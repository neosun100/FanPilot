// unit_logic.c —— fanlogic.h 的单元测试（零依赖，clang 直接编）
//
// 覆盖原则：
//   ① 每个函数的正常路径 + **边界** + 退化输入（NaN / 空 / 垃圾）
//   ② 每个修过的 bug 都有一条**回归**测试，标 [回归]
//   ③ 安全相关的必须有**反向**测试：不该生效的必须真的不生效
//
// 编译: clang -O0 -g -Wall -o tests/unit_logic tests/unit_logic.c && tests/unit_logic

#include <stdio.h>
#include <string.h>
#include <math.h>
#include "../src/fanlogic.h"

static int g_pass = 0, g_fail = 0;

static void group(const char *g){ printf("\n── %s\n", g); }
static void ok(int cond, const char *what){
    if (cond) { g_pass++; printf("  ✅ %s\n", what); }
    else      { g_fail++; printf("  ❌ %s\n", what); }
}
static void eqd(double got, double want, double tol, const char *what){
    if (fabs(got - want) <= tol) { g_pass++; printf("  ✅ %s (=%.2f)\n", what, got); }
    else { g_fail++; printf("  ❌ %s: 得到 %.4f，期望 %.4f\n", what, got, want); }
}

#define HW_MIN  1350.0
#define HW_MAX0 5349.0   // 实测本机风扇0 上限
#define HW_MAX1 5777.0   // 实测本机风扇1 上限

static fl_cfg parsed(const char *text){
    fl_cfg c; fl_cfg_defaults(&c);
    char buf[2048]; strncpy(buf, text, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    for (char *save = NULL, *l = strtok_r(buf, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
        fl_cfg_parse_line(&c, l);
    fl_cfg_clamp(&c);
    return c;
}

static void test_parse(void){
    group("配置解析 —— 单一百分比");
    fl_cfg c = parsed("percent = 85\n");
    eqd(c.percent, 85, 0.01, "percent = 85");
    c = parsed("percent=88\n");
    eqd(c.percent, 88, 0.01, "无空格写法也认");
    c = parsed("percent = 50%\n");
    eqd(c.percent, 50, 0.01, "允许写成 50%");
    c = parsed("percent = 62.5\n");
    eqd(c.percent, 62.5, 0.01, "小数也认");
    c = parsed("percent = abc\n");
    eqd(c.percent, FL_DEFAULT_PCT, 0.01, "⭐垃圾值 → 保留默认（不静默变成 0%）");
    c = parsed("percent = 85abc\n");
    eqd(c.percent, FL_DEFAULT_PCT, 0.01, "数字后跟垃圾 → 整体无效，保留默认");
    c = parsed("percent = 70   # 注释里有数字 kill -9 20\n");
    eqd(c.percent, 70, 0.01, "[回归] 注释先剥再解析（1.x 注释数字被吃进解析器）");
    c = parsed("# percent = 10\npercent = 60\n");
    eqd(c.percent, 60, 0.01, "整行注释不生效");
    c = parsed("percent = 60\r\n");
    eqd(c.percent, 60, 0.01, "CRLF 行尾也认");
    c = parsed("fan_mode = curve\nmin_rpm = 2500\nrpm = 4549, 4891\npercent = 40\n");
    eqd(c.percent, 40, 0.01, "旧版已删除的键（含 2.0 草案的 rpm）被忽略，不干扰");

    c = parsed("emergency_source = max\n");
    ok(c.emergency_source == 0, "emergency_source = max");
    c = parsed("emergency_source = average\n");
    ok(c.emergency_source == 1, "emergency_source = average");
    c = parsed("emergency_source = 乱写\n");
    ok(c.emergency_source == 0, "未知口径 → 最热核（保守方向）");
    c = parsed("");
    ok(c.emergency_source == 1, "默认口径 = 全核平均（使用者 2026-09-14 决定）");

    fl_cfg d;
    ok(fl_cfg_load("/nonexistent/fanpilot.conf", &d) == -1, "配置文件不存在 → 返回 -1（供调用方留痕）");
    eqd(d.percent, FL_DEFAULT_PCT, 0.01, "配置文件不存在 → 默认 50%");
}

static void test_clamp(void){
    group("fl_cfg_clamp —— 不可信输入，安全阈值硬夹（反向断言）");
    fl_cfg c = parsed("emergency_temp = 200\n");
    eqd(c.emergency_temp, FL_EMERG_MAX, 0.01, "[回归] emergency_temp 200 → 95（不许把保护调没）");
    c = parsed("emergency_temp = 10\n");
    eqd(c.emergency_temp, FL_EMERG_MIN, 0.01, "emergency_temp 10 → 70");
    c = parsed("emergency_temp = nan\n");
    eqd(c.emergency_temp, FL_EMERG_MIN, 0.01, "emergency_temp NaN → 70（NaN 不得绕过比较）");
    c = parsed("check_interval = 0.01\n");
    eqd(c.check_interval, FL_CHECK_MIN, 0.01, "check_interval 0.01 → 5（别把守护写成 CPU 大户）");
    c = parsed("check_interval = 9999\n");
    eqd(c.check_interval, FL_CHECK_MAX, 0.01, "check_interval 9999 → 60（过热响应不能更慢）");
    c = parsed("percent = 500\n");
    eqd(c.percent, 100, 0.01, "percent 500 → 100");
    c = parsed("percent = -5\n");
    eqd(c.percent, 0, 0.01, "percent -5 → 0（再由硬件下限兜底，不会停转）");
    c = parsed("percent = nan\n");
    eqd(c.percent, FL_DEFAULT_PCT, 0.01, "percent NaN → 默认 50%");
}

static void test_target(void){
    group("fl_fan_target —— 百分比 × 各风扇自己的硬件上限");
    fl_cfg c = parsed("percent = 85\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX0, 0), 4547, 0.01, "85% × 5349 = 4547（风扇0）");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX1, 0), 4910, 0.01, "85% × 5777 = 4910（风扇1）—— 同一百分比，两风扇各自折算");
    c = parsed("percent = 88\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX0, 0), 4707, 0.01, "88% × 5349 = 4707（四舍五入到 1 RPM）");
    c = parsed("percent = 100\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX1, 0), HW_MAX1, 0.01, "100% = 硬件上限");
    c = parsed("percent = 10\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX0, 0), HW_MIN, 0.01, "10%（535）低于 F*Mn → 夹到硬件下限 1350，不会停转");
    c = parsed("percent = 0\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX0, 0), HW_MIN, 0.01, "0% → 硬件下限");
    c = parsed("percent = 30\n");
    eqd(fl_fan_target(&c, HW_MIN, HW_MAX0, 1), HW_MAX0, 0.01, "⭐紧急 → 无视配置直接打满");
}

static void test_emergency(void){
    group("fl_emergency_next —— 紧急判定带 5°C 回差");
    fl_cfg c = parsed("emergency_temp = 90\n");
    ok(fl_emergency_next(&c, 0, 89.9) == 0, "89.9°C 未达阈值");
    ok(fl_emergency_next(&c, 0, 90.0) == 1, "90.0°C 进入紧急");
    ok(fl_emergency_next(&c, 1, 87.0) == 1, "[回差] 紧急中降到 87°C 仍保持（不在阈值附近横跳）");
    ok(fl_emergency_next(&c, 0, 87.0) == 0, "[回差] 非紧急时 87°C 不会进入");
    ok(fl_emergency_next(&c, 1, 84.9) == 0, "降到 84.9°C（< 阈值-5）才解除");
    // 横跳模拟：温度在 89~91 抖 20 次，状态切换次数必须 ≤ 1
    int st = 0, flips = 0;
    for (int i = 0; i < 20; i++) {
        int n = fl_emergency_next(&c, st, (i % 2) ? 91.0 : 89.0);
        if (n != st) flips++;
        st = n;
    }
    ok(flips == 1, "温度在 89/91 抖 20 次只切换 1 次（无回差时会是 20 次）");

    eqd(fl_pick_temp(0, 95, 80, 60), 95, 0.01, "口径 max");
    eqd(fl_pick_temp(1, 95, 80, 60), 80, 0.01, "口径 average");
    eqd(fl_pick_temp(2, 95, 80, 60), 60, 0.01, "口径 min");
}

static void test_rewrite(void){
    group("fl_needs_rewrite —— 定速 = 写一次；只在回读不符时重写");
    ok(fl_needs_rewrite(1, 4549, 4549) == 0, "⭐稳态：md=1 且 Tg 一致 → 不写");
    ok(fl_needs_rewrite(1, 4549 + FL_REWRITE_TOLERANCE, 4549) == 0, "偏差恰在容差内 → 不写");
    ok(fl_needs_rewrite(1, 3100, 3150) == 1, "[回归] 改档只差 50 RPM 也必须写（初版容差 50 时不写）");
    ok(fl_needs_rewrite(1, 3100, 3101.5) == 1, "改档差 1.5 RPM → 写");
    ok(fl_needs_rewrite(1, 3000, 4549) == 1, "Tg 被别的程序改了 → 重写");
    ok(fl_needs_rewrite(0, 4549, 4549) == 1, "md=0（被交还固件 / 睡醒）→ 重写");
    ok(fl_needs_rewrite(-1, 4549, 4549) == 1, "md 读失败 → 按需要写（宁可多写不脱管）");

    // 端到端模拟：1 天的 10s 巡检（8640 次），无外部扰动 ⇒ 写入只有起步那 1 次
    double tg = -1; int md = 0, writes = 0;
    for (int i = 0; i < 8640; i++) {
        if (fl_needs_rewrite(md, tg, 4549)) { md = 1; tg = 4549; writes++; }
    }
    ok(writes == 1, "模拟 1 天 8640 次巡检：写 SMC 恰 1 次");
}

static void test_storm_guards(void){
    group("🔴 防写入风暴 —— 令牌桶 + 抢写让步");
    fl_bucket b; fl_bucket_init(&b, 0);
    int got = 0;
    for (int i = 0; i < 1000; i++) got += fl_bucket_take(&b, 0, 1);
    ok(got == (int)FL_WRITE_BURST, "同一时刻狂写 1000 次 → 只放行 FL_WRITE_BURST 次（突发上限）");
    got = 0;
    for (int s = 1; s <= 3600; s++) got += fl_bucket_take(&b, s, 1);   // bug：每秒都想写
    ok(got <= (int)FL_WRITE_PER_HOUR + 1, "每秒都想写、持续 1 小时 → 放行 ≤ 速率上限 +1（长期速率上限）");
    fl_bucket_init(&b, 0);
    ok(fl_bucket_take(&b, 0, 4), "起步一次写 4 个键 → 放行");
    ok(fl_bucket_take(&b, 1e7, 1) && b.tokens <= FL_WRITE_BURST, "久不写之后回补不超过容量");
    // 模拟「每 10s 巡检都发现被外部改动」1 天：令牌桶下写入 ≤ 突发 + 24×60
    fl_bucket_init(&b, 0); got = 0;
    for (int t = 0; t < 86400; t += 10) got += 2 * fl_bucket_take(&b, t, 2);
    ok(got <= FL_WRITE_BURST + 24 * FL_WRITE_PER_HOUR + 2, "抢写 1 天：写入被压到 ≤ ~2922 次（1.x 是 2.3 万次）");
    // 人的正常操作不能被防线挡住：连续改 15 次档（每次 2 个键）必须全部放行
    fl_bucket_init(&b, 0); got = 0;
    for (int i = 0; i < 15; i++) got += fl_bucket_take(&b, i, 2);
    ok(got == 15, "[回归] 连续改档 15 次全部放行（初版容量 16 时第 9 次起被挡）");

    fl_fight g; fl_fight_init(&g);
    ok(fl_fight_note(&g, 0) == 0 && fl_fight_note(&g, 100) == 0, "外部改动 2 次 → 还不让步");
    ok(fl_fight_note(&g, 200) == 1, "10 分钟内第 3 次 → 进入让步");
    ok(fl_fight_yielding(&g, 200 + 1799), "让步持续 30 分钟");
    ok(!fl_fight_yielding(&g, 200 + 1800), "30 分钟后恢复接管");
    fl_fight_init(&g);
    fl_fight_note(&g, 0); fl_fight_note(&g, 700); 
    ok(fl_fight_note(&g, 1400) == 0, "零散改动（间隔 > 10 分钟）不算抢写（如每次睡醒 SMC 复位）");
    // 抢写 1 天：每 10s 被改一次。有让步时纠正写入次数 ≈ 每 30 分钟 3 次
    fl_fight_init(&g); int writes = 0;
    for (int t = 0; t < 86400; t += 10) {
        if (fl_fight_yielding(&g, t)) continue;
        writes += 2;
        fl_fight_note(&g, t);
    }
    ok(writes <= 2 * 3 * (86400 / 1800 + 1), "被持续抢写 1 天：纠正写入 ≤ ~294 次，且不拉锯");
}

int main(void){
    test_parse();
    test_clamp();
    test_target();
    test_emergency();
    test_rewrite();
    test_storm_guards();
    printf("\n═══════════════════════════════\n  通过 %d · 失败 %d\n", g_pass, g_fail);
    if (g_fail == 0) printf("  ✅ 全部通过\n");
    return g_fail == 0 ? 0 : 1;
}

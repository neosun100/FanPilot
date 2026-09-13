// unit_logic.c —— fanlogic.h 的单元测试（零依赖，clang 直接编）
//
// 覆盖原则：
//   ① 每个函数的正常路径 + **边界** + 退化输入（0/负/NaN 风险）
//   ② 每个修过的 bug 都有一条**回归**测试，标 [回归]
//   ③ 安全相关的必须有**反向**测试：不该生效的必须真的不生效
//
// 编译: clang -O0 -g -Wall -o tests/unit_logic tests/unit_logic.c && tests/unit_logic

#include <stdio.h>
#include <string.h>
#include <math.h>
#include "../src/fanlogic.h"

static int g_pass = 0, g_fail = 0;
static const char *g_group = "";

static void group(const char *g){ g_group = g; printf("\n── %s\n", g); }

static void ok(int cond, const char *what){
    if (cond) { g_pass++; printf("  ✅ %s\n", what); }
    else      { g_fail++; printf("  ❌ %s\n", what); }
}
static void eqd(double got, double want, double tol, const char *what){
    int c = fabs(got - want) <= tol;
    if (c) { g_pass++; printf("  ✅ %s (=%.2f)\n", what, got); }
    else   { g_fail++; printf("  ❌ %s: 得到 %.4f，期望 %.4f (±%.4f)\n", what, got, want, tol); }
}

#define HW_MAX0 5349.0   // 实测本机风扇0 上限
#define HW_MAX1 5777.0   // 实测本机风扇1 上限
#define HW_MIN  1350.0

// ═══════════════════════════════════════════════════════════════════
static void test_cfg_clamp(void){
    group("fl_cfg_clamp —— 配置是不可信输入，安全阈值必须硬夹");

    // [回归] 恶意/手误配置不得绕过保护
    fl_cfg c; fl_cfg_defaults(&c);
    c.emergency_temp = 200;  fl_cfg_clamp(&c);
    eqd(c.emergency_temp, 95, 0.001, "[回归] emergency_temp 200 → 95（不许把紧急保护调没）");

    fl_cfg_defaults(&c); c.emergency_temp = 10; fl_cfg_clamp(&c);
    eqd(c.emergency_temp, 70, 0.001, "emergency_temp 10 → 70（不许低到天天误触发）");

    fl_cfg_defaults(&c); c.poll_interval = 0.01; fl_cfg_clamp(&c);
    eqd(c.poll_interval, 0.5, 0.001, "[回归] poll_interval 0.01 → 0.5（别把守护写成 CPU 大户）");

    fl_cfg_defaults(&c); c.poll_interval = 999; fl_cfg_clamp(&c);
    eqd(c.poll_interval, 30, 0.001, "poll_interval 999 → 30（太慢来不及响应升温）");

    fl_cfg_defaults(&c); c.ema_seconds = 9999; fl_cfg_clamp(&c);
    eqd(c.ema_seconds, 120, 0.001, "[回归] ema_seconds 9999 → 120（平滑过久等于不响应）");

    fl_cfg_defaults(&c); c.ema_seconds = 0; fl_cfg_clamp(&c);
    eqd(c.ema_seconds, 1, 0.001, "ema_seconds 0 → 1（不得为 0，会除零）");

    fl_cfg_defaults(&c); c.deadband = 99999; fl_cfg_clamp(&c);
    eqd(c.deadband, 500, 0.001, "[回归] deadband 99999 → 500（死区过大等于不控制）");

    fl_cfg_defaults(&c); c.deadband = -5; fl_cfg_clamp(&c);
    eqd(c.deadband, 0, 0.001, "deadband -5 → 0（负死区无意义）");

    fl_cfg_defaults(&c); c.slew_up = 1; fl_cfg_clamp(&c);
    eqd(c.slew_up, 10, 0.001, "[回归] slew_up 1 → 10（太小等于升不上去）");

    // ⭐ 反向：夹取不能误伤合法配置（只夹越界的，别顺手改对的）
    fl_cfg_defaults(&c);
    fl_cfg d = c;
    fl_cfg_clamp(&c);
    ok(c.poll_interval == d.poll_interval && c.min_rpm == d.min_rpm &&
       c.max_rpm == d.max_rpm && c.ema_seconds == d.ema_seconds &&
       c.slew_up == d.slew_up && c.slew_down == d.slew_down &&
       c.deadband == d.deadband && c.emergency_temp == d.emergency_temp,
       "⭐反向：默认（合法）配置经夹取后**一字未改**");
}

// ═══════════════════════════════════════════════════════════════════
static void test_curve_rescale(void){
    group("fl_curve_rescale —— 抬高下限时整条曲线重新铺开（用户诉求）");

    // 下限 2000（默认）：端点应为 2000 与硬件上限
    fl_cfg c; fl_cfg_defaults(&c);
    fl_curve_rescale(&c, HW_MAX0);
    eqd(c.curve[0].rpm, 2000, 0.5, "下限2000: 45°C → 2000");
    eqd(c.curve[4].rpm, HW_MAX0, 0.5, "下限2000: 85°C → 硬件上限 5349");

    // ⭐ 核心诉求：下限 3000 时中间段**不得出现死区**（相邻点必须严格递增）
    fl_cfg_defaults(&c); c.min_rpm = 3000;
    fl_curve_rescale(&c, HW_MAX0);
    eqd(c.curve[0].rpm, 3000,    0.5, "下限3000: 45°C → 3000");
    eqd(c.curve[4].rpm, HW_MAX0, 0.5, "下限3000: 85°C → 5349");
    int strictly_up = 1;
    for (int i = 1; i < c.n_curve; i++)
        if (!(c.curve[i].rpm > c.curve[i-1].rpm + 1)) strictly_up = 0;
    ok(strictly_up, "⭐下限3000: 5 个点严格递增 —— **无死区**（这是重铺的目的）");
    printf("      重铺后: ");
    for (int i = 0; i < c.n_curve; i++) printf("%.0f°C:%.0f  ", c.curve[i].t, c.curve[i].rpm);
    printf("\n");

    // 下限 4000（更极端）仍不得出现死区
    fl_cfg_defaults(&c); c.min_rpm = 4000;
    fl_curve_rescale(&c, HW_MAX0);
    strictly_up = 1;
    for (int i = 1; i < c.n_curve; i++)
        if (!(c.curve[i].rpm > c.curve[i-1].rpm + 1)) strictly_up = 0;
    ok(strictly_up, "下限4000: 仍严格递增");
    eqd(c.curve[0].rpm, 4000, 0.5, "下限4000: 起点 4000");

    // 两个风扇上限不同 ⇒ 用各自的（实测 5349 vs 5777）
    fl_cfg_defaults(&c); c.min_rpm = 2000;
    fl_cfg c1 = c;
    fl_curve_rescale(&c,  HW_MAX0);
    fl_curve_rescale(&c1, HW_MAX1);
    ok(fabs(c1.curve[4].rpm - HW_MAX1) < 0.5 && fabs(c.curve[4].rpm - HW_MAX0) < 0.5,
       "[回归] 两风扇上限不同(5349/5777)时各自铺到自己的上限，不写死同值");

    // max_rpm 显式设定时优先于硬件上限
    fl_cfg_defaults(&c); c.max_rpm = 4000;
    fl_curve_rescale(&c, HW_MAX0);
    eqd(c.curve[4].rpm, 4000, 0.5, "显式 max_rpm=4000 时铺到 4000，不到硬件 5349");

    // ⭐ 幂等性：重铺两次结果相同（第一次后 lo=min、hi=hi，第二次映射是恒等）
    fl_cfg_defaults(&c); c.min_rpm = 3000;
    fl_curve_rescale(&c, HW_MAX0);
    fl_cfg once = c;
    fl_curve_rescale(&c, HW_MAX0);
    int same = 1;
    for (int i = 0; i < c.n_curve; i++)
        if (fabs(c.curve[i].rpm - once.curve[i].rpm) > 0.001) same = 0;
    ok(same, "⭐幂等：连续重铺两次结果完全相同（我最初误以为会漂移，实测不会）");

    // autoscale=0 ⇒ 曲线原样不动（手工调过的不被改写）
    fl_cfg_defaults(&c); c.min_rpm = 3000; c.curve_autoscale = 0;
    double before = c.curve[0].rpm;
    fl_curve_rescale(&c, HW_MAX0);
    eqd(c.curve[0].rpm, before, 0.001, "[反向] autoscale=0 时曲线一点不改（手工曲线受保护）");

    // 退化输入不得产生 NaN / 崩溃
    fl_cfg_defaults(&c); for (int i=0;i<c.n_curve;i++) c.curve[i].rpm = 2500;  // 平模板
    fl_curve_rescale(&c, HW_MAX0);
    ok(!isnan(c.curve[0].rpm) && fabs(c.curve[0].rpm - c.min_rpm) < 0.5,
       "退化：平模板（无形状）→ 全给下限，无 NaN（除零防护）");

    fl_cfg_defaults(&c); c.min_rpm = 6000;   // 下限高于硬件上限
    fl_curve_rescale(&c, HW_MAX0);
    ok(!isnan(c.curve[0].rpm) && fabs(c.curve[0].rpm - 6000) < 0.5,
       "退化：下限高于上限 → 全给下限，无 NaN");

    fl_cfg_defaults(&c); c.n_curve = 0;
    fl_curve_rescale(&c, HW_MAX0);
    ok(1, "退化：n_curve=0 不崩");
}

// ═══════════════════════════════════════════════════════════════════
static void test_temp_source(void){
    group("fl_control_temp / fl_is_emergency —— 控制输入与紧急判据同口径（temp_source 决定）");
    fl_cfg c; fl_cfg_defaults(&c);

    ok(c.temp_source == 1, "默认 temp_source = 1（全核平均，使用者选定）");

    // 用本机实测的真实温差：性能核最热 84.3，全核平均 72.6（差 11.7）
    double hot = 84.3, avg = 72.6;
    c.temp_source = 1;
    eqd(fl_control_temp(&c, hot, avg), avg, 0.001, "temp_source=average ⇒ 控制输入取平均 72.6");
    c.temp_source = 0;
    eqd(fl_control_temp(&c, hot, avg), hot, 0.001, "temp_source=max ⇒ 控制输入取最热 84.3");

    // 📌 断言口径已于 2026-09-14 按使用者决定变更（原断言「紧急固定看最热核」
    //    按新设计**已不成立**，故改写而非删除 —— 删掉安全断言而不留痕是最坏做法）。
    //    新设计：紧急判据与曲线同口径，由 temp_source 决定。
    fl_cfg_defaults(&c); c.emergency_temp = 90;

    c.temp_source = 0;    // max 口径
    ok(!fl_is_emergency(&c, 89.9, 70.0), "max口径: 最热 89.9 ⇒ 不触发");
    ok( fl_is_emergency(&c, 90.0, 70.0), "max口径: 最热 90.0 ⇒ 触发（不看平均）");

    c.temp_source = 1;    // average 口径（当前默认）
    ok(!fl_is_emergency(&c, 98.0, 89.9), "average口径: 平均 89.9 ⇒ 不触发（最热已 98）");
    ok( fl_is_emergency(&c, 92.0, 90.0), "average口径: 平均 90.0 ⇒ 触发");

    // ⭐ 把变更的后果**写成可执行的断言**，让它无法被悄悄遗忘：
    //    实测温差 2.0~7.8°C（高负载曾 11.7°C）⇒ 平均到 90 时最热核约 92~102°C
    c.temp_source = 1;
    ok(!fl_is_emergency(&c, 97.8, 90.0 - 7.8),
       "⚠️[已知后果] average口径下，最热核 97.8°C 而平均 82.2°C 时**不触发** —— "
       "这是使用者知情后的选择，非缺陷");
    ok( fl_is_emergency(&c, 97.8, 90.0),
       "average口径: 平均升到 90 才触发（此时最热核约 97.8）");

    // 切回 max 必须恢复更早介入
    c.temp_source = 0;
    ok(fl_is_emergency(&c, 97.8, 82.2),
       "⭐ temp_source=max 可随时恢复「更早介入」（同一输入下 max 触发、average 不触发）");
}

// ═══════════════════════════════════════════════════════════════════
static void test_curve_eval(void){
    group("fl_curve_eval —— 分段线性插值");
    fl_cfg c; fl_cfg_defaults(&c); c.curve_autoscale = 0;   // 用原始模板便于对数

    eqd(fl_curve_eval(&c, 20), 2000, 0.001, "低于首点(20°C) → 首点值 2000");
    eqd(fl_curve_eval(&c, 45), 2000, 0.001, "首点(45°C) 精确 2000");
    eqd(fl_curve_eval(&c, 50), 2300, 0.001, "45~55 中点(50°C) → 2300（线性）");
    eqd(fl_curve_eval(&c, 55), 2600, 0.001, "端点(55°C) 精确 2600");
    eqd(fl_curve_eval(&c, 60), 3000, 0.001, "55~65 中点(60°C) → 3000");
    eqd(fl_curve_eval(&c, 85), 5300, 0.001, "末点(85°C) 精确 5300");
    eqd(fl_curve_eval(&c, 150), 5300, 0.001, "高于末点(150°C) → 末点值（不外插）");

    // 单调性：整个区间内不得回落
    double prev = -1; int mono = 1;
    for (double t = 0; t <= 120; t += 0.5) {
        double v = fl_curve_eval(&c, t);
        if (v < prev - 0.001) mono = 0;
        prev = v;
    }
    ok(mono, "⭐0~120°C 全程单调不回落（回落会导致温度升高反而降速）");

    // 退化
    fl_cfg d; fl_cfg_defaults(&d); d.n_curve = 0;
    eqd(fl_curve_eval(&d, 60), d.min_rpm, 0.001, "退化：无曲线点 → 返回下限");

    fl_cfg e; fl_cfg_defaults(&e); e.n_curve = 1; e.curve[0].t = 50; e.curve[0].rpm = 2222;
    eqd(fl_curve_eval(&e, 10),  2222, 0.001, "退化：单点曲线，低温侧");
    eqd(fl_curve_eval(&e, 100), 2222, 0.001, "退化：单点曲线，高温侧");

    fl_cfg f; fl_cfg_defaults(&f); f.n_curve = 2;
    f.curve[0].t = 50; f.curve[0].rpm = 2000;
    f.curve[1].t = 50; f.curve[1].rpm = 3000;      // 重复温度点
    ok(!isnan(fl_curve_eval(&f, 50)), "退化：重复温度点不产生 NaN（除零防护）");
}

// ═══════════════════════════════════════════════════════════════════
static void test_clamp_fan(void){
    group("fl_clamp_fan —— 值域夹取 + 紧急路径不受用户上限约束");
    fl_cfg c; fl_cfg_defaults(&c);

    eqd(fl_clamp_fan(&c, HW_MIN, HW_MAX0, 500, 0),  2000, 0.001, "低于下限 → 下限 2000");
    eqd(fl_clamp_fan(&c, HW_MIN, HW_MAX0, 9999, 0), HW_MAX0, 0.001, "高于硬件上限 → 5349");
    eqd(fl_clamp_fan(&c, HW_MIN, HW_MAX0, 3000, 0), 3000, 0.001, "区间内原值通过");

    c.max_rpm = 3000;
    eqd(fl_clamp_fan(&c, HW_MIN, HW_MAX0, 5000, 0), 3000, 0.001, "非紧急：受用户 max_rpm=3000 约束");
    // 🔴 [回归] 这是修过的安全洞：紧急打满不得被用户上限挡住
    eqd(fl_clamp_fan(&c, HW_MIN, HW_MAX0, 9999, 1), HW_MAX0, 0.001,
        "🔴[回归] 紧急态**忽略**用户 max_rpm，铺到硬件上限 5349");

    // 下限低于硬件下限时应取硬件下限
    fl_cfg d; fl_cfg_defaults(&d); d.min_rpm = 500;
    eqd(fl_clamp_fan(&d, HW_MIN, HW_MAX0, 100, 0), HW_MIN, 0.001,
        "配置下限低于硬件下限 → 取硬件下限 1350");

    // hi < lo 的矛盾配置不得返回荒谬值
    fl_cfg e; fl_cfg_defaults(&e); e.min_rpm = 5000; e.max_rpm = 2000;
    double v = fl_clamp_fan(&e, HW_MIN, HW_MAX0, 3000, 0);
    ok(v >= 2000 && v <= HW_MAX0 && !isnan(v),
       "矛盾配置(下限5000>上限2000)仍返回合法范围内的值");
}

// ═══════════════════════════════════════════════════════════════════
static void test_ema(void){
    group("fl_ema —— 指数平滑");
    eqd(fl_ema(-1, 57, 0.13), 57, 0.001, "首次(prev<0) 直接取原值，不从 0 慢爬");
    eqd(fl_ema(50, 60, 1.0),  60, 0.001, "alpha=1 → 完全跟随");
    eqd(fl_ema(50, 60, 0.0),  50, 0.001, "alpha=0 → 完全不动");
    eqd(fl_ema(50, 60, 0.5),  55, 0.001, "alpha=0.5 → 取中");
    eqd(fl_ema(50, 60, 5.0),  60, 0.001, "alpha 越界(5.0) 被夹到 1");
    eqd(fl_ema(50, 60, -3.0), 50, 0.001, "alpha 越界(-3) 被夹到 0");

    // 收敛性：持续喂同一值应逼近它
    double v = 30; for (int i = 0; i < 200; i++) v = fl_ema(v, 70, 2.0/15.0);
    eqd(v, 70, 0.5, "持续喂 70°C 两百轮后收敛到 70");
}

// ═══════════════════════════════════════════════════════════════════
static void test_slew(void){
    group("fl_slew —— 非对称变化率限幅（升快降慢，这是「丝滑」的关键）");
    fl_cfg c; fl_cfg_defaults(&c);   // up=200 down=60 RPM/s
    double dt = 2.0;                  // 2s 周期 ⇒ 单周期最多 +400 / -120

    eqd(fl_slew(&c, 2000, 5000, dt, 0), 2400, 0.001, "升速被限：一周期最多 +400");
    eqd(fl_slew(&c, 3000, 1000, dt, 0), 2880, 0.001, "降速被限：一周期最多 -120");
    eqd(fl_slew(&c, 2000, 2100, dt, 0), 2100, 0.001, "小变化(100<400) 直接到位");
    ok(fabs(fl_slew(&c,2000,5000,dt,0)-2000) > fabs(fl_slew(&c,3000,1000,dt,0)-3000),
       "⭐非对称：升速步长(400) > 降速步长(120)");
    // 🔴 [回归] 紧急态必须无视限幅，立刻打满
    eqd(fl_slew(&c, 2000, 5349, dt, 1), 5349, 0.001,
        "🔴[回归] 紧急态忽略限幅，一步到位（保护优先于丝滑）");
    eqd(fl_slew(&c, 2000, 2000, dt, 0), 2000, 0.001, "无变化 → 不动");
}

// ═══════════════════════════════════════════════════════════════════
static void test_should_write(void){
    group("fl_should_write —— 死区抑制无谓 SMC 写入");
    fl_cfg c; fl_cfg_defaults(&c);   // deadband=50

    ok(fl_should_write(&c, -1, 2000),  "首次(last<0) 必须写");
    ok(!fl_should_write(&c, 2000, 2030), "[回归] 变化 30 < 死区 50 → 不写");
    ok(fl_should_write(&c, 2000, 2100),  "变化 100 > 死区 50 → 写");
    ok(!fl_should_write(&c, 2000, 2050), "边界：变化恰好=死区 → 不写（严格大于才写）");
    ok(fl_should_write(&c, 2000, 2051),  "边界：死区+1 → 写");
    ok(!fl_should_write(&c, 2000, 1970), "反向变化 30 也不写（取绝对值）");
    ok(fl_should_write(&c, 2000, 1900),  "反向变化 100 要写");
}

// ═══════════════════════════════════════════════════════════════════
static void test_fault(void){
    group("fl_fault_check —— 风扇故障状态机");
    fl_fan_state s; fl_fan_state_init(&s);
    double now = 1000;

    // 正常跟随不报
    for (int i = 0; i < 20; i++) { now += 2; fl_fault_check(&s, 2000, 1990, now, NULL); }
    ok(!s.fault, "正常跟随(1990/2000) 20 周期后不报故障");

    // 🔴 [回归] 爬升宽限期内不得误报（实测硬件 0→2500 需 6~9s）
    fl_fan_state_init(&s); now = 1000;
    fl_note_target(&s, 4000, now);                 // 目标从 0 大幅上调
    int false_alarm = 0;
    for (int i = 0; i < 5; i++) {                   // 10s，仍在 12s 宽限内
        now += 2;
        if (fl_fault_check(&s, 4000, 500, now, NULL)) false_alarm = 1;
    }
    ok(!false_alarm, "🔴[回归] 爬升宽限期(12s)内即使实际远低于目标也**不误报**");

    // 宽限期过后持续跟不上 ⇒ 报
    now += 20;                                      // 越过宽限
    int onset = 0, fired = 0;
    for (int i = 0; i < FL_FAULT_CYCLES + 2; i++) {
        now += 2;
        if (fl_fault_check(&s, 4000, 500, now, &onset)) fired = 1;
    }
    ok(fired, "⭐宽限期后持续低于 55% 达 6 周期 ⇒ 判定故障（判据是活的）");

    // 边界：只差一个周期不得提前报
    fl_fan_state_init(&s); now = 2000; s.settle_at = 0;
    int early = 0;
    for (int i = 0; i < FL_FAULT_CYCLES - 1; i++) {
        now += 2;
        if (fl_fault_check(&s, 4000, 500, now, NULL)) early = 1;
    }
    ok(!early, "边界：连续 5 周期（差 1 个）还不报");
    now += 2;
    ok(fl_fault_check(&s, 4000, 500, now, NULL), "边界：第 6 个周期才报");

    // onset 只在首次判定时为 1（避免日志刷屏）
    fl_fan_state_init(&s); now = 3000;
    int onsets = 0;
    for (int i = 0; i < 15; i++) {
        now += 2; onset = 0;
        fl_fault_check(&s, 4000, 500, now, &onset);
        if (onset) onsets++;
    }
    ok(onsets == 1, "onset 只在**首次**判定时置 1（防日志刷屏），实际置位次数=1");

    // 恢复后清除
    for (int i = 0; i < 3; i++) { now += 2; fl_fault_check(&s, 4000, 3990, now, NULL); }
    ok(!s.fault && s.cnt == 0, "恢复正常后故障态被清除");

    // 不判的场景
    fl_fan_state_init(&s);
    ok(!fl_fault_check(&s, 500, 0, 100, NULL), "目标<1000 时不判（可能是固件在管）");
    fl_fan_state_init(&s);
    ok(!fl_fault_check(&s, 3000, -1, 100, NULL), "实际读取失败(-1) 时不判，不猜");

    // fl_note_target 行为
    fl_fan_state_init(&s);
    ok(fl_note_target(&s, 2500, 500) == 1, "目标上调 >100 ⇒ 设置爬升宽限");
    ok(fabs(s.settle_at - (500 + FL_SPINUP_GRACE)) < 0.001, "宽限截止 = now + 12s");
    ok(fl_note_target(&s, 2550, 600) == 0, "目标小幅上调(50) ⇒ 不重置宽限");
    ok(fl_note_target(&s, 2000, 700) == 0, "目标下调 ⇒ 不重置宽限");
}

// ═══════════════════════════════════════════════════════════════════
// 端到端（纯逻辑层面）：模拟一次完整升温→降温，验证整链行为
static void test_integration(void){
    group("整链集成（纯逻辑）：升温 → 降温 的完整轨迹");
    fl_cfg c; fl_cfg_defaults(&c);
    fl_cfg_clamp(&c);
    fl_curve_rescale(&c, HW_MAX0);

    double ema = -1, cur = c.min_rpm, last = -1;
    double alpha = c.poll_interval / c.ema_seconds;
    int writes = 0, overshoot = 0;
    double peak = 0;

    // 40°C → 80°C 各 60 周期，再降回
    for (int phase = 0; phase < 2; phase++) {
        double t = phase == 0 ? 80 : 40;
        for (int i = 0; i < 60; i++) {
            ema = fl_ema(ema, t, alpha);
            int emg = t >= c.emergency_temp;
            double want = emg ? 1e9 : fl_curve_eval(&c, ema);
            double tgt = fl_clamp_fan(&c, HW_MIN, HW_MAX0, want, emg);
            tgt = fl_slew(&c, cur, tgt, c.poll_interval, emg);
            cur = tgt;
            if (cur > peak) peak = cur;
            if (fl_should_write(&c, last, tgt)) { last = tgt; writes++; }
        }
        // 升温段结束时应已接近曲线在 80°C 的值，且不得超过硬件上限
        if (phase == 0) {
            double expect = fl_curve_eval(&c, 80);
            eqd(cur, expect, 60, "升温 80°C 稳定后目标 ≈ 曲线值");
            if (cur > HW_MAX0 + 0.5) overshoot = 1;
        }
    }
    ok(!overshoot, "⭐全程从不超过硬件上限（越界会被 SMC 拒绝）");
    eqd(cur, c.min_rpm, 60, "降温回 40°C 后回落到下限附近");
    ok(peak <= HW_MAX0 + 0.5, "峰值不超硬件上限");
    printf("      120 周期共写 SMC %d 次（死区抑制生效，非每周期都写）\n", writes);
    ok(writes < 120, "死区抑制：写入次数 < 周期数");
}

int main(void){
    printf("═══ FanPilot 纯逻辑单元测试 ═══\n");
    test_cfg_clamp();
    test_curve_rescale();
    test_temp_source();
    test_curve_eval();
    test_clamp_fan();
    test_ema();
    test_slew();
    test_should_write();
    test_fault();
    test_integration();
    printf("\n═══════════════════════════════\n");
    printf("  通过 %d · 失败 %d\n", g_pass, g_fail);
    if (g_fail == 0) { printf("  ✅ 全部通过\n"); return 0; }
    printf("  ❌ 有失败\n");
    return 1;
}

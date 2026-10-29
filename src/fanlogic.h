// fanlogic.h —— FanPilot 的**纯决策逻辑**（零 IOKit 依赖，可单元测试）
//
// 2.0 起 FanPilot 只做一件事：**把风扇定死在指定转速**。
// 自适应曲线（EMA / 分段曲线 / 限幅 / 重铺 / 温度口径三档）整套删除 ——
// 理由见 CHANGELOG 2.0.0：使用者只要定速，而 SMC 的 F*md=1 + F*Tg 是**锁存**的，
// 定速只需「写一次」，曲线那套每 2 秒的计算全是无用功。
//
// 这里留下的每个函数都是**真正会出错**的地方：配置解析（不可信输入）、
// 安全夹取、紧急判定（带回差）、是否需要重写（外部改动检测）。
// 头文件内实现（static inline）：守护与测试都只 #include，不引入额外编译单元。

#ifndef FANLOGIC_H
#define FANLOGIC_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FL_NFAN 2

// ── 所有阈值集中在这里（不散落成魔法数字）──────────────────────────
#define FL_DEFAULT_PCT          50.0  // 默认定速：各风扇硬件上限的 50%
#define FL_CHECK_MIN             5.0  // 巡检间隔下限：别把守护写成 CPU 大户
#define FL_CHECK_MAX            60.0  // 上限：过热响应最坏延迟一个间隔，60s 已是极限
#define FL_CHECK_DEFAULT         5.0  // 2026-10-28 使用者：10s 太慢 ⇒ 5s（多的全是 SMC 读，写入仍为 0）
#define FL_EMERG_MIN            70.0  // 不许低到天天误触发
#define FL_EMERG_MAX            95.0  // ⭐ 不许把保护调没
#define FL_EMERG_DEFAULT        90.0
#define FL_EMERG_HYSTERESIS      5.0  // 降到 阈值-5°C 才解除，防止在阈值附近反复写 SMC
#define FL_EMERG_MIN_HOLD       60.0  // 打满后至少保持 60 s 才允许解除 ⇒ 最多每分钟进出一次
// 🩸 2026-10-29 使用者：「写 SMC 不要太频繁，否则可能有问题」。只靠回差的话，负载忽高忽低时全核平均
//    在 84~91°C 间来回摆，可以每次巡检都进出一次（每 10 s 4 次写入）。解除虽已受令牌桶约束，但进入不受，实测最坏仍有单风扇 5791 次/天。
#define FL_REWRITE_TOLERANCE     1.0  // F*Tg 回读与目标差超过此值才重写
// 🩸 初版取 50：实测 SMC 回读 Tg 与写入值逐位一致（flt），50 毫无必要，
//    反而让「改档 ≤50 RPM」被判成无需写入 —— e2e R15 抓到（3100→3150 不生效）。
// ── 🔴 防写入风暴（使用者原话：「之前就是各种写入风暴，导致我的电脑死机」）──
//    1.x 自适应模式 ≈ 2.3 万次/天写 SMC，与 2026-09-13~14 的 5 次 PMU 看门狗复位相关。
//    定速稳态本就 0 写入；以下两道是**防 bug 与防抢写**的硬上限，不是常态路径。
#define FL_WRITE_BURST          40.0  // 令牌桶容量：起步 4 次 + 连续改十几次档
#define FL_WRITE_PER_HOUR      120.0  // 长期速率上限（2 次/分钟回补）⇒ 最坏 ≈2900 次/天
// 🩸 初版 16 / 60：e2e 连续改档 10 次就把桶耗光，之后使用者改档要等几分钟才落地。
//    防线是防「bug 无限写」，不是防「人连续点几下」—— 容量要盖住人的正常操作。
#define FL_FIGHT_WINDOW        600.0  // 10 分钟内 …
#define FL_FIGHT_COUNT           3    // … 被外部改动 ≥3 次 ⇒ 判定有别的程序在抢写
#define FL_FIGHT_YIELD        1800.0  // ⇒ 让步 30 分钟（不纠正、不写），绝不互相拉锯

// ── 配置 ──────────────────────────────────────────────────────────
typedef struct {
    // 定速 = **各风扇硬件上限的百分比**（使用者 2026-10-28 指定）。
    // 为什么不用 RPM：两风扇上限不同（本机 5349 / 5777），同一个 RPM 对两者的风量占比不同；
    // 一个百分比让两风扇「一样卖力」，也只需要记一个数。
    double percent;
    double check_interval;     // 安全巡检间隔（秒）
    double emergency_temp;     // 紧急打满阈值
    int    emergency_source;   // 紧急判据口径：0=最热核 1=全核平均 2=最低核
} fl_cfg;

static inline void fl_cfg_defaults(fl_cfg *c){
    c->percent          = FL_DEFAULT_PCT;
    c->check_interval   = FL_CHECK_DEFAULT;
    c->emergency_temp   = FL_EMERG_DEFAULT;
    // 默认全核平均：使用者 2026-09-14 的明确决定（见 git 5dc2815）
    c->emergency_source = 1;
}

// 🔴 配置是**不可信输入**（对控制台用户可写，否则菜单栏 App 改不了）
//    ⇒ 保护性阈值的边界来自代码，不来自配置。
static inline void fl_cfg_clamp(fl_cfg *c){
    // NaN 回默认（atof("nan") 是合法输入，且任何比较对 NaN 都为假）；越界夹到 0~100。
    // 0% 不会让风扇停：目标最终还要夹到硬件下限 F*Mn（见 fl_fan_target）。
    if (c->percent != c->percent) c->percent = FL_DEFAULT_PCT;
    if (c->percent < 0)           c->percent = 0;
    if (c->percent > 100)         c->percent = 100;
    // NaN 落到下限：`!(x >= lo)` 对 NaN 为真
    if (!(c->check_interval >= FL_CHECK_MIN)) c->check_interval = FL_CHECK_MIN;
    if (c->check_interval > FL_CHECK_MAX)     c->check_interval = FL_CHECK_MAX;
    if (!(c->emergency_temp >= FL_EMERG_MIN)) c->emergency_temp = FL_EMERG_MIN;
    if (c->emergency_temp > FL_EMERG_MAX)     c->emergency_temp = FL_EMERG_MAX;
    if (c->emergency_source < 0 || c->emergency_source > 2) c->emergency_source = 0;
}

// 口径名 → 枚举。无法识别时退回 0(最热核) —— 保守方向
static inline int fl_parse_src(const char *v){
    if (!strcmp(v,"average") || !strcmp(v,"avg") || !strcmp(v,"1")) return 1;
    if (!strcmp(v,"min")     || !strcmp(v,"coolest") || !strcmp(v,"2")) return 2;
    return 0;
}
static inline const char *fl_src_name(int s){ return s==1?"average":(s==2?"min":"max"); }

// 解析一个数；不是数字（"abc"、空）返回 0 并保留原值 —— 不让垃圾值静默变成 0%
static inline int fl_parse_num(const char *v, double *out){
    char *end; double x = strtod(v, &end);
    if (end == v) return 0;
    while (*end == ' ' || *end == '\t' || *end == '%') end++;   // 允许写 "85%"
    if (*end) return 0;
    *out = x; return 1;
}

// 解析一行 `key = value  # 注释`。未知键忽略（旧版配置里的 curve/min_rpm 等不报错）。
// 🩸 注释必须**先剥再解析**：旧版实测踩过「注释里的 kill -9 被吃成数字」。
static inline void fl_cfg_parse_line(fl_cfg *c, const char *raw){
    char line[512];
    strncpy(line, raw, sizeof line - 1); line[sizeof line - 1] = 0;
    char *h = strchr(line, '#'); if (h) *h = 0;
    char k[64], v[400];
    if (sscanf(line, " %63[^= \t] = %399[^\n]", k, v) != 2) return;
    char *e = v + strlen(v);
    while (e > v && (e[-1]==' ' || e[-1]=='\t' || e[-1]=='\r')) *--e = 0;
    if      (!strcmp(k, "percent"))          fl_parse_num(v, &c->percent);
    else if (!strcmp(k, "check_interval"))   c->check_interval   = atof(v);
    else if (!strcmp(k, "emergency_temp"))   c->emergency_temp   = atof(v);
    else if (!strcmp(k, "emergency_source")) c->emergency_source = fl_parse_src(v);
}

// 读整份配置：默认值 → 逐行覆盖 → 硬夹。文件不存在 = 全默认（返回 -1 供调用方留痕）。
static inline int fl_cfg_load(const char *path, fl_cfg *c){
    fl_cfg_defaults(c);
    FILE *fp = fopen(path, "r");
    int rc = -1;
    if (fp) {
        char line[512];
        while (fgets(line, sizeof line, fp)) fl_cfg_parse_line(c, line);
        fclose(fp);
        rc = 0;
    }
    fl_cfg_clamp(c);
    return rc;
}

// ── 每风扇实际写入的目标 ───────────────────────────────────────────
// 百分比 × 该风扇运行时读到的上限，再夹在 [F*Mn, F*Mx] 内（风扇数、上下限全不硬编码）。
// 紧急时直接给硬件上限。
static inline double fl_fan_target(const fl_cfg *c, double fmin, double fmax, int emergency){
    if (emergency) return fmax;
    double t = (double)(long)(fmax * c->percent / 100.0 + 0.5);   // 取整到 1 RPM
    if (t < fmin) t = fmin;
    if (t > fmax) t = fmax;
    return t;
}

// ── 紧急判定（带回差）────────────────────────────────────────────
static inline double fl_pick_temp(int src, double hottest, double average, double coolest){
    if (src == 1) return average;
    if (src == 2) return coolest;
    return hottest;
}
// 进入：温度 ≥ 阈值；解除：温度 < 阈值 - 回差；之间保持上一状态。
// 🩸 无回差时，温度在 90°C 上下抖 ⇒ 每次巡检都在「打满 ↔ 定速」之间切换并写 SMC。
static inline int fl_emergency_next(const fl_cfg *c, int prev, double temp){
    if (temp >= c->emergency_temp) return 1;
    if (temp <  c->emergency_temp - FL_EMERG_HYSTERESIS) return 0;
    return prev;
}

// 带最短保持时间的紧急判定：进入立即生效（过热保护不能等）；解除要满足回差**且**已保持 ≥ FL_EMERG_MIN_HOLD。
// since = 进入紧急的时刻（醒着时钟），由本函数维护。
static inline int fl_emergency_step(const fl_cfg *c, int prev, double temp, double now, double *since){
    int next = fl_emergency_next(c, prev, temp);
    if (!prev && next) { *since = now; return 1; }
    if (prev && !next && now - *since < FL_EMERG_MIN_HOLD) return 1;
    return next;
}

// ── 是否需要（重）写 SMC ──────────────────────────────────────────
// 定速的全部意义是「写一次就不再动」⇒ 只在回读与目标不符时才写：
//   · md != 1  ⇒ 被交还了固件（别的程序 / 睡眠交接后 / SMC 复位）
//   · Tg 偏离  ⇒ 被别的程序改了目标
// 读失败（md_now < 0）按「需要写」处理：宁可多写一次，也不让风扇脱管。
static inline int fl_needs_rewrite(int md_now, double tg_now, double target){
    if (md_now != 1) return 1;
    double d = tg_now - target;
    if (d < 0) d = -d;
    return d > FL_REWRITE_TOLERANCE;
}

// ── 回读不一致时：是「别人改了」还是「我自己要改」？──────────────────
// 🩸 2026-10-29 实测：每次紧急打满 → 解除，守护都会让步 30 分钟、把风扇**卡在最高速**。
//    根因：拿 SMC 回读去和**新目标**比 —— 紧急进入时 Tg(3209) ≠ 新目标(5349)、解除时 Tg(5349) ≠ 3209，
//    都被记成「外部改动」，一进一出凑满 3 次 ⇒ 判定有人抢写 ⇒ 让步，停在自己刚写的上限上。
// 正解：拿回读和**我上次写进去的值**比。不一样才说明有人动过；只是目标变了（紧急 / 改档）是我自己的事。
//   last_written < 0 = 还没写过（刚启动 / 刚交还过固件）⇒ 无从判断，不算外部改动。
static inline int fl_is_external_change(int md_now, double tg_now, double last_written){
    if (last_written < 0) return 0;
    if (md_now != 1) return 1;                        // 我上次写的是手动，现在不是 ⇒ 有人交还了
    double d = tg_now - last_written; if (d < 0) d = -d;
    return d > FL_REWRITE_TOLERANCE;
}

// ── 哪些 SMC 键算「核心温度」（守护与 fanctl 共用，单一来源）──────────────
// 🩸 2026-10-28：fanctl 原来手写 5 个键，里面混着 TCMb / TVDP 两个**非核心**键（实测 TVDP 100.48 °C，
//    比所有核心都热）⇒ fanctl 的「最热」和守护的「最热核心」不是一回事。
// 规则：名字以 Tp 开头 · 类型 "flt " · 4 字节 · 读数在 (-5, 150) 内（排除未接线 / 溢出值）
static inline int fl_is_core_temp_key(const char *name, const char *type4, unsigned size, double v){
    return name[0] == 'T' && name[1] == 'p' && !strcmp(type4, "flt ") && size == 4 && v > -5 && v < 150;
}

// ── 睡眠期间要不要接管：只看「系统能力」这个事实 ─────────────────────
// 🩸 2026-10-28：本机睡眠时约每小时一次 DarkWake（rtc/Maintenance，用电池，5~9 s），Power Nap 关着也有。
//    旧逻辑收到「已唤醒」就接管 ⇒ 合盖放包里每小时把风扇冲向定速一次；
//    「醒着超过 30 s 就当已唤醒」的时长兜底在长 DarkWake 里也会误接管。
// ⇒ 只在系统能力含**显示**位（完全唤醒，盖子开着 / 用户在用）时接管；DarkWake 只有 CPU/网络位。
//    caps < 0 = 读不到：按「接管」处理（否则将来接口变了，FanPilot 会在每次唤醒后静默失效），调用方必须留痕。
#define FL_CAP_GRAPHICS 0x02          // = IOPM.h 的 kIOPMSystemCapabilityGraphics
static inline int fl_should_take_over(long caps){
    if (caps < 0) return 1;
    return (caps & FL_CAP_GRAPHICS) != 0;
}

// ── 写入令牌桶 ────────────────────────────────────────────────────
// 每次 SMC 写入取 1 枚；按 FL_WRITE_PER_HOUR 匀速回补，最多存 FL_WRITE_BURST 枚。
// 取不到 ⇒ 本次**不写**（调用方留痕）。时间用「醒着时钟」，睡眠不回补也不消耗。
typedef struct { double tokens, last; } fl_bucket;

static inline void fl_bucket_init(fl_bucket *b, double now){ b->tokens = FL_WRITE_BURST; b->last = now; }
static inline int fl_bucket_take(fl_bucket *b, double now, int n){
    double dt = now - b->last;
    if (dt > 0) {
        b->tokens += dt * FL_WRITE_PER_HOUR / 3600.0;
        if (b->tokens > FL_WRITE_BURST) b->tokens = FL_WRITE_BURST;
    }
    b->last = now;
    if (b->tokens < n) return 0;
    b->tokens -= n;
    return 1;
}

// ── 抢写检测 ──────────────────────────────────────────────────────
// 🩸 2026-09-14 事故形态：两个程序各自「纠正」对方，目标值在 3300 ↔ 2500 来回跳，
//    双方都不报错。⇒ 发现被反复改写时，FanPilot **让步**而不是加大力度。
typedef struct { double at[FL_FIGHT_COUNT]; int n; double yield_until; } fl_fight;

static inline void fl_fight_init(fl_fight *g){ memset(g, 0, sizeof *g); }
static inline int  fl_fight_yielding(const fl_fight *g, double now){ return now < g->yield_until; }
// 记一次外部改动；返回 1 = 刚刚进入让步
static inline int fl_fight_note(fl_fight *g, double now){
    // 滑动窗口：丢掉窗口外的旧记录
    int k = 0;
    for (int i = 0; i < g->n; i++) if (now - g->at[i] < FL_FIGHT_WINDOW) g->at[k++] = g->at[i];
    g->n = k;
    if (g->n < FL_FIGHT_COUNT) g->at[g->n++] = now;
    if (g->n >= FL_FIGHT_COUNT) {
        g->n = 0;
        g->yield_until = now + FL_FIGHT_YIELD;
        return 1;
    }
    return 0;
}

#endif

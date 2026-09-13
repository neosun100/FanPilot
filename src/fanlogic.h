// fanlogic.h —— FanPilot 的**纯决策逻辑**（零 IOKit 依赖，可单元测试）
//
// 为什么单独拆出来：这些是真正会出错的地方（曲线插值、安全夹取、限幅、故障状态机），
// 但它们原先和 IOKit 调用缠在一起，**只能靠跑真机观察，无法单元测试**。
// 剥离后 tests/unit_logic.c 可以直接喂输入验输出，覆盖边界与回归。
//
// 头文件内实现（static inline）：不引入额外编译单元，守护与测试都只 #include。

#ifndef FANLOGIC_H
#define FANLOGIC_H

#define FL_MAX_CURVE 12
#define FL_NFAN      2

// ── 配置 ──────────────────────────────────────────────────────────
typedef struct {
    double poll_interval;
    double min_rpm;
    double max_rpm;            // <=0 表示用硬件上限
    double ema_seconds;
    double slew_up, slew_down; // RPM/秒
    double deadband;           // RPM
    double emergency_temp;
    int    temp_source;        // 控制输入：0 = 最热核(max)，1 = 全核平均(average)
    int    curve_autoscale;    // 1 = 抬高下限时整条曲线跟着重新铺开（默认开）
    int    n_curve;
    struct { double t, rpm; } curve[FL_MAX_CURVE];
} fl_cfg;

static inline void fl_cfg_defaults(fl_cfg *c){
    c->poll_interval = 2.0;
    c->min_rpm       = 2000;
    c->max_rpm       = 0;
    c->ema_seconds   = 15.0;
    c->slew_up       = 200;
    c->slew_down     = 60;
    c->deadband      = 50;
    c->emergency_temp= 90;
    c->temp_source   = 1;      // 默认全核平均（使用者选定）
    c->curve_autoscale = 1;
    c->n_curve = 5;
    c->curve[0].t=45; c->curve[0].rpm=2000;
    c->curve[1].t=55; c->curve[1].rpm=2600;
    c->curve[2].t=65; c->curve[2].rpm=3400;
    c->curve[3].t=75; c->curve[3].rpm=4300;
    c->curve[4].t=85; c->curve[4].rpm=5300;
}

// ── 安全夹取：配置是**不可信输入**（对用户可写，否则菜单栏 App 改不了）
//
// 🔴 保护性阈值的边界必须来自代码，不能来自可被降级的配置。
//    实测踩过两个洞：max_rpm 设很低 ⇒ 紧急打满被挡；
//                    emergency_temp 设 200 ⇒ 紧急保护被整个禁用。
static inline void fl_cfg_clamp(fl_cfg *c){
    if (c->poll_interval < 0.5) c->poll_interval = 0.5;   // 别把守护写成 CPU 大户
    if (c->poll_interval > 30)  c->poll_interval = 30;    // 太慢来不及响应升温
    if (c->ema_seconds < 1)     c->ema_seconds = 1;
    if (c->ema_seconds > 120)   c->ema_seconds = 120;     // 平滑过久等于不响应
    if (c->emergency_temp > 95) c->emergency_temp = 95;   // ⭐ 不许把保护调没
    if (c->emergency_temp < 70) c->emergency_temp = 70;   // 也不许低到天天误触发
    if (c->slew_up < 10)        c->slew_up = 10;          // 太小等于升不上去
    if (c->deadband < 0)        c->deadband = 0;
    if (c->deadband > 500)      c->deadband = 500;        // 太大等于不控制
}

// ── ⭐ 曲线自适应重铺（curve_autoscale）───────────────────────────
//
// 问题：只靠 fl_clamp_fan 夹底会把曲线**压平**。
//   例：下限设 3000 时，默认曲线 45:2000 / 55:2600 / 65:3400
//       ⇒ 45°C 与 55°C 都被夹到 3000，**45~65°C 成为死区，没有比例响应**。
//
// 正解：把配置里的曲线当作**形状模板**，把它的 RPM 跨度线性映射到 [min_rpm, hi]：
//       rpm' = min_rpm + (rpm - curve_lo)/(curve_hi - curve_lo) * (hi - min_rpm)
//   ⇒ 抬高下限后整条曲线跟着重新铺开，温度→转速的梯度保持存在。
//
// 例（下限 3000、上限取硬件 5349）：
//   45°C 2000→3000 · 55°C 2600→3427 · 65°C 3400→3996 · 75°C 4300→4637 · 85°C 5300→5349
//
// ⚠️ 就地改写 cfg.curve，所以**只在配置加载后调用一次**，不可在主循环里反复调用
//    （否则每次都以上一次的结果为输入，曲线会持续漂移 —— 这类「幂等性陷阱」
//     本项目在 md=1 重复写那里已经栽过一次）。
static inline void fl_curve_rescale(fl_cfg *c, double hw_max){
    if (!c->curve_autoscale) return;      // 关掉时曲线原样使用（手工调过的不被改写）
    if (c->n_curve <= 0) return;
    double hi = hw_max;
    if (c->max_rpm > 0 && c->max_rpm < hi) hi = c->max_rpm;
    if (hi <= c->min_rpm) {                  // 上限不高于下限：整条压成常量下限
        for (int i = 0; i < c->n_curve; i++) c->curve[i].rpm = c->min_rpm;
        return;
    }
    double lo_src = c->curve[0].rpm, hi_src = c->curve[0].rpm;
    for (int i = 1; i < c->n_curve; i++) {
        if (c->curve[i].rpm < lo_src) lo_src = c->curve[i].rpm;
        if (c->curve[i].rpm > hi_src) hi_src = c->curve[i].rpm;
    }
    double span_src = hi_src - lo_src;
    if (span_src <= 0) {                     // 模板本身是平的：无形状可铺，全给下限
        for (int i = 0; i < c->n_curve; i++) c->curve[i].rpm = c->min_rpm;
        return;
    }
    double span_dst = hi - c->min_rpm;
    for (int i = 0; i < c->n_curve; i++) {
        double frac = (c->curve[i].rpm - lo_src) / span_src;
        c->curve[i].rpm = c->min_rpm + frac * span_dst;
    }
}

// ── 控制输入的选择 ────────────────────────────────────────────────
//
// temp_source: 0 = 最热核(max) · 1 = 全核平均(average)
//
// 🔴 **紧急保护路径永远用 max，不受此设置影响。**
//    实测本机两个核簇温差巨大（性能核 72~84°C，能效核 59~62°C），
//    5 个凉快的能效核把平均值拉低 **11.7°C**。
//    ⇒ 若按平均判 90°C 紧急阈值，最热核到 ~102°C 时平均才刚到 90 —— 保护形同废设。
//    这与本项目既有原则一致：保护性阈值的边界必须来自代码，不能来自可被降级的配置。
static inline double fl_control_temp(const fl_cfg *c, double hottest, double average){
    return c->temp_source == 1 ? average : hottest;
}
// 紧急判定：与曲线**使用同一个口径**（由 temp_source 决定）。
//
// 📌 2026-09-14 使用者明确选择：紧急判据也改看平均值，阈值保持 90°C。
//    我先用实测数据提过后果，使用者在知情后确认 ⇒ 按其决定实现。
//
// 后果（实测温差 2.0~7.8°C，高负载时曾达 11.7°C）：
//    平均 90°C 触发时，最热核实际约 95~102°C。
//    P 核约 100~105°C 开始重度降频。
// ⚠️ 但这**不是唯一防线**：macOS/SoC 自身有硬件级过热保护（降频，极端时强制关机），
//    本函数只是在其之上更早介入的一层优化。
//
// 想恢复"紧急看最热核"只需 temp_source = max（曲线也会一起变回最热核口径）。
static inline int fl_is_emergency(const fl_cfg *c, double hottest, double average){
    return fl_control_temp(c, hottest, average) >= c->emergency_temp;
}

// ── 曲线：分段线性插值 ────────────────────────────────────────────
static inline double fl_curve_eval(const fl_cfg *c, double t){
    if (c->n_curve <= 0) return c->min_rpm;
    if (t <= c->curve[0].t) return c->curve[0].rpm;
    for (int i = 1; i < c->n_curve; i++) {
        if (t <= c->curve[i].t) {
            double t0=c->curve[i-1].t, r0=c->curve[i-1].rpm;
            double t1=c->curve[i].t,   r1=c->curve[i].rpm;
            if (t1 <= t0) return r1;
            return r0 + (r1-r0) * (t-t0) / (t1-t0);
        }
    }
    return c->curve[c->n_curve-1].rpm;
}

// ── 夹到该风扇的合法区间。emergency=1 时**忽略用户 max_rpm**，只受硬件上限约束
static inline double fl_clamp_fan(const fl_cfg *c, double fmin, double fmax,
                                  double rpm, int emergency){
    double lo = c->min_rpm > fmin ? c->min_rpm : fmin;
    double hi = fmax;
    if (!emergency && c->max_rpm > 0 && c->max_rpm < hi) hi = c->max_rpm;
    if (hi < lo) hi = lo;
    if (rpm < lo) rpm = lo;
    if (rpm > hi) rpm = hi;
    return rpm;
}

// ── EMA 平滑。prev < 0 表示尚未初始化（首次直接取原值，避免从 0 慢慢爬）
static inline double fl_ema(double prev, double raw, double alpha){
    if (prev < 0) return raw;
    if (alpha > 1) alpha = 1;
    if (alpha < 0) alpha = 0;
    return alpha * raw + (1 - alpha) * prev;
}

// ── 变化率限幅（非对称：升快降慢）。emergency 时不限幅
static inline double fl_slew(const fl_cfg *c, double cur, double target,
                             double dt, int emergency){
    if (emergency) return target;
    double up = c->slew_up * dt, down = c->slew_down * dt;
    double d = target - cur;
    if (d >  up)   return cur + up;
    if (d < -down) return cur - down;
    return target;
}

// ── 死区：变化小于 deadband 就不写 SMC（写是唯一危险操作，能少写就少写）
static inline int fl_should_write(const fl_cfg *c, double last_written, double target){
    if (last_written < 0) return 1;
    double d = target - last_written;
    if (d < 0) d = -d;
    return d > c->deadband;
}

// ── 风扇故障状态机 ────────────────────────────────────────────────
//
// 只有守护有**历史**，才能区分「刚提速还没跟上」（正常，实测爬升 6~9s）
// 和「持续跟不上」（故障）。显示层只有瞬时值，判不了这件事。
#define FL_FAULT_RATIO   0.55   // 实际低于目标的这个比例算异常
#define FL_FAULT_CYCLES  6      // 连续这么多周期才判故障（2s 轮询 ⇒ 12s）
#define FL_SPINUP_GRACE  12.0   // 目标上调后的爬升宽限秒数

typedef struct {
    int    fault;
    int    cnt;
    double settle_at;    // 爬升宽限截止时刻
    double prev_target;
} fl_fan_state;

static inline void fl_fan_state_init(fl_fan_state *s){
    s->fault = 0; s->cnt = 0; s->settle_at = 0; s->prev_target = 0;
}

// 目标上调超过 100 RPM 就给爬升宽限。返回是否重置了宽限。
static inline int fl_note_target(fl_fan_state *s, double target, double now){
    int bumped = (target > s->prev_target + 100);
    if (bumped) s->settle_at = now + FL_SPINUP_GRACE;
    s->prev_target = target;
    return bumped;
}

// 返回 1 = 故障态。onset 非 NULL 时 *onset=1 表示本次**刚刚**判定为故障（用于打日志）
static inline int fl_fault_check(fl_fan_state *s, double target, double actual,
                                 double now, int *onset){
    if (onset) *onset = 0;
    if (target < 1000 || actual < 0) { s->cnt = 0; s->fault = 0; return 0; }
    if (now < s->settle_at) return s->fault;          // 爬升宽限期内不判
    if (actual < target * FL_FAULT_RATIO) {
        if (s->cnt < 100000) s->cnt++;
        if (s->cnt >= FL_FAULT_CYCLES && !s->fault) {
            s->fault = 1;
            if (onset) *onset = 1;
        }
    } else {
        s->cnt = 0; s->fault = 0;
    }
    return s->fault;
}

#endif // FANLOGIC_H

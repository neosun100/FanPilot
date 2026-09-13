// fanpilotd —— 自适应风扇温控守护（root LaunchDaemon）
//
// 设计依据全部来自实测，见 docs/SMC-RESEARCH.md 与 docs/PLAN.md。
// 控制链（五层，每层解决一个具体抖动来源）：
//   23×Tp* → max() → EMA平滑 → 分段曲线 → 变化率限幅 → 死区 → 写SMC
//
// 失效安全（PLAN §4.1，原设计已被实测推翻后的修正版）：
//   · 正常退出/SIGTERM → 写 F*md=0 交还固件
//   · SIGKILL/崩溃      → 靠 launchd KeepAlive 约 1s 重新接管
//                         （SMC 实测不会自动回退；风扇保持最后转速，
//                          配 min_rpm 下限 ⇒ 最坏也比出厂空闲的 0 转风量大）
//   · 传感器读失败      → 立即交还固件，不用陈旧值继续控制
//
// 编译: clang -O2 -framework IOKit -framework CoreFoundation -o fanpilotd fanpilotd.c

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <IOKit/IOKitLib.h>

#define KIDX 2
#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_KEYINFO 9
#define CMD_READ_INDEX   8

#define MAX_SENSORS 64
#define MAX_CURVE   12
#define NFAN        2

typedef struct { uint8_t a,b,c,d; uint16_t r; } SVer;
typedef struct { uint16_t v,l; uint32_t a,b,c; } SPLim;
typedef struct { uint32_t size, type; uint8_t attr; } SInfo;
typedef struct {
    uint32_t key; SVer vers; SPLim plim; SInfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SData;

// ── 缓存的键句柄：keyinfo 只在启动时问一次（实测省掉每周期一次 IOKit 往返）
typedef struct { char name[5]; uint32_t size, type; uint8_t attr; int valid; } Key;

static io_connect_t g_conn = 0;
static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_reload = 0;

// ── 配置（默认值即可用；配置文件可覆盖）
static struct {
    double poll_interval;     // 秒
    double min_rpm;           // 下限（用户要求默认 2000）
    double max_rpm;           // 上限；<=0 表示用各风扇的硬件上限 F*Mx
    double ema_seconds;       // 平滑时间常数
    double slew_up, slew_down;// RPM/秒
    double deadband;          // RPM，小于此变化不写
    double emergency_temp;    // 超过此温度直接打满并忽略限幅
    int    n_curve;
    struct { double t, rpm; } curve[MAX_CURVE];
} cfg;

static void cfg_defaults(void){
    cfg.poll_interval = 2.0;
    cfg.min_rpm       = 2000;
    cfg.max_rpm       = 0;        // 0 = 硬件上限
    cfg.ema_seconds   = 15.0;
    cfg.slew_up       = 200;
    cfg.slew_down     = 60;
    cfg.deadband      = 50;
    cfg.emergency_temp= 90;
    cfg.n_curve = 5;
    cfg.curve[0] = (typeof(cfg.curve[0])){45, 2000};
    cfg.curve[1] = (typeof(cfg.curve[0])){55, 2600};
    cfg.curve[2] = (typeof(cfg.curve[0])){65, 3400};
    cfg.curve[3] = (typeof(cfg.curve[0])){75, 4300};
    cfg.curve[4] = (typeof(cfg.curve[0])){85, 5300};
}

// ───────────────────────── SMC 基础层 ─────────────────────────

static uint32_t s2k(const char *s){
    return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)
         | ((uint32_t)(uint8_t)s[2]<<8) | (uint32_t)(uint8_t)s[3];
}
static void k2s(uint32_t k, char *o){
    o[0]=(k>>24)&255; o[1]=(k>>16)&255; o[2]=(k>>8)&255; o[3]=k&255; o[4]=0;
}

// S1 键白名单：唯一允许写入的 4 个键
static int is_writable_key(const char *k){
    static const char *W[] = {"F0md","F1md","F0Tg","F1Tg",NULL};
    for (int i=0; W[i]; i++) if (!strcmp(k, W[i])) return 1;
    return 0;
}

static int smc_open(void){
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static kern_return_t smc_call(SData *in, SData *out){
    size_t n = sizeof(SData); memset(out, 0, n);
    return IOConnectCallStructMethod(g_conn, KIDX, in, sizeof(SData), out, &n);
}

static int key_init(Key *k, const char *name){
    strncpy(k->name, name, 4); k->name[4] = 0; k->valid = 0;
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(name); in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    k->size = out.info.size; k->type = out.info.type; k->attr = out.info.attr;
    k->valid = 1; return 0;
}

// 用缓存句柄读原始字节 —— 守护热路径只走这里
static int key_read(const Key *k, uint8_t *buf){
    if (!k->valid) return -1;
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(k->name); in.data8 = CMD_READ_BYTES; in.info.size = k->size;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(buf, out.bytes, k->size > 32 ? 32 : k->size);
    return 0;
}
static int key_read_flt(const Key *k, double *v){
    uint8_t b[32];
    if (k->size != 4 || key_read(k, b) != 0) return -1;
    float f; memcpy(&f, b, 4); *v = f; return 0;
}
static int key_read_u8(const Key *k, int *v){
    uint8_t b[32];
    if (k->size < 1 || key_read(k, b) != 0) return -1;
    *v = b[0]; return 0;
}

static int key_write(const Key *k, const uint8_t *data, uint32_t len){
    if (!k->valid) return -1;
    if (!is_writable_key(k->name)) {                       // S1
        fprintf(stderr, "⛔ 拒绝写非白名单键 %s\n", k->name); return -2; }
    if (k->size != len) {
        fprintf(stderr, "⛔ %s 长度不符 (SMC=%u, 给=%u)\n", k->name, k->size, len); return -2; }
    if (!(k->attr & 0x40)) {                               // 实测: 0x40 = 可写
        fprintf(stderr, "⛔ %s 无可写位 (attr=0x%02x)\n", k->name, k->attr); return -2; }
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(k->name); in.data8 = CMD_WRITE_BYTES; in.info.size = len;
    memcpy(in.bytes, data, len > 32 ? 32 : len);
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) {
        fprintf(stderr, "✗ 写 %s 失败 result=%u\n", k->name, out.result); return -1; }
    return 0;
}
static int key_write_flt(const Key *k, double v){ float f=(float)v; uint8_t b[4];
    memcpy(b,&f,4); return key_write(k,b,4); }
static int key_write_u8(const Key *k, uint8_t v){ return key_write(k,&v,1); }

// ───────────────────────── 状态 ─────────────────────────

static Key  g_temp[MAX_SENSORS];  static int g_ntemp = 0;   // Tp* 簇
static Key  g_md[NFAN], g_tg[NFAN], g_ac[NFAN], g_mn[NFAN], g_mx[NFAN];
static double g_fmin[NFAN], g_fmax[NFAN];                    // 运行时读到的硬件上下限
static double g_ema = -1;                                    // EMA 状态
static double g_cur_target[NFAN];                            // 已限幅的当前目标
static double g_last_written[NFAN] = {-1,-1};                 // 死区比较基准
static long   g_writes = 0;

// 枚举 Tp* 簇（启动时一次）
static int enum_sensors(void){
    Key nk; if (key_init(&nk, "#KEY") != 0) return -1;
    uint8_t b[32]; if (key_read(&nk, b) != 0) return -1;
    uint32_t total = ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|(b[2]<<8)|b[3];

    for (uint32_t i = 0; i < total && g_ntemp < MAX_SENSORS; i++) {
        SData in, out; memset(&in, 0, sizeof in);
        in.data8 = CMD_READ_INDEX; in.data32 = i;
        if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) continue;
        char n[5]; k2s(out.key, n);
        if (n[0] != 'T' || n[1] != 'p') continue;
        Key k; if (key_init(&k, n) != 0) continue;
        char t[5]; k2s(k.type, t);
        if (strcmp(t, "flt ") || k.size != 4) continue;
        double v; if (key_read_flt(&k, &v) != 0) continue;
        if (v < -5 || v > 150) continue;          // 明显无效
        g_temp[g_ntemp++] = k;
    }
    return g_ntemp > 0 ? 0 : -1;
}

// 取 Tp* 簇最大值。取 max 不取平均：平均会被冷核拉低，漏掉局部热点。
static int read_hottest(double *out){
    double hot = -1e9; int got = 0;
    for (int i = 0; i < g_ntemp; i++) {
        double v;
        if (key_read_flt(&g_temp[i], &v) == 0 && v > -5 && v < 150) {
            if (v > hot) hot = v; got++;
        }
    }
    if (!got) return -1;
    *out = hot; return 0;
}

// 分段线性曲线：温度 → 目标 RPM
static double curve_eval(double t){
    if (cfg.n_curve == 0) return cfg.min_rpm;
    if (t <= cfg.curve[0].t) return cfg.curve[0].rpm;
    for (int i = 1; i < cfg.n_curve; i++) {
        if (t <= cfg.curve[i].t) {
            double t0 = cfg.curve[i-1].t, r0 = cfg.curve[i-1].rpm;
            double t1 = cfg.curve[i].t,   r1 = cfg.curve[i].rpm;
            if (t1 <= t0) return r1;
            return r0 + (r1 - r0) * (t - t0) / (t1 - t0);
        }
    }
    return cfg.curve[cfg.n_curve-1].rpm;
}

// 把目标夹到该风扇的合法区间（S2：上下限运行时读取，不硬编码）
//
// ⚠️ emergency=1 时**忽略用户配置的 max_rpm**，只受硬件上限约束。
//    🩸 初版没有这个参数，于是留了个洞：配置文件为了让菜单栏 App 能改而对用户可写，
//       若 max_rpm 被设得很低（手误，或以用户身份运行的恶意程序），
//       90°C 的紧急打满会被这个用户上限挡住 —— **安全路径不该受用户配置约束**。
//    通则：保护性逻辑的边界必须来自硬件/系统，不能来自可被降级的配置。
static double clamp_fan(int f, double rpm, int emergency){
    double lo = cfg.min_rpm > g_fmin[f] ? cfg.min_rpm : g_fmin[f];
    double hi = g_fmax[f];
    if (!emergency && cfg.max_rpm > 0 && cfg.max_rpm < hi) hi = cfg.max_rpm;
    if (hi < lo) hi = lo;
    if (rpm < lo) rpm = lo;
    if (rpm > hi) rpm = hi;
    return rpm;
}

// 失效安全：交还固件
static void fans_to_firmware(void){
    for (int f = 0; f < NFAN; f++) key_write_u8(&g_md[f], 0);
}

static void on_signal(int sig){
    if (sig == SIGHUP) { g_reload = 1; return; }
    g_stop = 1;
}

// ───────────────────────── 配置 ─────────────────────────

static void parse_curve(char *v){
    cfg.n_curve = 0;
    char *save = NULL;
    for (char *tok = strtok_r(v, ",", &save);
         tok && cfg.n_curve < MAX_CURVE;
         tok = strtok_r(NULL, ",", &save)) {
        double t, r;
        if (sscanf(tok, " %lf : %lf", &t, &r) == 2) {
            cfg.curve[cfg.n_curve].t = t;
            cfg.curve[cfg.n_curve].rpm = r;
            cfg.n_curve++;
        }
    }
}

// key = value 格式。比 JSON 简单且不需要引入解析器 —— 配置面本来就小。
static void cfg_load(const char *path){
    FILE *fp = fopen(path, "r");
    if (!fp) return;                       // 没有配置文件就用默认值，不算错误
    char line[512];
    while (fgets(line, sizeof line, fp)) {
        char *h = strchr(line, '#'); if (h) *h = 0;
        char k[64], v[400];
        if (sscanf(line, " %63[^= ] = %399[^\n]", k, v) != 2) continue;
        char *e = v + strlen(v); while (e > v && (e[-1]==' '||e[-1]=='\t')) *--e = 0;
        if      (!strcmp(k,"poll_interval"))  cfg.poll_interval = atof(v);
        else if (!strcmp(k,"min_rpm"))        cfg.min_rpm       = atof(v);
        else if (!strcmp(k,"max_rpm"))        cfg.max_rpm       = atof(v);
        else if (!strcmp(k,"ema_seconds"))    cfg.ema_seconds   = atof(v);
        else if (!strcmp(k,"slew_up"))        cfg.slew_up       = atof(v);
        else if (!strcmp(k,"slew_down"))      cfg.slew_down     = atof(v);
        else if (!strcmp(k,"deadband"))       cfg.deadband      = atof(v);
        else if (!strcmp(k,"emergency_temp")) cfg.emergency_temp= atof(v);
        else if (!strcmp(k,"curve"))          parse_curve(v);
    }
    fclose(fp);

    // ── 🔴 配置是**不可信输入**，安全相关的值必须硬夹，不能相信文件里写的
    //
    // 为什么：配置文件对普通用户可写（否则菜单栏 App 改不了配置）。
    // 于是手误或以用户身份运行的程序都能改它。安全阈值若可被配置任意放大，
    // 保护就等于不存在。
    //   🩸 实测发现的两个洞：
    //     ① max_rpm 设很低 ⇒ 紧急打满被用户上限挡住（已在 clamp_fan 用 emergency 参数修）
    //     ② emergency_temp 设 200 ⇒ **紧急保护被整个禁用**（本处修）
    // ⭐ 通则：保护性阈值的边界必须来自代码/硬件，不能来自可被降级的配置。
    if (cfg.poll_interval < 0.5) cfg.poll_interval = 0.5;   // 防止把自己写成 CPU 大户
    if (cfg.poll_interval > 30)  cfg.poll_interval = 30;    // 太慢会来不及响应升温
    if (cfg.ema_seconds < 1)     cfg.ema_seconds = 1;
    if (cfg.ema_seconds > 120)   cfg.ema_seconds = 120;     // 平滑过久等于不响应
    if (cfg.emergency_temp > 95) cfg.emergency_temp = 95;   // ⭐ 硬上限：不许把保护调没
    if (cfg.emergency_temp < 70) cfg.emergency_temp = 70;   // 也不许低到天天误触发
    if (cfg.slew_up < 10)        cfg.slew_up = 10;          // 太小等于升不上去
    if (cfg.deadband < 0)        cfg.deadband = 0;
    if (cfg.deadband > 500)      cfg.deadband = 500;        // 太大等于不控制
}

static void write_status(const char *path, double hot, double ema,
                        double ac[], double tg[], const char *mode){
    char tmp[512]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *fp = fopen(tmp, "w");
    if (!fp) return;
    // ⭐ 把**生效中的**配置也写进来：验收/UI 一律读这一份机器可读的源，
    //    绝不去解析 fanpilot.conf（那份带人写的注释，注释里的数字会被解析器吃进去
    //    —— 实测踩过：min_rpm 被解析成 20009，因为注释里有 "kill -9"）。
    fprintf(fp,
      "{\n  \"ts\": %ld,\n  \"mode\": \"%s\",\n"
      "  \"temp_hottest_c\": %.2f,\n  \"temp_smoothed_c\": %.2f,\n"
      "  \"sensors\": %d,\n  \"writes_total\": %ld,\n"
      "  \"config\": {\"min_rpm\": %.0f, \"max_rpm\": %.0f, \"poll_interval\": %.2f,"
      " \"ema_seconds\": %.1f, \"slew_up\": %.0f, \"slew_down\": %.0f, \"deadband\": %.0f},\n"
      "  \"fans\": [\n",
      (long)time(NULL), mode, hot, ema, g_ntemp, g_writes,
      cfg.min_rpm, cfg.max_rpm, cfg.poll_interval,
      cfg.ema_seconds, cfg.slew_up, cfg.slew_down, cfg.deadband);
    for (int f = 0; f < NFAN; f++)
        fprintf(fp, "    {\"id\": %d, \"actual_rpm\": %.0f, \"target_rpm\": %.0f,"
                    " \"min\": %.0f, \"max\": %.0f}%s\n",
                f, ac[f], tg[f], g_fmin[f], g_fmax[f], f==NFAN-1?"":",");
    fprintf(fp, "  ]\n}\n");
    fclose(fp);
    rename(tmp, path);                    // 原子替换，读者永远看不到半个文件
}

// ───────────────────────── 主循环 ─────────────────────────

int main(int argc, char **argv){
    const char *cfg_path    = "/usr/local/etc/fanpilot.conf";
    const char *status_path = "/var/run/fanpilot.status.json";
    int oneshot = 0, check_only = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--config") && i+1 < argc) cfg_path = argv[++i];
        else if (!strcmp(argv[i], "--status") && i+1 < argc) status_path = argv[++i];
        else if (!strcmp(argv[i], "--oneshot")) oneshot = 1;
        else if (!strcmp(argv[i], "--check-config")) check_only = 1;
    }

    cfg_defaults();
    cfg_load(cfg_path);

    // --check-config：只加载并打印**生效后**的配置就退出。
    // 不占单实例锁、不打开 SMC —— 所以可以在守护正常运行时随时校验一份配置文件。
    // （加这个模式的直接原因：测「恶意配置能否绕过安全夹取」时被单实例锁挡住了，
    //   说明缺一条「只读校验」的路径。安全机制不该妨碍对安全机制的测试。）
    if (check_only) {
        printf("poll_interval=%.2f\nmin_rpm=%.0f\nmax_rpm=%.0f\nema_seconds=%.1f\n"
               "slew_up=%.0f\nslew_down=%.0f\ndeadband=%.0f\nemergency_temp=%.1f\n"
               "curve_points=%d\n",
               cfg.poll_interval, cfg.min_rpm, cfg.max_rpm, cfg.ema_seconds,
               cfg.slew_up, cfg.slew_down, cfg.deadband, cfg.emergency_temp, cfg.n_curve);
        for (int i = 0; i < cfg.n_curve; i++)
            printf("curve%d=%.1f:%.0f\n", i, cfg.curve[i].t, cfg.curve[i].rpm);
        return 0;
    }

    // ── 🩸 单实例锁（Phase 1 测试实测踩到的缺陷）
    //
    // 事故还原：一个前台测试实例与 launchd 管的实例**同时运行**，
    // 两者各自独立算曲线、抢写同一组 SMC 寄存器，目标值互相踩（实测漂移 2115→2209）。
    // 这类竞争不会报错，只会让转速看起来「有点怪」—— 极难发现。
    //
    // ⚠️ 锁必须在**打开 SMC 之前**拿到，否则第二个实例已经能读写硬件了。
    // flock 在进程死亡（含 SIGKILL）时由内核自动释放，正好适合 KeepAlive 重启场景。
    {
        const char *lock_path = "/var/run/fanpilotd.lock";
        int lf = open(lock_path, O_CREAT | O_RDWR, 0644);
        if (lf < 0) {
            // 降级留痕：拿不到锁文件就说清楚，不静默继续（否则又是一次静默竞争）
            fprintf(stderr, "⚠️ 打不开锁文件 %s: %s —— 无法保证单实例\n",
                    lock_path, strerror(errno));
        } else if (flock(lf, LOCK_EX | LOCK_NB) != 0) {
            fprintf(stderr,
                "✗ 已有另一个 fanpilotd 在运行（锁 %s 被占用）—— 拒绝启动。\n"
                "  两个实例会抢写同一组 SMC 寄存器。先停掉旧的：\n"
                "    sudo launchctl bootout system/com.newmac.fanpilotd\n"
                "    sudo pkill -x fanpilotd     # ⚠️ 必须 sudo，root 进程用户态 pkill 杀不掉\n",
                lock_path);
            return 4;
        }
        // 故意不 close(lf)：锁随进程生命周期，进程退出时内核释放
    }

    if (smc_open() != 0) { fprintf(stderr, "✗ 打不开 SMC\n"); return 1; }

    // 缓存全部键句柄
    for (int f = 0; f < NFAN; f++) {
        char n[8];
        snprintf(n,8,"F%dmd",f); key_init(&g_md[f], n);
        snprintf(n,8,"F%dTg",f); key_init(&g_tg[f], n);
        snprintf(n,8,"F%dAc",f); key_init(&g_ac[f], n);
        snprintf(n,8,"F%dMn",f); key_init(&g_mn[f], n);
        snprintf(n,8,"F%dMx",f); key_init(&g_mx[f], n);
        if (key_read_flt(&g_mn[f], &g_fmin[f]) != 0) g_fmin[f] = 1350;
        if (key_read_flt(&g_mx[f], &g_fmax[f]) != 0) g_fmax[f] = 4000;
    }
    if (enum_sensors() != 0) { fprintf(stderr, "✗ 找不到 Tp* 传感器\n"); return 1; }

    fprintf(stderr, "fanpilotd 启动: %d 个传感器 · 风扇0 %.0f~%.0f · 风扇1 %.0f~%.0f\n"
                    "  轮询 %.1fs · 下限 %.0f · 上限 %s · EMA %.0fs · 限幅 +%.0f/-%.0f · 死区 %.0f\n",
            g_ntemp, g_fmin[0], g_fmax[0], g_fmin[1], g_fmax[1],
            cfg.poll_interval, cfg.min_rpm,
            cfg.max_rpm > 0 ? "见配置" : "硬件上限",
            cfg.ema_seconds, cfg.slew_up, cfg.slew_down, cfg.deadband);

    signal(SIGTERM, on_signal); signal(SIGINT, on_signal); signal(SIGHUP, on_signal);

    // 起步：先 md=1 再写 Tg（PLAN §4.2：顺序反了会有「已切手动但目标为0」窗口）
    for (int f = 0; f < NFAN; f++) {
        g_cur_target[f] = clamp_fan(f, cfg.min_rpm, 0);
        if (key_write_u8(&g_md[f], 1) != 0) {
            fprintf(stderr, "✗ 无法切手动模式（需要 root）—— 退出\n");
            return 1;
        }
        key_write_flt(&g_tg[f], g_cur_target[f]);
        g_last_written[f] = g_cur_target[f];
        g_writes++;
    }

    double alpha = cfg.poll_interval / cfg.ema_seconds;
    if (alpha > 1) alpha = 1;

    while (!g_stop) {
        if (g_reload) { g_reload = 0; cfg_load(cfg_path);
            alpha = cfg.poll_interval / cfg.ema_seconds; if (alpha>1) alpha=1;
            fprintf(stderr, "配置已热加载\n"); }

        double hot;
        if (read_hottest(&hot) != 0) {
            // S5 降级留痕：读不到温度就交还固件，绝不用陈旧值继续控制
            fprintf(stderr, "⚠️ 传感器读取失败 → 交还固件自动控制\n");
            fans_to_firmware();
            double z[NFAN] = {0,0};
            write_status(status_path, -1, -1, z, z, "failsafe_sensor_read_failed");
            sleep(5);
            continue;
        }

        // ② EMA 平滑（杀瞬时尖峰）
        g_ema = (g_ema < 0) ? hot : (alpha * hot + (1 - alpha) * g_ema);

        int emergency = hot >= cfg.emergency_temp;   // S6 用**原始**温度，不用平滑值
        double want = emergency ? 1e9 : curve_eval(g_ema);

        double ac[NFAN], tg[NFAN];
        for (int f = 0; f < NFAN; f++) {
            double target = clamp_fan(f, want, emergency);

            // ④ 变化率限幅（非对称：升快降慢）；紧急情况忽略限幅
            if (!emergency) {
                double max_up   = cfg.slew_up   * cfg.poll_interval;
                double max_down = cfg.slew_down * cfg.poll_interval;
                double d = target - g_cur_target[f];
                if (d >  max_up)   target = g_cur_target[f] + max_up;
                if (d < -max_down) target = g_cur_target[f] - max_down;
            }
            g_cur_target[f] = target;

            // ⑤ 死区：写 SMC 是唯一危险操作，能少写就少写
            //
            // 🩸 初版在这里无条件重写 md=1「幂等地维持手动模式」，实测把写入次数
            //    整整翻了一倍（24~30 次/分 中有一半是纯浪费）。
            //    改成**先读后判**：读一次只要 0.145ms，比一次无谓写入便宜得多。
            //    通则：幂等 ≠ 免费。写操作的幂等性不能当作可以随便重复的理由。
            int md_now;
            if (key_read_u8(&g_md[f], &md_now) == 0 && md_now != 1) {
                key_write_u8(&g_md[f], 1);          // 只在真的不是手动时才纠正
                g_writes++;
            }
            if (g_last_written[f] < 0 ||
                (target - g_last_written[f] >  cfg.deadband) ||
                (g_last_written[f] - target >  cfg.deadband)) {
                if (key_write_flt(&g_tg[f], target) == 0) {
                    g_last_written[f] = target; g_writes++;
                }
            }
            if (key_read_flt(&g_ac[f], &ac[f]) != 0) ac[f] = -1;
            tg[f] = target;
        }

        write_status(status_path, hot, g_ema, ac, tg,
                     emergency ? "emergency" : "normal");
        if (oneshot) break;
        usleep((useconds_t)(cfg.poll_interval * 1e6));
    }

    // 正常退出/SIGTERM：交还固件（SIGKILL 走不到这里，靠 launchd KeepAlive）
    fprintf(stderr, "收到退出信号 → 交还固件自动控制\n");
    fans_to_firmware();
    double z[NFAN] = {0,0};
    write_status(status_path, -1, -1, z, z, "stopped_firmware_auto");
    if (g_conn) IOServiceClose(g_conn);
    return 0;
}

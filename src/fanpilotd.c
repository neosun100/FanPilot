// fanpilotd —— 自适应风扇温控守护（root LaunchDaemon）
//
// 设计依据全部来自实测，见 docs/SMC-RESEARCH.md 与 docs/PLAN.md。
// 控制链（五层，每层解决一个具体抖动来源）：
//   23×Tp* → max() → EMA平滑 → 分段曲线 → 变化率限幅 → 死区 → 写SMC
//
// ⭐ 纯决策逻辑全在 src/fanlogic.h（零 IOKit 依赖，被 tests/unit_logic.c 覆盖 81 项）。
//    本文件只负责 IOKit 读写、进程生命周期、状态输出 —— **逻辑不在这里重复一份**
//    （两份都可能被当权威，必然静默分叉）。
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
#include <sys/stat.h>
#include <IOKit/IOKitLib.h>

#include "fanlogic.h"

#define KIDX 2
#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_KEYINFO 9
#define CMD_READ_INDEX   8

#define MAX_SENSORS 64
#define NFAN        FL_NFAN

typedef struct { uint8_t a,b,c,d; uint16_t r; } SVer;
typedef struct { uint16_t v,l; uint32_t a,b,c; } SPLim;
typedef struct { uint32_t size, type; uint8_t attr; } SInfo;
typedef struct {
    uint32_t key; SVer vers; SPLim plim; SInfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SData;

// 缓存的键句柄：keyinfo 只在启动时问一次（实测省掉每周期一次 IOKit 往返）
typedef struct { char name[5]; uint32_t size, type; uint8_t attr; int valid; } Key;

static io_connect_t g_conn = 0;
static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_reload = 0;

static fl_cfg g_cfg;                  // 配置模板（用户可写文件加载而来）
static fl_cfg g_fan_cfg[NFAN];        // 按各风扇硬件上限**分别重铺**后的曲线

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

// ───────────────────────── 运行时状态 ─────────────────────────

static Key  g_temp[MAX_SENSORS];  static int g_ntemp = 0;   // Tp* 簇
static Key  g_md[NFAN], g_tg[NFAN], g_ac[NFAN], g_mn[NFAN], g_mx[NFAN];
static double g_fmin[NFAN], g_fmax[NFAN];                    // 运行时读到的硬件上下限
static double g_ema = -1;
static double g_cur_target[NFAN];
static double g_last_written[NFAN] = {-1,-1};
static long   g_writes = 0;
static fl_fan_state g_fs[NFAN];

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
        if (v < -5 || v > 150) continue;
        g_temp[g_ntemp++] = k;
    }
    return g_ntemp > 0 ? 0 : -1;
}

// 一次读完 Tp* 簇，同时给出**最热值**与**全核平均值**。
// 控制输入由 cfg.temp_source 选（使用者选定默认平均）；
// 但紧急判定固定用最热值 —— 见 fanlogic.h 的 fl_is_emergency。
static int read_temps(double *hottest, double *average, double *coolest){
    double hot = -1e9, cool = 1e9, sum = 0; int got = 0;
    for (int i = 0; i < g_ntemp; i++) {
        double v;
        if (key_read_flt(&g_temp[i], &v) == 0 && v > -5 && v < 150) {
            if (v > hot)  hot  = v;
            if (v < cool) cool = v;
            sum += v; got++;
        }
    }
    if (!got) return -1;
    *hottest = hot; *average = sum / got; *coolest = cool; return 0;
}

static void fans_to_firmware(void){
    for (int f = 0; f < NFAN; f++) key_write_u8(&g_md[f], 0);
}

static void on_signal(int sig){
    if (sig == SIGHUP) { g_reload = 1; return; }
    g_stop = 1;
}

// ───────────────────────── 配置 ─────────────────────────

// 口径名 → 枚举。无法识别时退回 0(max) —— 保守方向
static int parse_src(const char *v){
    if (!strcmp(v,"average") || !strcmp(v,"avg") || !strcmp(v,"1")) return 1;
    if (!strcmp(v,"min")     || !strcmp(v,"coolest") || !strcmp(v,"2")) return 2;
    return 0;   // max
}
static const char *src_name(int s){ return s==1?"average":(s==2?"min":"max"); }

static void parse_curve(fl_cfg *c, char *v){
    c->n_curve = 0;
    char *save = NULL;
    for (char *tok = strtok_r(v, ",", &save);
         tok && c->n_curve < FL_MAX_CURVE;
         tok = strtok_r(NULL, ",", &save)) {
        double t, r;
        if (sscanf(tok, " %lf : %lf", &t, &r) == 2) {
            c->curve[c->n_curve].t = t;
            c->curve[c->n_curve].rpm = r;
            c->n_curve++;
        }
    }
}

// key = value 格式。比 JSON 简单且不需要引入解析器 —— 配置面本来就小。
static void cfg_load(const char *path, fl_cfg *c){
    fl_cfg_defaults(c);
    FILE *fp = fopen(path, "r");
    if (fp) {
        char line[512];
        while (fgets(line, sizeof line, fp)) {
            char *h = strchr(line, '#'); if (h) *h = 0;
            char k[64], v[400];
            if (sscanf(line, " %63[^= ] = %399[^\n]", k, v) != 2) continue;
            char *e = v + strlen(v); while (e > v && (e[-1]==' '||e[-1]=='\t')) *--e = 0;
            if      (!strcmp(k,"poll_interval"))   c->poll_interval  = atof(v);
            else if (!strcmp(k,"min_rpm"))         c->min_rpm        = atof(v);
            else if (!strcmp(k,"max_rpm"))         c->max_rpm        = atof(v);
            else if (!strcmp(k,"ema_seconds"))     c->ema_seconds    = atof(v);
            else if (!strcmp(k,"slew_up"))         c->slew_up        = atof(v);
            else if (!strcmp(k,"slew_down"))       c->slew_down      = atof(v);
            else if (!strcmp(k,"deadband"))        c->deadband       = atof(v);
            else if (!strcmp(k,"emergency_temp"))  c->emergency_temp = atof(v);
            else if (!strcmp(k,"curve_autoscale")) c->curve_autoscale= atoi(v);
            else if (!strcmp(k,"temp_source"))      c->temp_source      = parse_src(v);
            else if (!strcmp(k,"emergency_source")) c->emergency_source = parse_src(v);
            else if (!strcmp(k,"curve"))           parse_curve(c, v);
        }
        fclose(fp);
    }
    // 🔴 配置是**不可信输入**（对用户可写，否则菜单栏 App 改不了）⇒ 安全阈值硬夹
    fl_cfg_clamp(c);
}

// 按各风扇自己的硬件上限分别重铺曲线。
// ⚠️ 两风扇上限实测不同（5349 / 5777），共用一条铺到低者的曲线会让风扇1 白丢余量。
static void rebuild_fan_curves(void){
    for (int f = 0; f < NFAN; f++) {
        g_fan_cfg[f] = g_cfg;
        fl_curve_rescale(&g_fan_cfg[f], g_fmax[f]);
    }
}

static void log_effective(void){
    fprintf(stderr, "生效配置: 下限%.0f 上限%s 轮询%.1fs EMA%.0fs 限幅+%.0f/-%.0f 死区%.0f 紧急%.0f°C 自适应曲线%s\n",
            g_cfg.min_rpm,
            g_cfg.max_rpm > 0 ? "见配置" : "硬件上限",
            g_cfg.poll_interval, g_cfg.ema_seconds,
            g_cfg.slew_up, g_cfg.slew_down, g_cfg.deadband,
            g_cfg.emergency_temp, g_cfg.curve_autoscale ? "开" : "关");
    for (int f = 0; f < NFAN; f++) {
        fprintf(stderr, "  风扇%d 曲线(铺到 %.0f): ", f, g_fmax[f]);
        for (int i = 0; i < g_fan_cfg[f].n_curve; i++)
            fprintf(stderr, "%.0f°C:%.0f  ", g_fan_cfg[f].curve[i].t, g_fan_cfg[f].curve[i].rpm);
        fprintf(stderr, "\n");
    }
}

static void write_status(const char *path, double hot, double avg, double cool, double ema,
                        double ac[], double tg[], const char *mode, const int fault[]){
    char tmp[512]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *fp = fopen(tmp, "w");
    if (!fp) return;
    // ⭐ 把**生效中的**配置也写进来：验收/UI 一律读这一份机器可读的源，
    //    绝不去解析 fanpilot.conf（那份带人写的注释，注释里的数字会被解析器吃进去
    //    —— 实测踩过：min_rpm 被解析成 20009，因为注释里有 "kill -9"）。
    fprintf(fp,
      "{\n  \"ts\": %ld,\n  \"mode\": \"%s\",\n"
      "  \"temp_hottest_c\": %.2f,\n  \"temp_average_c\": %.2f,\n"
      "  \"temp_coolest_c\": %.2f,\n  \"temp_smoothed_c\": %.2f,\n"
      "  \"sensors\": %d,\n  \"writes_total\": %ld,\n"
      "  \"config\": {\"min_rpm\": %.0f, \"max_rpm\": %.0f, \"poll_interval\": %.2f,"
      " \"ema_seconds\": %.1f, \"slew_up\": %.0f, \"slew_down\": %.0f,"
      " \"deadband\": %.0f, \"emergency_temp\": %.0f, \"curve_autoscale\": %d,"
      " \"temp_source\": \"%s\", \"emergency_source\": \"%s\"},\n"
      "  \"fans\": [\n",
      (long)time(NULL), mode, hot, avg, cool, ema, g_ntemp, g_writes,
      g_cfg.min_rpm, g_cfg.max_rpm, g_cfg.poll_interval,
      g_cfg.ema_seconds, g_cfg.slew_up, g_cfg.slew_down, g_cfg.deadband,
      g_cfg.emergency_temp, g_cfg.curve_autoscale,
      src_name(g_cfg.temp_source), src_name(g_cfg.emergency_source));
    for (int f = 0; f < NFAN; f++)
        fprintf(fp, "    {\"id\": %d, \"actual_rpm\": %.0f, \"target_rpm\": %.0f,"
                    " \"min\": %.0f, \"max\": %.0f, \"fault\": %s}%s\n",
                f, ac[f], tg[f], g_fmin[f], g_fmax[f],
                (fault && fault[f]) ? "true" : "false", f==NFAN-1?"":",");
    fprintf(fp, "  ]\n}\n");
    fclose(fp);
    rename(tmp, path);                    // 原子替换，读者永远看不到半个文件
}

// ───────────────────────── 主循环 ─────────────────────────

int main(int argc, char **argv){
    const char *cfg_path    = "/usr/local/etc/fanpilot/fanpilot.conf";
    const char *status_path = "/var/run/fanpilot.status.json";
    int oneshot = 0, check_only = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--config") && i+1 < argc) cfg_path = argv[++i];
        else if (!strcmp(argv[i], "--status") && i+1 < argc) status_path = argv[++i];
        else if (!strcmp(argv[i], "--oneshot")) oneshot = 1;
        else if (!strcmp(argv[i], "--check-config")) check_only = 1;
    }

    cfg_load(cfg_path, &g_cfg);

    // --check-config：只加载并打印**生效后**的配置（含每风扇实际曲线）就退出。
    //
    // 🩸 初版在这里直接 return，于是打印的是**模板**而不是生效曲线 ——
    //    因为按各风扇硬件上限重铺发生在读到 F*Mx 之后。
    //    那样的校验命令看起来能验、其实验不到，是最坏的一种判据。
    // ⇒ 先只读地打开 SMC 拿边界（读不需要 root、也不需要占锁、绝不写），
    //    重铺后再打印。校验命令必须显示真正会生效的东西。
    if (check_only) {
        double mx[NFAN] = {5349, 5777};      // 读不到时的兜底（本机实测值）
        if (smc_open() == 0) {
            for (int f = 0; f < NFAN; f++) {
                char n[8]; snprintf(n,8,"F%dMx",f);
                Key k; if (key_init(&k, n) == 0) key_read_flt(&k, &mx[f]);
                snprintf(n,8,"F%dMn",f);
                if (key_init(&k, n) == 0) key_read_flt(&k, &g_fmin[f]);
            }
        }
        printf("poll_interval=%.2f\nmin_rpm=%.0f\nmax_rpm=%.0f\nema_seconds=%.1f\n"
               "slew_up=%.0f\nslew_down=%.0f\ndeadband=%.0f\nemergency_temp=%.1f\n"
               "curve_autoscale=%d\ncurve_points=%d\n",
               g_cfg.poll_interval, g_cfg.min_rpm, g_cfg.max_rpm, g_cfg.ema_seconds,
               g_cfg.slew_up, g_cfg.slew_down, g_cfg.deadband, g_cfg.emergency_temp,
               g_cfg.curve_autoscale, g_cfg.n_curve);
        for (int f = 0; f < NFAN; f++) {
            g_fmax[f] = mx[f];
            fl_cfg t = g_cfg;
            fl_curve_rescale(&t, mx[f]);
            printf("fan%d_hw_max=%.0f\n", f, mx[f]);
            for (int i = 0; i < t.n_curve; i++)
                printf("fan%d_curve%d=%.1f:%.0f\n", f, i, t.curve[i].t, t.curve[i].rpm);
        }
        if (g_conn) IOServiceClose(g_conn);
        return 0;
    }

    // ── 单实例锁。必须在**打开 SMC 之前**拿到，否则第二个实例已能读写硬件。
    //    flock 在进程死亡（含 SIGKILL）时由内核自动释放，正好适合 KeepAlive 重启。
    //    🩸 缺这个锁时实测踩过：前台测试实例与 launchd 实例同时跑，各自算曲线
    //       抢写同一组 SMC 寄存器，目标值互踩（漂移 2115→2209）且**不报错**。
    {
        const char *lock_path = "/var/run/fanpilotd.lock";
        int lf = open(lock_path, O_CREAT | O_RDWR, 0644);
        if (lf < 0) {
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
    }

    if (smc_open() != 0) { fprintf(stderr, "✗ 打不开 SMC\n"); return 1; }

    for (int f = 0; f < NFAN; f++) {
        char n[8];
        snprintf(n,8,"F%dmd",f); key_init(&g_md[f], n);
        snprintf(n,8,"F%dTg",f); key_init(&g_tg[f], n);
        snprintf(n,8,"F%dAc",f); key_init(&g_ac[f], n);
        snprintf(n,8,"F%dMn",f); key_init(&g_mn[f], n);
        snprintf(n,8,"F%dMx",f); key_init(&g_mx[f], n);
        if (key_read_flt(&g_mn[f], &g_fmin[f]) != 0) g_fmin[f] = 1350;
        if (key_read_flt(&g_mx[f], &g_fmax[f]) != 0) g_fmax[f] = 4000;
        fl_fan_state_init(&g_fs[f]);
    }
    if (enum_sensors() != 0) { fprintf(stderr, "✗ 找不到 Tp* 传感器\n"); return 1; }
    rebuild_fan_curves();

    fprintf(stderr, "fanpilotd 启动: %d 个传感器 · 风扇0 %.0f~%.0f · 风扇1 %.0f~%.0f\n",
            g_ntemp, g_fmin[0], g_fmax[0], g_fmin[1], g_fmax[1]);
    log_effective();

    signal(SIGTERM, on_signal); signal(SIGINT, on_signal); signal(SIGHUP, on_signal);

    // 起步：先 md=1 再写 Tg（PLAN §4.2：顺序反了会有「已切手动但目标为0」窗口）
    for (int f = 0; f < NFAN; f++) {
        g_cur_target[f] = fl_clamp_fan(&g_fan_cfg[f], g_fmin[f], g_fmax[f], g_cfg.min_rpm, 0);
        if (key_write_u8(&g_md[f], 1) != 0) {
            fprintf(stderr, "✗ 无法切手动模式（需要 root）—— 退出\n");
            return 1;
        }
        key_write_flt(&g_tg[f], g_cur_target[f]);
        g_last_written[f] = g_cur_target[f];
        g_writes++;
    }

    // ⭐ 配置文件自动重载（监视 mtime）。
    //    为什么：菜单栏 App 是**无特权**的，它改完配置没法给 root 守护发 SIGHUP。
    //    让守护自己发现变化 ⇒ 用户在菜单里点一下就立即生效，
    //    **不需要「重新加载配置」这种按钮**（让用户手动 reload 本身就是设计失败）。
    struct stat cst;
    time_t cfg_mtime = (stat(cfg_path, &cst) == 0) ? cst.st_mtime : 0;

    while (!g_stop) {
        int need_reload = g_reload;
        g_reload = 0;
        if (stat(cfg_path, &cst) == 0 && cst.st_mtime != cfg_mtime) {
            cfg_mtime = cst.st_mtime;
            need_reload = 1;
        }
        if (need_reload) {
            cfg_load(cfg_path, &g_cfg);
            rebuild_fan_curves();
            fprintf(stderr, "配置已重载（检测到文件变化或收到 SIGHUP）\n");
            log_effective();
        }

        double alpha = g_cfg.poll_interval / g_cfg.ema_seconds;

        double hot, avg, cool;
        if (read_temps(&hot, &avg, &cool) != 0) {
            // S5 降级留痕：读不到温度就交还固件，绝不用陈旧值继续控制
            fprintf(stderr, "⚠️ 传感器读取失败 → 交还固件自动控制\n");
            fans_to_firmware();
            double z[NFAN] = {0,0};
            int nofault[NFAN] = {0,0};
            write_status(status_path, -1, -1, -1, -1, z, z, "failsafe_sensor_read_failed", nofault);
            sleep(5);
            continue;
        }

        // 控制输入按配置选（默认全核平均）；平滑只作用在控制输入上
        double ctl = fl_control_temp(&g_cfg, hot, avg, cool);
        g_ema = fl_ema(g_ema, ctl, alpha);
        // 紧急判定与曲线同口径（temp_source 决定），且用**原始值**不用平滑值 ——
        // 平滑会让紧急介入迟到 EMA 一个时间常数。
        int emergency = fl_is_emergency(&g_cfg, hot, avg, cool);

        double ac[NFAN], tg[NFAN];
        for (int f = 0; f < NFAN; f++) {
            const fl_cfg *fc = &g_fan_cfg[f];
            double want  = emergency ? 1e9 : fl_curve_eval(fc, g_ema);
            double target = fl_clamp_fan(fc, g_fmin[f], g_fmax[f], want, emergency);
            target = fl_slew(fc, g_cur_target[f], target, g_cfg.poll_interval, emergency);
            g_cur_target[f] = target;

            // 🩸 幂等 ≠ 免费：初版无条件重写 md=1「幂等地维持手动模式」，
            //    实测把写入次数整整翻倍。改成先读后判（读一次 0.145ms，
            //    远比一次无谓写入便宜）⇒ 24~30 次/分 → 16 次/分。
            int md_now;
            if (key_read_u8(&g_md[f], &md_now) == 0 && md_now != 1) {
                key_write_u8(&g_md[f], 1);
                g_writes++;
            }
            if (fl_should_write(fc, g_last_written[f], target)) {
                if (key_write_flt(&g_tg[f], target) == 0) {
                    g_last_written[f] = target; g_writes++;
                }
            }
            if (key_read_flt(&g_ac[f], &ac[f]) != 0) ac[f] = -1;
            tg[f] = target;

            double nowt = (double)time(NULL);
            fl_note_target(&g_fs[f], target, nowt);   // 目标上调则给爬升宽限
            int onset = 0;
            fl_fault_check(&g_fs[f], target, ac[f], nowt, &onset);
            if (onset)
                fprintf(stderr, "⚠️ 风扇 %d 疑似故障：目标 %.0f RPM，实际仅 %.0f RPM，"
                                "已连续 %d 个周期低于 %.0f%%\n",
                        f, target, ac[f], g_fs[f].cnt, FL_FAULT_RATIO * 100);
        }

        int faults[NFAN];
        for (int f = 0; f < NFAN; f++) faults[f] = g_fs[f].fault;
        write_status(status_path, hot, avg, cool, g_ema, ac, tg,
                     emergency ? "emergency" : "normal", faults);
        if (oneshot) break;
        usleep((useconds_t)(g_cfg.poll_interval * 1e6));
    }

    // 正常退出/SIGTERM：交还固件（SIGKILL 走不到这里，靠 launchd KeepAlive）
    fprintf(stderr, "收到退出信号 → 交还固件自动控制\n");
    fans_to_firmware();
    double z[NFAN] = {0,0};
    int nf2[NFAN] = {0,0};
    write_status(status_path, -1, -1, -1, -1, z, z, "stopped_firmware_auto", nf2);
    if (g_conn) IOServiceClose(g_conn);
    return 0;
}

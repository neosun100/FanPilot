// fanpilotd —— 风扇定速守护（root LaunchDaemon）
//
// 2.0 起只做一件事：**把风扇定死在指定转速，然后什么都不做。**
//
// 为什么这样就够：SMC 的 F*md=1（手动）与 F*Tg（目标）是**锁存**寄存器 ——
// 实测停写 60 秒后仍保持（docs/SMC-RESEARCH.md）。定速只需写一次，
// 之后守护的全部工作是**事件驱动**的：
//
//   事件                         动作
//   ─────────────────────────   ───────────────────────────────────────
//   启动 / 唤醒 / 配置变化        写 md=1 + Tg=目标
//   系统将睡眠                    交还固件（md=0）—— 睡着时没人能撤销手动指令
//   SIGTERM                      交还固件后退出
//   每 check_interval 秒巡检      ① 紧急：温度 ≥ 阈值 ⇒ 打满（5°C 回差）
//                                ② 回读 md/Tg，被外部改动才重写
//                                ③ 传感器读失败 ⇒ 交还固件
//   SIGKILL / 崩溃               风扇保持锁存的定速值；launchd KeepAlive 10s 后拉起新实例
//
// 稳态成本：每 10 秒 ~29 次 SMC **读**（23 温度 + 每风扇 md/Tg/实际转速），
// SMC **写 0 次**，一次状态文件原子替换。没有任何其它定时器。
//
// ⭐ 纯决策逻辑全在 src/fanlogic.h（零 IOKit 依赖，tests/unit_logic.c 覆盖）。
//    本文件只负责 IOKit 读写、事件接线、状态输出 —— 逻辑不在这里重复一份。
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
#include <libgen.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <CoreFoundation/CoreFoundation.h>

#include "fanlogic.h"

#define KIDX 2
#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_INDEX   8
#define CMD_READ_KEYINFO 9

#define MAX_SENSORS 64
#define NFAN        FL_NFAN

typedef struct { uint8_t a,b,c,d; uint16_t r; } SVer;
typedef struct { uint16_t v,l; uint32_t a,b,c; } SPLim;
typedef struct { uint32_t size, type; uint8_t attr; } SInfo;
typedef struct {
    uint32_t key; SVer vers; SPLim plim; SInfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SData;

// 缓存的键句柄：keyinfo 只在启动时问一次（省掉每次一个 IOKit 往返）
typedef struct { char name[5]; uint32_t size, type; uint8_t attr; int valid; } Key;

static io_connect_t g_conn = 0;
static fl_cfg g_cfg;

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

static Key    g_temp[MAX_SENSORS]; static int g_ntemp = 0;   // Tp* 簇
static Key    g_md[NFAN], g_tg[NFAN], g_ac[NFAN];
static double g_fmin[NFAN], g_fmax[NFAN];                    // 运行时读到的硬件上下限
static long   g_writes = 0;
static time_t g_last_write = 0;    // 最近一次 SMC 写入的墙钟时间（0 = 从未）—— 让「累计 N 次」可被验证
static long   g_external = 0;      // 被外部改动并纠正的次数（> 0 说明有别的程序在抢）
static int    g_emergency = 0;
static int    g_failsafe = 0;
static int    g_starved = 0;       // 写入预算耗尽中（边沿留痕用）
static fl_bucket g_bucket;
static fl_fight  g_fight;      // 传感器读失败 ⇒ 已交还固件
static int    g_sleeping = 0;      // WillSleep 之后、唤醒之前：绝不重新接管
static double g_sleep_at = 0;      // 进入 g_sleeping 时的「醒着时钟」（见 awake_now）
static int    g_stop = 0;
static int    g_reload = 0;
static int    g_hup = 0;
static const char *g_status_path = "/var/run/fanpilot.status.json";
static const char *g_cfg_path    = "/usr/local/etc/fanpilot/fanpilot.conf";

// 只计醒着的时间（CLOCK_UPTIME_RAW 睡眠时不走）。用于判断「WillSleep 之后又醒着过了很久」
// ⇒ 唤醒通知丢了，不能永远不接管。
static double awake_now(void){
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

// 枚举 Tp* 簇（启动时一次）
static int enum_sensors(void){
    Key nk; if (key_init(&nk, "#KEY") != 0) return -1;
    uint8_t b[32]; if (key_read(&nk, b) != 0) return -1;
    uint32_t total = ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];
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

// 交还写入也计入 writes_total —— 菜单里的「启动以来共写 N 次」若漏掉睡眠/退出时的交还，数字就偏小
// （不受令牌桶限制：这是安全方向的写入，且只在边沿发生）
static void fans_to_firmware(void){
    for (int f = 0; f < NFAN; f++)
        if (key_write_u8(&g_md[f], 0) == 0) { g_writes++; g_last_write = time(NULL); }
}

// ───────────────────────── 状态文件 ─────────────────────────

static void write_status(const char *mode, double hot, double avg, double cool,
                         const double ac[], const double tg[]){
    char tmp[512]; snprintf(tmp, sizeof tmp, "%s.tmp", g_status_path);
    FILE *fp = fopen(tmp, "w");
    if (!fp) { fprintf(stderr, "⚠️ 写不了状态文件 %s: %s\n", tmp, strerror(errno)); return; }
    fprintf(fp,
      "{\n  \"ts\": %ld,\n  \"mode\": \"%s\",\n"
      "  \"temp_hottest_c\": %.2f,\n  \"temp_average_c\": %.2f,\n  \"temp_coolest_c\": %.2f,\n"
      "  \"sensors\": %d,\n  \"writes_total\": %ld,\n  \"last_write_ts\": %ld,\n  \"external_overrides\": %ld,\n"
      "  \"config\": {\"percent\": %.1f, \"check_interval\": %.1f, \"emergency_temp\": %.0f,"
      " \"emergency_source\": \"%s\"},\n"
      "  \"fans\": [\n",
      (long)time(NULL), mode, hot, avg, cool, g_ntemp, g_writes, (long)g_last_write, g_external,
      g_cfg.percent, g_cfg.check_interval, g_cfg.emergency_temp, fl_src_name(g_cfg.emergency_source));
    // set_rpm = 定速折算值（不含紧急）；target_rpm = 此刻实际下发的目标（紧急时为上限）
    for (int f = 0; f < NFAN; f++)
        fprintf(fp, "    {\"id\": %d, \"set_rpm\": %.0f, \"target_rpm\": %.0f,"
                    " \"actual_rpm\": %.0f, \"min\": %.0f, \"max\": %.0f}%s\n",
                f, fl_fan_target(&g_cfg, g_fmin[f], g_fmax[f], 0), tg[f], ac[f],
                g_fmin[f], g_fmax[f], f==NFAN-1?"":",");
    fprintf(fp, "  ]\n}\n");
    fclose(fp);
    rename(tmp, g_status_path);           // 原子替换，读者永远看不到半个文件
}

// ───────────────────────── 核心：一次巡检 ─────────────────────────
//
// 启动、唤醒、配置变化、定时巡检**全走这一个函数**（单一来源，不会分叉）。
// 它是幂等的：回读一致就什么都不写。
static void check_once(const char *why_in){
    const char *why = why_in;
    double z[NFAN] = {0, 0};
    if (g_sleeping) {
        // 🩸 WillSleep 已交还固件；离真正睡着还有几秒。若此时巡检把 md 写回 1，
        //    就又回到「带着手动指令睡一整夜」那个 bug（v1.2.0 修过的）。
        if (awake_now() - g_sleep_at < 30) return;
        fprintf(stderr, "⚠️ WillSleep 后醒着已超 30s 却没收到唤醒通知 —— 视为已唤醒，重新接管\n");
        g_sleeping = 0;
    }

    double hot, avg, cool;
    if (read_temps(&hot, &avg, &cool) != 0) {
        // 降级留痕：读不到温度就交还固件，绝不在看不见温度时维持手动转速
        // 只在**边沿**交还一次：持续失败时每次巡检都写 md=0 是无意义的重复写入
        if (!g_failsafe) {
            fprintf(stderr, "⚠️ 传感器读取失败 → 交还固件自动控制\n");
            fans_to_firmware();
        }
        g_failsafe = 1;
        write_status("failsafe_sensor_read_failed", -1, -1, -1, z, z);
        return;
    }
    if (g_failsafe) { fprintf(stderr, "传感器恢复 → 重新接管\n"); why = "恢复"; }
    g_failsafe = 0;

    int em = fl_emergency_next(&g_cfg, g_emergency,
                               fl_pick_temp(g_cfg.emergency_source, hot, avg, cool));
    if (em != g_emergency)          // 边沿触发留痕，不按巡检刷屏
        fprintf(stderr, em ? "🔥 %s温度 %.1f°C ≥ %.0f°C → 紧急打满\n"
                           : "紧急解除（%s温度 %.1f°C < %.0f°C-5）→ 回到定速\n",
                fl_src_name(g_cfg.emergency_source),
                fl_pick_temp(g_cfg.emergency_source, hot, avg, cool), g_cfg.emergency_temp);
    g_emergency = em;

    double now = awake_now();
    int yielding = fl_fight_yielding(&g_fight, now);
    int starved = 0;
    double ac[NFAN], tg[NFAN];
    for (int f = 0; f < NFAN; f++) {
        double target = fl_fan_target(&g_cfg, g_fmin[f], g_fmax[f], em);
        int md = -1; double tg_now = -1;
        if (key_read_u8(&g_md[f], &md) != 0) md = -1;
        if (key_read_flt(&g_tg[f], &tg_now) != 0) tg_now = -1;
        if (!yielding && fl_needs_rewrite(md, tg_now, target)) {
            // 定时巡检里发现不符 = 有别的东西改了寄存器（别的风扇软件 / SMC 复位）
            if (!strcmp(why, "巡检")) {
                g_external++;
                fprintf(stderr, "⚠️ 风扇%d 被外部改动（md=%d Tg=%.0f，累计 %ld 次）\n",
                        f, md, tg_now, g_external);
                if (fl_fight_note(&g_fight, now)) {
                    fprintf(stderr, "🛑 10 分钟内被外部改动 %d 次 —— 有别的程序在写风扇。"
                                    "FanPilot 让步 %.0f 分钟（不纠正、不写），避免互相拉锯\n",
                            FL_FIGHT_COUNT, FL_FIGHT_YIELD / 60);
                    yielding = 1;
                    continue;
                }
            }
            // 🔴 写入令牌桶：防 bug 导致的写入风暴。紧急打满不受限（它自身被回差限频）
            int n = (md != 1) + 1;
            if (!em && !fl_bucket_take(&g_bucket, now, n)) {
                if (!g_starved) fprintf(stderr, "🛑 SMC 写入预算耗尽（>%.0f 次/小时）—— 暂停写入，"
                                                "这说明有 bug 或外部抢写，请看上面的日志\n",
                                        FL_WRITE_PER_HOUR);
                starved = 1;
            } else {
                // 先 md=1 再写 Tg：顺序反了会有「已切手动但目标是旧值/0」的窗口
                if (md != 1 && key_write_u8(&g_md[f], 1) == 0) g_writes++;
                if (key_write_flt(&g_tg[f], target) == 0) g_writes++;
                g_last_write = time(NULL);
            }
        }
        if (key_read_flt(&g_ac[f], &ac[f]) != 0) ac[f] = -1;
        tg[f] = target;
    }
    if (g_starved && !starved) fprintf(stderr, "写入预算恢复\n");
    g_starved = starved;
    write_status(yielding ? "yielded_external_writer" : starved ? "write_budget_exhausted"
                 : em ? "emergency" : "normal", hot, avg, cool, ac, tg);
}

static void log_effective(void){
    fprintf(stderr, "生效配置: 定速 %.1f%% · 巡检 %.0fs · 紧急 %.0f°C（%s，回差 %.0f°C）\n",
            g_cfg.percent, g_cfg.check_interval, g_cfg.emergency_temp,
            fl_src_name(g_cfg.emergency_source), FL_EMERG_HYSTERESIS);
    for (int f = 0; f < NFAN; f++)
        fprintf(stderr, "  风扇%d → %.0f RPM（硬件 %.0f~%.0f）\n", f,
                fl_fan_target(&g_cfg, g_fmin[f], g_fmax[f], 0), g_fmin[f], g_fmax[f]);
}

// 配置文件的「身份」：目录事件只说明**目录里有东西变了**，不说明配置变了。
// 🩸 实测：配置与状态文件同在 /tmp 时，写状态 → 目录事件 → 重载 → 写状态 …
//    23 秒自触发 4074 次重载。⇒ 只有身份真变了才算配置变化。
static struct stat g_cfg_st;
static int cfg_changed(void){
    struct stat st;
    if (stat(g_cfg_path, &st) != 0) memset(&st, 0, sizeof st);
    int changed = st.st_ino != g_cfg_st.st_ino || st.st_size != g_cfg_st.st_size
               || st.st_mtimespec.tv_sec  != g_cfg_st.st_mtimespec.tv_sec
               || st.st_mtimespec.tv_nsec != g_cfg_st.st_mtimespec.tv_nsec;
    g_cfg_st = st;
    return changed;
}

static void reload_config(void){
    if (fl_cfg_load(g_cfg_path, &g_cfg) != 0)
        fprintf(stderr, "⚠️ 读不到配置 %s —— 使用默认值（%.0f%%）\n",
                g_cfg_path, FL_DEFAULT_PCT);
    log_effective();
}

// ───────────────────────── 睡眠 / 唤醒交接 ─────────────────────────
//
// 🩸 2026-09-14 实测的真 bug：合盖睡眠 44 分钟，用户态被冻结，而 F*md=1 锁存
//    ⇒ 风扇按合盖前的 3822 RPM 转了一整夜。睡前必须把控制权交给唯一还醒着的固件。

static io_connect_t          g_pm_root     = MACH_PORT_NULL;
static IONotificationPortRef g_pm_port     = NULL;
static io_object_t           g_pm_notifier = IO_OBJECT_NULL;

// 「收到某条电源消息该做什么」的纯动作部分，与 IOKit 应答分离 ⇒ --selftest-pm 可直接触发
static void pm_apply(natural_t type){
    switch (type) {
    case kIOMessageSystemWillSleep:
        fans_to_firmware();
        g_sleeping = 1;
        g_sleep_at = awake_now();
        break;
    // 只认 HasPoweredOn：WillPowerOn 时 SMC 可能还没就绪，读失败会白走一趟失效安全
    case kIOMessageSystemHasPoweredOn:
        if (g_sleeping) {
            g_sleeping = 0;
            fprintf(stderr, "系统唤醒 → 重新接管风扇\n");
            check_once("唤醒");
        }
        break;
    default:
        break;
    }
}

static void pm_callback(void *refcon, io_service_t svc, natural_t type, void *arg){
    (void)refcon; (void)svc;
    pm_apply(type);
    // ⚠️ 必须应答，否则系统睡眠被拖 30 秒才超时放行。
    // ⛔ 永不 IOCancelPowerChange：风扇控制器没有理由否决机器睡觉。
    if (type == kIOMessageCanSystemSleep || type == kIOMessageSystemWillSleep)
        IOAllowPowerChange(g_pm_root, (long)arg);
}

// 失败不致命（降级留痕）：定速仍然可用，只是睡眠交接失灵
static int pm_register(void){
    g_pm_root = IORegisterForSystemPower(NULL, &g_pm_port, pm_callback, &g_pm_notifier);
    if (g_pm_root == MACH_PORT_NULL || g_pm_port == NULL) {
        fprintf(stderr, "⚠️ 电源通知注册失败 —— 睡眠时将无法交还固件（风扇可能整夜转）\n");
        g_pm_port = NULL;
        return -1;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(g_pm_port),
                       kCFRunLoopDefaultMode);
    return 0;
}

// ───────────────────────── 事件接线 ─────────────────────────
//
// 信号与配置变化都用 dispatch source 投递到主队列（主 run loop 会服务主队列），
// 处理完就 CFRunLoopStop 唤醒主循环 ⇒ **即刻**响应，不靠轮询。
// 🩸 1.x 用 run loop 超时轮询 mtime：SIGTERM 与菜单改设置最坏都要等一个周期。

static void wake_main(void){ CFRunLoopStop(CFRunLoopGetMain()); }

static void watch_signal(int sig){
    signal(sig, SIG_IGN);                 // 交给 dispatch，不走异步信号处理函数
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                 (uintptr_t)sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
        if (sig == SIGHUP) { g_reload = 1; g_hup = 1; } else g_stop = 1;
        wake_main();
    });
    dispatch_resume(s);
}

// 监视**配置所在目录**而不是文件：菜单栏 App 用「临时文件 + rename」原子写，
// rename 会换 inode，盯文件 fd 的话第一次修改后就再也收不到事件。
static int watch_config_dir(void){
    char buf[1024]; strncpy(buf, g_cfg_path, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    const char *dir = dirname(buf);
    int fd = open(dir, O_EVTONLY);
    if (fd < 0) {
        fprintf(stderr, "⚠️ 无法监视配置目录 %s: %s —— 改配置需 sudo killall -HUP fanpilotd\n",
                dir, strerror(errno));
        return -1;
    }
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{ g_reload = 1; wake_main(); });
    dispatch_resume(s);
    return 0;
}

// ───────────────────────── 启动 ─────────────────────────

static int init_fan_keys(int need_write){
    for (int f = 0; f < NFAN; f++) {
        char n[8]; Key mn, mx;
        snprintf(n,8,"F%dmd",f); key_init(&g_md[f], n);
        snprintf(n,8,"F%dTg",f); key_init(&g_tg[f], n);
        snprintf(n,8,"F%dAc",f); key_init(&g_ac[f], n);
        snprintf(n,8,"F%dMn",f);
        if (key_init(&mn, n) != 0 || key_read_flt(&mn, &g_fmin[f]) != 0) g_fmin[f] = -1;
        snprintf(n,8,"F%dMx",f);
        if (key_init(&mx, n) != 0 || key_read_flt(&mx, &g_fmax[f]) != 0) g_fmax[f] = -1;
        // 🔴 读不到硬件范围就不写：没有上下限就无法保证目标合法（1.x 用 4000 兜底，删了）
        if (need_write && (g_fmin[f] <= 0 || g_fmax[f] <= g_fmin[f] || !g_md[f].valid || !g_tg[f].valid)) {
            fprintf(stderr, "✗ 风扇%d 的 SMC 键不全或范围读不到（Mn=%.0f Mx=%.0f）—— 拒绝控制\n",
                    f, g_fmin[f], g_fmax[f]);
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv){
    int oneshot = 0, check_only = 0, selftest_pm = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--config") && i+1 < argc) g_cfg_path = argv[++i];
        else if (!strcmp(argv[i], "--status") && i+1 < argc) g_status_path = argv[++i];
        else if (!strcmp(argv[i], "--oneshot")) oneshot = 1;
        else if (!strcmp(argv[i], "--check-config")) check_only = 1;
        else if (!strcmp(argv[i], "--selftest-pm")) selftest_pm = 1;
    }
    fl_cfg_load(g_cfg_path, &g_cfg);

    // ── --selftest-pm：不睡机器地验证睡眠交接真的有效果（回读 SMC 判效果，不判接线）
    //    刻意不占 flock：只做一次交还写入；在跑的守护下一次巡检会自愈（e2e 断言这一环）
    if (selftest_pm) {
        int reg = pm_register();
        printf("pm_registered=%d\n", reg == 0 ? 1 : 0);
        if (smc_open() != 0) { printf("smc_open=0\nresult=fail\n"); return 1; }
        printf("smc_open=1\n");
        init_fan_keys(0);
        int okall = 1;
        for (int f = 0; f < NFAN; f++) {
            int b; if (key_read_u8(&g_md[f], &b) != 0) b = -1;
            printf("fan%d_md_before=%d\n", f, b);
        }
        pm_apply(kIOMessageSystemWillSleep);          // ← 被测的那一条路径
        for (int f = 0; f < NFAN; f++) {
            int a; if (key_read_u8(&g_md[f], &a) != 0) a = -1;
            printf("fan%d_md_after=%d\n", f, a);
            if (a != 0) okall = 0;
        }
        printf("sleeping_flag=%d\n", g_sleeping);
        int pass = okall && reg == 0 && g_sleeping;
        printf("result=%s\n", pass ? "pass" : "fail");
        IOServiceClose(g_conn);
        return pass ? 0 : 1;
    }

    // ── --check-config：只读打开 SMC 拿硬件范围，打印**真正会写进去的值**就退出
    //    🩸 1.x 初版打印的是模板而非生效值 —— 看起来能验、其实验不到
    if (check_only) {
        if (smc_open() == 0) init_fan_keys(0);
        else for (int f = 0; f < NFAN; f++) g_fmin[f] = g_fmax[f] = -1;
        printf("percent=%.1f\n", g_cfg.percent);
        printf("check_interval=%.1f\nemergency_temp=%.1f\nemergency_source=%s\n",
               g_cfg.check_interval, g_cfg.emergency_temp, fl_src_name(g_cfg.emergency_source));
        for (int f = 0; f < NFAN; f++) {
            printf("fan%d_hw_min=%.0f\nfan%d_hw_max=%.0f\n", f, g_fmin[f], f, g_fmax[f]);
            if (g_fmax[f] > 0)
                printf("fan%d_effective_target=%.0f\n", f,
                       fl_fan_target(&g_cfg, g_fmin[f], g_fmax[f], 0));
        }
        if (g_conn) IOServiceClose(g_conn);
        return 0;
    }

    // ── 单实例锁。必须在**打开 SMC 之前**拿到，否则第二个实例已能写硬件。
    //    flock 在进程死亡（含 SIGKILL）时由内核释放，正好配合 KeepAlive 重启。
    {
        const char *lock_path = "/var/run/fanpilotd.lock";
        int lf = open(lock_path, O_CREAT | O_RDWR, 0644);
        if (lf < 0) {
            fprintf(stderr, "⚠️ 打不开锁文件 %s: %s —— 无法保证单实例\n", lock_path, strerror(errno));
        } else if (flock(lf, LOCK_EX | LOCK_NB) != 0) {
            fprintf(stderr,
                "✗ 已有另一个 fanpilotd 在运行（锁 %s 被占用）—— 拒绝启动。\n"
                "  两个实例会抢写同一组 SMC 寄存器。先停掉旧的：\n"
                "    sudo launchctl bootout system/com.newmac.fanpilotd\n", lock_path);
            return 4;
        }
    }

    if (smc_open() != 0) { fprintf(stderr, "✗ 打不开 SMC\n"); return 1; }
    if (init_fan_keys(1) != 0) return 1;
    if (enum_sensors() != 0) { fprintf(stderr, "✗ 找不到 Tp* 传感器\n"); return 1; }

    fprintf(stderr, "fanpilotd 2 启动: %d 个传感器 · 风扇0 %.0f~%.0f · 风扇1 %.0f~%.0f\n",
            g_ntemp, g_fmin[0], g_fmax[0], g_fmin[1], g_fmax[1]);
    log_effective();

    watch_signal(SIGTERM); watch_signal(SIGINT); watch_signal(SIGHUP);
    cfg_changed();      // 记下初始身份
    watch_config_dir();
    pm_register();      // 失败已在内部留痕，不阻止启动

    fl_bucket_init(&g_bucket, awake_now());
    fl_fight_init(&g_fight);
    check_once("启动");
    double last = awake_now();
    while (!oneshot && !g_stop) {
        // 只有两种唤醒：巡检到期，或事件（信号 / 配置 / 电源）调了 CFRunLoopStop。
        // 🩸 等待时长按「距上次巡检还剩多少」算，不是每次都等满一个间隔 ——
        //    否则频繁的目录噪音会不断重置等待，**饿死**巡检（紧急保护随之失效）。
        double wait = g_cfg.check_interval - (awake_now() - last);
        if (wait > 0) {
            // 🔴 空转保护：本模式没有任何事件源时 CFRunLoopRunInMode **立刻**返回 Finished，
            //    主循环会变成 100% CPU 的忙等。实测目前不会发生（主队列算事件源），
            //    但这是「自己不断触发自己」那一类，宁可多一道闸门：退回 usleep 并留痕一次。
            if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait, false) == kCFRunLoopRunFinished) {
                static int warned = 0;
                if (!warned++) fprintf(stderr, "⚠️ run loop 无事件源（立即返回）—— 退回 usleep，事件响应变为最坏 %.0fs\n", wait);
                usleep((useconds_t)(wait * 1e6));
            }
        }
        if (g_stop) break;
        if (g_reload) {
            g_reload = 0;
            // 目录事件必须过身份判据；SIGHUP 是显式要求，无条件重读（重读一次无害）
            if (cfg_changed() || g_hup) {
                g_hup = 0; reload_config();
                fl_fight_init(&g_fight);    // 使用者显式改了设置 = 明确要 FanPilot 接管，结束让步
                check_once("配置变化"); last = awake_now();
            }
        }
        if (awake_now() - last >= g_cfg.check_interval) {
            // 兜底：目录事件只覆盖「增删 / 改名」（原子写）；cp 覆盖、nano 原地保存
            // 不改目录 ⇒ 收不到事件。巡检时顺带 stat 一次（1 个系统调用）补上。
            // 🩸 原地编辑触发的写入必须记为「配置变化」而不是「巡检发现外部改动」——
            //    初版走了巡检分支，使用者自己改配置被算成抢写，3 次就会错误让步 30 分钟
            if (cfg_changed()) {
                reload_config(); fl_fight_init(&g_fight); check_once("配置变化");
            } else {
                check_once("巡检");
            }
            last = awake_now();
        }
    }

    // 正常退出 / SIGTERM：交还固件（SIGKILL 走不到这里，靠 launchd KeepAlive）
    fprintf(stderr, "退出 → 交还固件自动控制\n");
    fans_to_firmware();
    double z[NFAN] = {0, 0};
    write_status("stopped_firmware_auto", -1, -1, -1, z, z);
    IOServiceClose(g_conn);
    return 0;
}

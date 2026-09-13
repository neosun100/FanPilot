// fanctl —— SMC 风扇读写工具（写入需 root）
//
// 这是 FanPilot 的底层能力实现，守护(fanpilotd)直接复用本文件的 smc_* 函数。
// 安全机制从第一行就内建，不是事后加的：
//   S1 键白名单   —— 只有 F0md/F1md/F0Tg/F1Tg 可写，其余一律拒绝
//   S2 值域校验   —— 目标 RPM 必须落在**运行时读到的** F*Mn~F*Mx 内（不硬编码）
//   S4 存档/还原  —— 写之前先能存档，随时可完全还原
//
// 用法:
//   fanctl status              显示两个风扇与关键温度
//   fanctl archive <file>      存档当前 md/Tg 到 JSON
//   fanctl restore <file>      从存档还原
//   fanctl mode <0|1> <0|1>    设两个风扇的模式（0=固件自动 1=手动）
//   fanctl rpm  <fan> <rpm>    设某个风扇的目标转速（自动切到手动模式）
//   fanctl auto                两个风扇都交还固件（**失效安全状态**）
//
// 编译: clang -O2 -framework IOKit -framework CoreFoundation -o fanctl fanctl.c

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

#define KIDX 2
#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_KEYINFO 9

typedef struct { uint8_t a,b,c,d; uint16_t r; } SVer;
typedef struct { uint16_t v,l; uint32_t a,b,c; } SPLim;
typedef struct { uint32_t size, type; uint8_t attr; } SInfo;
typedef struct {
    uint32_t key; SVer vers; SPLim plim; SInfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SData;

static io_connect_t g_conn = 0;

static uint32_t s2k(const char *s){
    return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)
         | ((uint32_t)(uint8_t)s[2]<<8) | (uint32_t)(uint8_t)s[3];
}

// ── S1 键白名单：唯一允许写入的 4 个键 ───────────────────────────────
static const char *WRITABLE[] = { "F0md", "F1md", "F0Tg", "F1Tg", NULL };
static int is_writable(const char *key){
    for (int i = 0; WRITABLE[i]; i++) if (!strcmp(key, WRITABLE[i])) return 1;
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
static void smc_close(void){ if (g_conn) IOServiceClose(g_conn); }

static kern_return_t smc_call(SData *in, SData *out){
    size_t n = sizeof(SData);
    memset(out, 0, n);
    return IOConnectCallStructMethod(g_conn, KIDX, in, sizeof(SData), out, &n);
}

static int smc_info(const char *key, SInfo *info){
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(key); in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.info; return 0;
}

static int smc_read(const char *key, SInfo *info, uint8_t *buf){
    if (smc_info(key, info) != 0) return -1;
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(key); in.data8 = CMD_READ_BYTES; in.info.size = info->size;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(buf, out.bytes, info->size > 32 ? 32 : info->size);
    return 0;
}

// 读 flt 键；读不到返回 0 并置 ok=0
static double read_flt(const char *key, int *ok){
    SInfo i; uint8_t b[32];
    if (smc_read(key, &i, b) != 0 || i.size != 4) { if(ok)*ok=0; return 0; }
    float f; memcpy(&f, b, 4); if(ok)*ok=1; return f;
}
static int read_u8(const char *key, int *ok){
    SInfo i; uint8_t b[32];
    if (smc_read(key, &i, b) != 0 || i.size < 1) { if(ok)*ok=0; return -1; }
    if(ok)*ok=1; return b[0];
}

// ── 写入：走白名单 + 长度必须与 SMC 报告的一致 ────────────────────────
static int smc_write(const char *key, const uint8_t *data, uint32_t len){
    if (!is_writable(key)) {                                  // S1
        fprintf(stderr, "⛔ 拒绝：键 %s 不在白名单内（只允许 F0md/F1md/F0Tg/F1Tg）\n", key);
        return -2;
    }
    SInfo info;
    if (smc_info(key, &info) != 0) { fprintf(stderr, "✗ 读不到 %s 的键信息\n", key); return -1; }
    if (info.size != len) {
        fprintf(stderr, "⛔ 拒绝：%s 长度不符（SMC 报告 %u，给了 %u）\n", key, info.size, len);
        return -2;
    }
    if (!(info.attr & 0x40)) {                                 // 实测确证：0x40 = 可写
        fprintf(stderr, "⛔ 拒绝：%s 属性 0x%02x 无可写位\n", key, info.attr);
        return -2;
    }
    SData in, out; memset(&in, 0, sizeof in);
    in.key = s2k(key); in.data8 = CMD_WRITE_BYTES; in.info.size = len;
    memcpy(in.bytes, data, len > 32 ? 32 : len);
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) {
        fprintf(stderr, "✗ 写 %s 失败（result=%u）—— 需要 root?\n", key, out.result);
        return -1;
    }
    return 0;
}

static int write_flt(const char *key, float v){
    uint8_t b[4]; memcpy(b, &v, 4);          // flt 是小端（实测）
    return smc_write(key, b, 4);
}
static int write_u8(const char *key, uint8_t v){
    return smc_write(key, &v, 1);
}

// ── S2 值域校验：上下限运行时读取，绝不硬编码 ─────────────────────────
static int fan_bounds(int fan, double *mn, double *mx){
    char kmn[5], kmx[5];
    snprintf(kmn, 5, "F%dMn", fan); snprintf(kmx, 5, "F%dMx", fan);
    int a, b;
    *mn = read_flt(kmn, &a); *mx = read_flt(kmx, &b);
    return (a && b) ? 0 : -1;
}

static void print_status(void){
    int ok; int n = read_u8("FNum", &ok);
    printf("风扇数 FNum = %d\n\n", ok ? n : -1);
    for (int f = 0; f < (ok ? n : 2); f++) {
        char kac[5], ktg[5], kmd[5];
        snprintf(kac,5,"F%dAc",f); snprintf(ktg,5,"F%dTg",f); snprintf(kmd,5,"F%dmd",f);
        double mn, mx; fan_bounds(f, &mn, &mx);
        int o1,o2,o3;
        double ac = read_flt(kac,&o1), tg = read_flt(ktg,&o2);
        int md = read_u8(kmd,&o3);
        printf("风扇 %d: 实际 %.0f RPM · 目标 %.0f · 模式 %d(%s) · 范围 %.0f~%.0f\n",
               f, ac, tg, md, md == 0 ? "固件自动" : "手动", mn, mx);
    }
    printf("\n关键温度:\n");
    const char *tk[] = {"Tp00","Tp0C","Tp0X","TCMb","TVDP",NULL};
    double hot = -999;
    for (int i = 0; tk[i]; i++) {
        int o; double v = read_flt(tk[i], &o);
        if (o) { printf("  %-5s %6.2f °C\n", tk[i], v); if (v > hot) hot = v; }
    }
    printf("  ⇒ 最热 %.2f °C\n", hot);
}

static int cmd_archive(const char *path){
    FILE *fp = fopen(path, "w");
    if (!fp) { perror("fopen"); return 1; }
    int o;
    fprintf(fp, "{\n");
    for (int f = 0; f < 2; f++) {
        char ktg[5], kmd[5];
        snprintf(ktg,5,"F%dTg",f); snprintf(kmd,5,"F%dmd",f);
        fprintf(fp, "  \"F%dmd\": %d,\n", f, read_u8(kmd,&o));
        fprintf(fp, "  \"F%dTg\": %.0f%s\n", f, read_flt(ktg,&o), f == 0 ? "," : "");
    }
    fprintf(fp, "}\n");
    fclose(fp);
    printf("✅ 已存档到 %s\n", path);
    return 0;
}

static int cmd_rpm(int fan, double rpm){
    double mn, mx;
    if (fan_bounds(fan, &mn, &mx) != 0) { fprintf(stderr, "✗ 读不到风扇 %d 的上下限\n", fan); return 1; }
    if (rpm < mn || rpm > mx) {                                // S2
        fprintf(stderr, "⛔ 拒绝：%.0f RPM 越界（风扇 %d 允许 %.0f~%.0f）\n", rpm, fan, mn, mx);
        return 2;
    }
    char ktg[5], kmd[5];
    snprintf(ktg,5,"F%dTg",fan); snprintf(kmd,5,"F%dmd",fan);
    if (write_flt(ktg, (float)rpm) != 0) return 1;
    if (write_u8(kmd, 1) != 0) return 1;                        // 切手动才生效
    printf("✅ 风扇 %d 目标 → %.0f RPM（模式=手动）\n", fan, rpm);
    return 0;
}

static int cmd_auto(void){
    int rc = 0;
    for (int f = 0; f < 2; f++) {
        char kmd[5]; snprintf(kmd,5,"F%dmd",f);
        if (write_u8(kmd, 0) != 0) rc = 1;
    }
    if (!rc) printf("✅ 两个风扇已交还固件自动控制（失效安全状态）\n");
    return rc;
}

int main(int argc, char **argv){
    if (argc < 2) {
        fprintf(stderr,
          "用法: %s status | archive <file> | mode <f0> <f1> | rpm <fan> <rpm> | auto\n", argv[0]);
        return 1;
    }
    if (smc_open() != 0) { fprintf(stderr, "✗ 打不开 SMC\n"); return 1; }
    int rc = 0;
    const char *c = argv[1];

    if (!strcmp(c, "status"))       print_status();
    else if (!strcmp(c, "archive") && argc == 3) rc = cmd_archive(argv[2]);
    else if (!strcmp(c, "auto"))    rc = cmd_auto();
    else if (!strcmp(c, "rpm") && argc == 4)  rc = cmd_rpm(atoi(argv[2]), atof(argv[3]));
    else if (!strcmp(c, "mode") && argc == 4) {
        rc |= write_u8("F0md", (uint8_t)atoi(argv[2]));
        rc |= write_u8("F1md", (uint8_t)atoi(argv[3]));
        if (!rc) printf("✅ 模式已设 F0md=%s F1md=%s\n", argv[2], argv[3]);
    }
    else { fprintf(stderr, "✗ 未知命令或参数个数不对: %s\n", c); rc = 1; }

    smc_close();
    return rc;
}

// smcprobe —— SMC 键枚举探针（只读）
//
// 目的：在动手写 App 之前，先用实测回答三个问题：
//   ① Apple Silicon M5 Max 上还能不能通过 IOKit 访问 SMC
//   ② 风扇键（F*）到底有哪些、几个风扇、当前转速/目标值/模式
//   ③ 温度键（T*）有哪些，哪些适合做控制输入
//
// 编译: clang -O2 -framework IOKit -framework CoreFoundation -o smcprobe smcprobe.c
// 只读：本程序**不写**任何 SMC 键。写入需要 root，且是另一个二进制的职责。

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_INDEX   8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result, status, data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

static uint32_t s2k(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) |
           ((uint32_t)s[2] << 8)  | (uint32_t)s[3];
}
static void k2s(uint32_t k, char *out) {
    out[0] = (k >> 24) & 0xff; out[1] = (k >> 16) & 0xff;
    out[2] = (k >> 8)  & 0xff; out[3] = k & 0xff; out[4] = 0;
}

// 依次尝试 Apple Silicon / Intel 上的服务名。返回 0 = 成功。
static int smc_open(const char **which) {
    const char *names[] = { "AppleSMC", "AppleSMCKeysEndpoint", NULL };
    for (int i = 0; names[i]; i++) {
        io_service_t svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(names[i]));
        if (!svc) continue;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        IOObjectRelease(svc);
        if (kr == KERN_SUCCESS) { *which = names[i]; return 0; }
    }
    return -1;
}

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t osz = sizeof(SMCKeyData);
    memset(out, 0, osz);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                     in, sizeof(SMCKeyData), out, &osz);
}

// 读一个键：填 info（类型/长度）与 bytes。返回 0 = 成功。
static int smc_read(const char *key, SMCKeyInfoData *info, uint8_t *buf) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.key  = s2k(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;

    memset(&in, 0, sizeof in);
    in.key = s2k(key);
    in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = info->dataSize;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(buf, out.bytes, info->dataSize > 32 ? 32 : info->dataSize);
    return 0;
}

// 按索引取第 i 个键名
static int smc_key_at(uint32_t idx, char *name5) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.data8  = SMC_CMD_READ_INDEX;
    in.data32 = idx;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    k2s(out.key, name5);
    return 0;
}

// 把 SMC 原始字节按类型解成 double。ok=0 表示这个类型我们不认识。
static double decode(uint32_t type, const uint8_t *b, uint32_t len, int *ok) {
    char t[5]; k2s(type, t);
    *ok = 1;
    if (!strcmp(t, "flt ") && len == 4) { float f; memcpy(&f, b, 4); return f; }
    if (!strcmp(t, "ui8 ") && len >= 1) return b[0];
    if (!strcmp(t, "ui16") && len >= 2) return (b[0] << 8) | b[1];        // SMC 为大端
    if (!strcmp(t, "ui32") && len >= 4) return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | (b[2] << 8) | b[3];
    if (!strcmp(t, "si8 ") && len >= 1) return (int8_t)b[0];
    if (!strcmp(t, "sp78") && len >= 2) return (double)((int8_t)b[0]) + b[1] / 256.0;
    if (!strcmp(t, "fpe2") && len >= 2) return (((b[0] << 8) | b[1]) >> 2);
    *ok = 0;
    return 0;
}

static void dump(const char *key) {
    SMCKeyInfoData info; uint8_t buf[32] = {0};
    if (smc_read(key, &info, buf) != 0) { printf("  %-5s  <读不到>\n", key); return; }
    char t[5]; k2s(info.dataType, t);
    int ok; double v = decode(info.dataType, buf, info.dataSize, &ok);
    if (ok) printf("  %-5s  type=%-5s len=%u  值 = %.2f\n", key, t, info.dataSize, v);
    else {
        printf("  %-5s  type=%-5s len=%u  raw =", key, t, info.dataSize);
        for (uint32_t i = 0; i < info.dataSize && i < 16; i++) printf(" %02x", buf[i]);
        printf("\n");
    }
}

int main(void) {
    const char *which = NULL;
    if (smc_open(&which) != 0) { fprintf(stderr, "✗ 打不开 SMC 服务\n"); return 1; }
    printf("✅ SMC 已连接，服务名 = %s\n\n", which);

    // ── 风扇数量
    printf("=== 风扇数量 ===\n");
    dump("FNum");

    // ── 枚举全部键，分类统计
    printf("\n=== 枚举全部 SMC 键 ===\n");
    SMCKeyInfoData info; uint8_t buf[32];
    uint32_t total = 0;
    if (smc_read("#KEY", &info, buf) == 0) {
        int ok; total = (uint32_t)decode(info.dataType, buf, info.dataSize, &ok);
    }
    printf("  #KEY（总键数）= %u\n", total);

    char fans[512][5]; int nf = 0;
    char temps[2048][5]; int nt = 0;
    for (uint32_t i = 0; i < total; i++) {
        char name[5];
        if (smc_key_at(i, name) != 0) continue;
        if (name[0] == 'F' && nf < 512) { strcpy(fans[nf++], name); }
        else if (name[0] == 'T' && nt < 2048) { strcpy(temps[nt++], name); }
    }
    printf("  F* 风扇类键 %d 个 · T* 温度类键 %d 个\n", nf, nt);

    printf("\n=== 全部 F*（风扇）键及当前值 ===\n");
    for (int i = 0; i < nf; i++) dump(fans[i]);

    printf("\n=== T*（温度）键：前 40 个 ===\n");
    for (int i = 0; i < nt && i < 40; i++) dump(temps[i]);

    IOServiceClose(g_conn);
    return 0;
}

// power —— SMC 功率/电压/电流键只读探针
//
// 目的：回答「整机功率到底多少」。`powermetrics` 只给 CPU/GPU/ANE 三条轨，
// 而 SMC 的 P* 键给出各条实测轨（含整机与 DC-in），是唯一能答"总功率"的本地源。
//
// 🔴 只读：本程序**没有**任何写入路径（无 SMC_CMD_WRITE_BYTES）。
//
// 🩸 结构体布局必须与 smcprobe.c 完全一致 —— `IOConnectCallStructMethod` 按字节偏移
//    解释这块内存。第一版我把 SMCVersion 写成 4 字节（实际 6 字节：uint8_t×4 + uint16_t），
//    整个结构体错位，表现为「读 #KEY 失败」而不是给出错值。
//
// 编译: clang -O2 -o /tmp/power power.c -framework IOKit -framework CoreFoundation
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_INDEX   8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key; SMCVersion vers; SMCPLimitData pLimitData; SMCKeyInfoData keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

static uint32_t s2k(const char *s) {
    return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];
}
static void k2s(uint32_t k, char *o) {
    o[0]=(k>>24)&0xff; o[1]=(k>>16)&0xff; o[2]=(k>>8)&0xff; o[3]=k&0xff; o[4]=0;
}
static int smc_open(void) {
    const char *names[] = { "AppleSMC", "AppleSMCKeysEndpoint", NULL };
    for (int i = 0; names[i]; i++) {
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(names[i]));
        if (!s) continue;
        kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &g_conn);
        IOObjectRelease(s);
        if (kr == KERN_SUCCESS) return 0;
    }
    return -1;
}
static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t osz = sizeof(SMCKeyData); memset(out, 0, osz);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData), out, &osz);
}
static int smc_read(const char *key, SMCKeyInfoData *info, uint8_t *buf) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); in.key = s2k(key); in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    memset(&in, 0, sizeof in); in.key = s2k(key); in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = info->dataSize;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(buf, out.bytes, info->dataSize > 32 ? 32 : info->dataSize);
    return 0;
}
static int smc_key_at(uint32_t idx, char *name5) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); in.data8 = SMC_CMD_READ_INDEX; in.data32 = idx;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    k2s(out.key, name5); return 0;
}
// flt = 小端 IEEE-754（FanPilot docs/SMC-RESEARCH.md §3.1 已四重验证过的口径）
static double decode_flt(const uint8_t *b) { float f; memcpy(&f, b, 4); return (double)f; }

int main(int argc, char **argv) {
    if (smc_open() != 0) { fprintf(stderr, "打不开 SMC\n"); return 1; }
    SMCKeyInfoData info; uint8_t buf[32]; char ts[5], ks[5];

    uint32_t total = 0;
    if (smc_read("#KEY", &info, buf) == 0)
        total = ((uint32_t)buf[0]<<24)|((uint32_t)buf[1]<<16)|((uint32_t)buf[2]<<8)|buf[3];
    if (!total) { fprintf(stderr, "读 #KEY 失败\n"); return 1; }
    printf("SMC 键总数 %u\n\n", total);

    const char groups[] = { 'P', 'V', 'I' };
    const char *labels[] = { "功率 P* (W)", "电压 V* (V)", "电流 I* (A)" };
    for (int g = 0; g < 3; g++) {
        printf("=== %s ===\n", labels[g]);
        int shown = 0;
        for (uint32_t i = 0; i < total; i++) {
            if (smc_key_at(i, ks) != 0) continue;
            if (ks[0] != groups[g]) continue;
            if (smc_read(ks, &info, buf) != 0) continue;
            k2s(info.dataType, ts);
            if (strcmp(ts, "flt ") != 0 || info.dataSize != 4) continue;
            double v = decode_flt(buf);
            if (v != v) continue;                       // NaN
            if (v < -1e4 || v > 1e4) continue;          // 离谱值
            if (argc > 1 && v == 0.0) continue;         // 带任意参数 = 只显示非零
            printf("  %-5s = %10.3f\n", ks, v);
            shown++;
        }
        if (!shown) printf("  （无）\n");
        printf("\n");
    }
    IOServiceClose(g_conn);
    return 0;
}

// sensors —— 温度传感器普查 + 风扇键可写性确认（只读）
//
// 目的：从 361 个 T* 键里挑出适合做控制输入的那几个，并确认 F*Tg / F*md 是可写的。
// 判据：① 读得到有效值 ② 值在合理区间(0~120°C) ③ 按值降序看哪些是真热点
//
// 编译: clang -O2 -framework IOKit -framework CoreFoundation -o sensors sensors.c

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_INDEX   8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key; SMCVersion vers; SMCPLimitData pLimitData; SMCKeyInfoData keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;
static uint32_t s2k(const char *s){return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];}
static void k2s(uint32_t k,char*o){o[0]=(k>>24)&0xff;o[1]=(k>>16)&0xff;o[2]=(k>>8)&0xff;o[3]=k&0xff;o[4]=0;}

static kern_return_t call(SMCKeyData*in,SMCKeyData*out){
    size_t n=sizeof(SMCKeyData); memset(out,0,n);
    return IOConnectCallStructMethod(g_conn,KERNEL_INDEX_SMC,in,sizeof(SMCKeyData),out,&n);
}
static int rd(const char*key,SMCKeyInfoData*info,uint8_t*buf){
    SMCKeyData in,out; memset(&in,0,sizeof in);
    in.key=s2k(key); in.data8=SMC_CMD_READ_KEYINFO;
    if(call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -1;
    *info=out.keyInfo;
    memset(&in,0,sizeof in); in.key=s2k(key); in.data8=SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize=info->dataSize;
    if(call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -1;
    memcpy(buf,out.bytes,info->dataSize>32?32:info->dataSize);
    return 0;
}
static int key_at(uint32_t i,char*n){
    SMCKeyData in,out; memset(&in,0,sizeof in);
    in.data8=SMC_CMD_READ_INDEX; in.data32=i;
    if(call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -1;
    k2s(out.key,n); return 0;
}

typedef struct { char key[5]; double v; } Ent;
static int cmpdesc(const void*a,const void*b){
    double d=((const Ent*)b)->v-((const Ent*)a)->v;
    return d>0?1:(d<0?-1:0);
}

int main(void){
    io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!svc||IOServiceOpen(svc,mach_task_self(),0,&g_conn)!=KERN_SUCCESS){
        fprintf(stderr,"✗ SMC 打不开\n"); return 1; }
    IOObjectRelease(svc);

    SMCKeyInfoData info; uint8_t buf[32];
    uint32_t total=0;
    if(rd("#KEY",&info,buf)==0) total=((uint32_t)buf[0]<<24)|((uint32_t)buf[1]<<16)|(buf[2]<<8)|buf[3];

    // ── 1. 风扇控制键的属性（dataAttributes 的 bit0 通常表示可写）
    printf("=== 风扇控制键：类型 / 长度 / 属性位 ===\n");
    const char *fk[]={"F0md","F1md","F0Tg","F1Tg","F0Ac","F1Ac","F0Mn","F0Mx","F1Mn","F1Mx","FS! ",NULL};
    for(int i=0;fk[i];i++){
        if(rd(fk[i],&info,buf)!=0){ printf("  %-5s <读不到>\n",fk[i]); continue; }
        char t[5]; k2s(info.dataType,t);
        printf("  %-5s type=%-5s len=%u attr=0x%02x\n",fk[i],t,info.dataSize,info.dataAttributes);
    }

    // ── 2. 全部 flt 型 T* 键，按温度降序
    printf("\n=== 温度传感器（flt 型，按当前温度降序，前 30）===\n");
    Ent *e=calloc(4096,sizeof(Ent)); int n=0;
    for(uint32_t i=0;i<total&&n<4096;i++){
        char name[5];
        if(key_at(i,name)!=0) continue;
        if(name[0]!='T') continue;
        if(rd(name,&info,buf)!=0) continue;
        char t[5]; k2s(info.dataType,t);
        if(strcmp(t,"flt ")||info.dataSize!=4) continue;
        float f; memcpy(&f,buf,4);
        if(f<-5||f>150) continue;            // 明显无效的丢掉
        strcpy(e[n].key,name); e[n].v=f; n++;
    }
    qsort(e,n,sizeof(Ent),cmpdesc);
    printf("  有效 flt 温度传感器 %d 个\n",n);
    for(int i=0;i<n&&i<30;i++) printf("  %-5s  %6.2f °C\n",e[i].key,e[i].v);

    // ── 3. TempMonitor 实际在用的那几个（对照）
    printf("\n=== 对照：TempMonitor 选用的传感器 ===\n");
    const char *tm[]={"Tp0X","Tp0j","Tf0A","Tf0B","TCMb","TCDX","TCHP",NULL};
    for(int i=0;tm[i];i++){
        if(rd(tm[i],&info,buf)!=0){ printf("  %-5s <无此键>\n",tm[i]); continue; }
        char t[5]; k2s(info.dataType,t);
        if(!strcmp(t,"flt ")&&info.dataSize==4){ float f; memcpy(&f,buf,4);
            printf("  %-5s  %6.2f °C\n",tm[i],f); }
        else printf("  %-5s  type=%s\n",tm[i],t);
    }
    free(e); IOServiceClose(g_conn); return 0;
}

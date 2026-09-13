// sample —— 传感器/风扇时序采样（只读）
//
// 目的：判定哪些温度键可以当控制输入。判据是**响应性**：
//   真温度键会随负载变化；固定值或非温度量纲的键不会。
// 用法: ./sample <秒数> [间隔秒]
// 输出: CSV（时间, 各传感器, 风扇实际转速, 目标, 模式）便于算方差。

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>

#define KIDX 2
typedef struct{uint8_t a,b,c,d;uint16_t r;}V;
typedef struct{uint16_t v,l;uint32_t a,b,c;}P;
typedef struct{uint32_t s,t;uint8_t at;}I;
typedef struct{uint32_t k;V v;P p;I i;uint8_t r,s,d8;uint32_t d32;uint8_t by[32];}D;

static io_connect_t g;
static uint32_t s2k(const char*s){return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];}
static kern_return_t cl(D*a,D*b){size_t n=sizeof(D);memset(b,0,n);
    return IOConnectCallStructMethod(g,KIDX,a,sizeof(D),b,&n);}

// 读 flt 键；失败返回 NAN 语义的 -999
static double rdflt(const char*k){
    D a,b; memset(&a,0,sizeof a); a.k=s2k(k); a.d8=9;
    if(cl(&a,&b)!=KERN_SUCCESS||b.r) return -999;
    uint32_t sz=b.i.s;
    memset(&a,0,sizeof a); a.k=s2k(k); a.d8=5; a.i.s=sz;
    if(cl(&a,&b)!=KERN_SUCCESS||b.r) return -999;
    if(sz==4){ float f; memcpy(&f,b.by,4); return f; }
    if(sz==1) return b.by[0];
    return -999;
}

int main(int argc,char**argv){
    int dur = argc>1?atoi(argv[1]):60;
    double iv = argc>2?atof(argv[2]):2.0;
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!s||IOServiceOpen(s,mach_task_self(),0,&g)!=KERN_SUCCESS){fprintf(stderr,"✗ SMC\n");return 1;}
    IOObjectRelease(s);

    // 候选控制输入：两个离群键 + 性能核簇代表 + 电压域 + TempMonitor 用的
    const char *keys[] = {"Tf06","Tf16","Tp00","Tp0X","TVDP","TCMb","Tf0A", NULL};
    printf("ts");
    for(int i=0;keys[i];i++) printf(",%s",keys[i]);
    printf(",F0Ac,F1Ac,F0Tg,F0md\n");

    time_t end=time(NULL)+dur;
    while(time(NULL)<end){
        printf("%ld",(long)time(NULL));
        for(int i=0;keys[i];i++) printf(",%.2f",rdflt(keys[i]));
        printf(",%.0f,%.0f,%.0f,%.0f\n",
               rdflt("F0Ac"),rdflt("F1Ac"),rdflt("F0Tg"),rdflt("F0md"));
        fflush(stdout);
        usleep((useconds_t)(iv*1e6));
    }
    IOServiceClose(g);
    return 0;
}

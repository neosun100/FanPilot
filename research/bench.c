// bench —— SMC 读取开销基准 + Tp0* 簇枚举（只读）
//
// 为什么必须测这个：本机 TempMonitor 裸奔占 52% CPU、Stats 占 9%
// （见 NewMac/docs/runbooks/m5-max-performance-bible.md）。
// 如果单次 SMC 读很贵，守护的轮询间隔就必须放宽，否则我们只是造了第三个 CPU 大户。
//
// 输出：① 单键读取耗时 ② 读一簇键的耗时 ③ 按此推算各轮询间隔下的 CPU 占用
// 编译: clang -O2 -framework IOKit -framework CoreFoundation -o bench bench.c

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <IOKit/IOKitLib.h>

#define KIDX 2
typedef struct{uint8_t a,b,c,d;uint16_t r;}V;
typedef struct{uint16_t v,l;uint32_t a,b,c;}P;
typedef struct{uint32_t s,t;uint8_t at;}I;
typedef struct{uint32_t k;V v;P p;I i;uint8_t r,s,d8;uint32_t d32;uint8_t by[32];}D;

static io_connect_t g;
static uint32_t s2k(const char*s){return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];}
static void k2s(uint32_t k,char*o){o[0]=(k>>24)&255;o[1]=(k>>16)&255;o[2]=(k>>8)&255;o[3]=k&255;o[4]=0;}
static kern_return_t cl(D*a,D*b){size_t n=sizeof(D);memset(b,0,n);
    return IOConnectCallStructMethod(g,KIDX,a,sizeof(D),b,&n);}

// 缓存键信息后只读字节：这是守护该用的方式（键类型不会变，没必要每次问）
typedef struct { char key[5]; uint32_t size, type; } KeyInfo;

static int keyinfo(const char*k, KeyInfo*ki){
    D a,b; memset(&a,0,sizeof a); a.k=s2k(k); a.d8=9;
    if(cl(&a,&b)!=KERN_SUCCESS||b.r) return -1;
    strcpy(ki->key,k); ki->size=b.i.s; ki->type=b.i.t; return 0;
}
static int readbytes(const KeyInfo*ki, uint8_t*out){
    D a,b; memset(&a,0,sizeof a); a.k=s2k(ki->key); a.d8=5; a.i.s=ki->size;
    if(cl(&a,&b)!=KERN_SUCCESS||b.r) return -1;
    memcpy(out,b.by,ki->size>32?32:ki->size); return 0;
}
static int at(uint32_t x,char*n){D a,b;memset(&a,0,sizeof a);a.d8=8;a.d32=x;
    if(cl(&a,&b)!=KERN_SUCCESS||b.r)return -1;k2s(b.k,n);return 0;}

static double now_ms(void){
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec*1000.0 + t.tv_nsec/1e6;
}

int main(void){
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!s||IOServiceOpen(s,mach_task_self(),0,&g)!=KERN_SUCCESS){fprintf(stderr,"✗ SMC\n");return 1;}
    IOObjectRelease(s);

    // ── 1. 枚举 Tp0* 簇（控制输入候选）
    I dummy; uint8_t bf[32]; uint32_t tot=0;
    { D a,b; memset(&a,0,sizeof a); a.k=s2k("#KEY"); a.d8=9;
      if(cl(&a,&b)==KERN_SUCCESS&&!b.r){ uint32_t sz=b.i.s;
        memset(&a,0,sizeof a); a.k=s2k("#KEY"); a.d8=5; a.i.s=sz;
        if(cl(&a,&b)==KERN_SUCCESS&&!b.r)
          tot=((uint32_t)b.by[0]<<24)|((uint32_t)b.by[1]<<16)|(b.by[2]<<8)|b.by[3]; } }
    (void)dummy; (void)bf;

    KeyInfo cluster[128]; int nc=0;
    printf("=== Tp0* / Tp1* 性能核簇（控制输入候选）===\n");
    for(uint32_t x=0;x<tot && nc<128;x++){
        char n[5]; if(at(x,n)) continue;
        if(n[0]!='T'||n[1]!='p') continue;
        KeyInfo ki; if(keyinfo(n,&ki)) continue;
        char t[5]; k2s(ki.type,t);
        if(strcmp(t,"flt ")||ki.size!=4) continue;
        uint8_t buf[32]; if(readbytes(&ki,buf)) continue;
        float f; memcpy(&f,buf,4);
        if(f<-5||f>150) continue;
        cluster[nc++]=ki;
        if(nc<=8||f>50) printf("  %-5s %6.2f °C\n",n,f);
    }
    printf("  ⇒ Tp* 有效传感器共 %d 个\n\n",nc);

    // ── 2. 单键读取耗时（已缓存 keyinfo，只做 READ_BYTES —— 守护的真实用法）
    const int N=2000;
    KeyInfo one; keyinfo("Tp00",&one);
    uint8_t buf[32];
    double t0=now_ms();
    for(int i=0;i<N;i++) readbytes(&one,buf);
    double t1=now_ms();
    double per=(t1-t0)/N;
    printf("=== 单键读取耗时（缓存 keyinfo 后）===\n");
    printf("  %d 次 READ_BYTES 共 %.1f ms ⇒ 单次 **%.4f ms**\n\n",N,t1-t0,per);

    // ── 3. 读整簇 + 4 个风扇键的耗时（守护每个周期的真实工作量）
    KeyInfo fans[4]; const char*fk[]={"F0Ac","F1Ac","F0Tg","F1Tg"};
    for(int i=0;i<4;i++) keyinfo(fk[i],&fans[i]);
    const int M=300;
    t0=now_ms();
    for(int i=0;i<M;i++){
        for(int j=0;j<nc;j++) readbytes(&cluster[j],buf);
        for(int j=0;j<4;j++)  readbytes(&fans[j],buf);
    }
    t1=now_ms();
    double cycle=(t1-t0)/M;
    printf("=== 一个控制周期的耗时（%d 温度键 + 4 风扇键）===\n",nc);
    printf("  %d 轮共 %.1f ms ⇒ 单周期 **%.3f ms**\n\n",M,t1-t0,cycle);

    // ── 4. 推算各轮询间隔下的 CPU 占用
    printf("=== 推算守护的 CPU 占用（单核百分比）===\n");
    printf("  %-12s %-14s %s\n","轮询间隔","单周期","CPU 占用");
    double ivs[]={0.5,1,2,3,5,10};
    for(int i=0;i<6;i++){
        double pct = cycle/(ivs[i]*1000.0)*100.0;
        printf("  %-12.1fs %-14.3fms %.4f%%   %s\n", ivs[i], cycle, pct,
               pct<0.05?"✅ 可忽略":(pct<0.5?"✅ 很低":"⚠️ 需注意"));
    }
    printf("\n  对照（NewMac 实测）：TempMonitor 裸奔 52%%、限流后 11.7%%；Stats 调优后 4.9%%\n");

    IOServiceClose(g);
    return 0;
}

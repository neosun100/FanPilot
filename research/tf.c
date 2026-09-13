// 把所有 Tf* 键列出来找规律（Tf06/Tf16 异常高，需要确认它们是什么）
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>
#define K 2
typedef struct{uint8_t a,b,c,d;uint16_t r;}V;
typedef struct{uint16_t v,l;uint32_t a,b,c;}P;
typedef struct{uint32_t s;uint32_t t;uint8_t at;}I;
typedef struct{uint32_t k;V v;P p;I i;uint8_t r,s,d8;uint32_t d32;uint8_t by[32];}D;
static io_connect_t c;
static uint32_t s2k(const char*s){return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];}
static void k2s(uint32_t k,char*o){o[0]=(k>>24)&255;o[1]=(k>>16)&255;o[2]=(k>>8)&255;o[3]=k&255;o[4]=0;}
static kern_return_t cl(D*a,D*b){size_t n=sizeof(D);memset(b,0,n);return IOConnectCallStructMethod(c,K,a,sizeof(D),b,&n);}
static int rd(const char*k,I*i,uint8_t*bf){D a,b;memset(&a,0,sizeof a);a.k=s2k(k);a.d8=9;
 if(cl(&a,&b)!=KERN_SUCCESS||b.r)return -1;*i=b.i;memset(&a,0,sizeof a);a.k=s2k(k);a.d8=5;a.i.s=i->s;
 if(cl(&a,&b)!=KERN_SUCCESS||b.r)return -1;memcpy(bf,b.by,i->s>32?32:i->s);return 0;}
static int at(uint32_t x,char*n){D a,b;memset(&a,0,sizeof a);a.d8=8;a.d32=x;
 if(cl(&a,&b)!=KERN_SUCCESS||b.r)return -1;k2s(b.k,n);return 0;}
int main(void){io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
 if(!s||IOServiceOpen(s,mach_task_self(),0,&c))return 1; IOObjectRelease(s);
 I i;uint8_t bf[32];uint32_t tot=0;
 if(!rd("#KEY",&i,bf))tot=((uint32_t)bf[0]<<24)|((uint32_t)bf[1]<<16)|(bf[2]<<8)|bf[3];
 printf("=== 全部 Tf* 键 ===\n");
 for(uint32_t x=0;x<tot;x++){char n[5];if(at(x,n))continue;
  if(n[0]!='T'||n[1]!='f')continue;
  if(rd(n,&i,bf))continue;char t[5];k2s(i.t,t);
  if(!strcmp(t,"flt ")&&i.s==4){float f;memcpy(&f,bf,4);printf("  %-5s %7.2f °C  attr=0x%02x\n",n,f,i.at);}
  else printf("  %-5s type=%s\n",n,t);}
 IOServiceClose(c);return 0;}

#!/usr/bin/env bash
# FanPilot 验收
#
# 设计原则（承自 NewMac cpu-limiter/verify.sh）：
#   · **反向断言**和正向断言一样重要 —— 只验「能用」会漏掉「不该能用的也能用」
#   · 判**当前事实**，不判「我执行过命令」
#   · 判据用 `grep -c` 比数量，不用 `grep -q`（大输出会吃 SIGPIPE 使判据恒假）
#   · 资源预算超标 = 验收失败（R7 是一等需求，不是「尽量」）
set -uo pipefail

LABEL="com.newmac.fanpilotd"
BIN="/usr/local/sbin/fanpilotd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CONF="/usr/local/etc/fanpilot/fanpilot.conf"
STATUS="/var/run/fanpilot.status.json"
FANCTL="$(cd "$(dirname "$0")/.." && pwd)/src/fanctl"

PASS=0; FAIL=0
ok(){   printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2 —— $3"; fi; }

[ "$(id -u)" = "0" ] || { echo "需要 root：sudo $0" >&2; exit 2; }

echo "═══ A. 安装完整性 ═══"
[ -x "${BIN}" ]   && ok "守护二进制存在 ${BIN}"        || bad "守护二进制缺失" ""
[ -f "${PLIST}" ] && ok "plist 存在"                   || bad "plist 缺失" ""
[ -f "${CONF}" ]  && ok "配置存在"                     || bad "配置缺失" ""

# ⭐ 这条判据本来缺失，导致「配置被改成 root 属主」时验收仍全绿、而用户一点就报错。
#    通则：凡是「某个身份必须能做某件事」的前提，就必须有一条以**那个身份**去试的判据。
CU="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || echo root)"
if [ -n "${CU}" ] && [ "${CU}" != "root" ]; then
  sudo -u "${CU}" test -w "${CONF}" \
    && ok "控制台用户 ${CU} 可写配置文件（菜单栏改设置才能生效）" \
    || bad "控制台用户 ${CU} **不能写** ${CONF}" "菜单栏「转速下限」会弹 Permission denied"
  sudo -u "${CU}" test -w "$(dirname "${CONF}")" \
    && ok "控制台用户可写配置目录（原子写需要）" \
    || bad "控制台用户不能写配置目录" "原子写会失败"
fi

echo "═══ B. 运行状态 ═══"
state="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*state =/{print $2;exit}')"
[ "${state}" = "running" ] && ok "state = running" || bad "state = ${state:-不存在}" "守护没在跑"

# 坑2：runs 短时暴涨 = KeepAlive 在救一个反复崩溃的守护（看着活着其实在崩）
ra="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*runs =/{print $2;exit}')"
sleep 6
rb="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*runs =/{print $2;exit}')"
if [ -n "${ra:-}" ] && [ -n "${rb:-}" ] && [ "${rb}" -le "$((ra + 1))" ]; then
  ok "runs 稳定 (${ra} → ${rb})，非崩溃循环"
else
  bad "runs ${ra:-?} → ${rb:-?}" "6 秒内暴涨 = 崩溃重启循环"
fi

n_inst="$(pgrep -x fanpilotd | grep -c . || true)"
[ "${n_inst}" = "1" ] && ok "实例数 = 1（单实例锁生效）" || bad "实例数 = ${n_inst}" "多实例会抢写 SMC"

echo "═══ C. ⭐ 失效安全机制（安全红线，不许缺） ═══"
# KeepAlive 不是可选项：SIGKILL 时进程内清理不执行，SMC 实测不会自动回退
ka="$(grep -c -A1 '<key>KeepAlive</key>' "${PLIST}" 2>/dev/null || true)"
[ "${ka}" != "0" ] && ok "plist 含 KeepAlive（SIGKILL 兜底）" || bad "plist 缺 KeepAlive" "失效安全被破坏"
kav="$(awk '/<key>KeepAlive<\/key>/{getline; print}' "${PLIST}" | grep -c 'true' || true)"
[ "${kav}" != "0" ] && ok "KeepAlive = true" || bad "KeepAlive 不是 true" "失效安全被破坏"

echo "═══ D. 状态文件与控制效果 ═══"
if [ -f "${STATUS}" ]; then
  age=$(( $(date +%s) - $(awk -F'[:,]' '/"ts"/{gsub(/[^0-9]/,"",$2);print $2;exit}' "${STATUS}") ))
  [ "${age}" -le 15 ] && ok "状态文件新鲜（${age}s 前更新）" \
                      || bad "状态文件陈旧 ${age}s" "守护可能卡住"
  mode="$(awk -F'"' '/"mode"/{print $4;exit}' "${STATUS}")"
  [ "${mode}" = "normal" ] && ok "mode = normal" || bad "mode = ${mode}" "非正常控制态"
else
  bad "状态文件不存在" "守护没真正工作"
fi

if [ -x "${FANCTL}" ]; then
  # 🩸 必须用 `fanctl kv`（纯 ASCII），**不能**解析 `fanctl status` 的中文输出：
  #    macOS 自带 BSD awk 不是多字节安全的，2 个风扇曾被数成 12 个。
  kv="$("${FANCTL}" kv 2>/dev/null)"
  md_manual="$(printf '%s\n' "${kv}" | grep -c '^fan[0-9]*_mode=1' || true)"
  [ "${md_manual}" = "2" ] && ok "两个风扇均为手动模式（守护在控）" \
                           || bad "手动模式的风扇数 = ${md_manual}" "期望 2"
  # SMC 里的目标 == 守护报告的目标（判**硬件事实**，不判守护自己说的）
  for f in 0 1; do
    want="$(awk -v f="${f}" -F'[:,]' '/"id": /{id=$2+0} /"target_rpm"/{for(i=1;i<=NF;i++) if($i ~ /"target_rpm"/) {v=$(i+1)+0}; if(id==f){print v; exit}}' "${STATUS}")"
    got="$(printf '%s\n' "${kv}" | sed -n "s/^fan${f}_target=//p")"
    awk -v a="${got:-0}" -v b="${want:-0}" 'BEGIN{exit !(a-b<2 && b-a<2 && b>0)}' \
      && ok "风扇${f} SMC 目标 ${got} == 守护目标 ${want}" \
      || bad "风扇${f} SMC 目标 ${got:-?} ≠ 守护目标 ${want:-?}" "有别的程序在改，或守护没生效"
  done
else
  bad "找不到 ${FANCTL}" "无法验证风扇状态"
fi

echo "═══ D2. 🔴 防写入风暴（使用者头号约束：写入风暴曾导致死机） ═══"
# 判据：60 秒窗口内 writes_total 不增长。⭐ 这是**行为**判据，不是「配置写了定速」。
w1="$(sed -n 's/.*"writes_total"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "${STATUS}")"
sleep 60
w2="$(sed -n 's/.*"writes_total"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "${STATUS}")"
d=$(( ${w2:-0} - ${w1:-0} ))
[ "${d}" = "0" ] && ok "稳态 60 秒写 SMC ${d} 次（定速 = 写一次就不再动）" \
                 || bad "稳态 60 秒写 SMC ${d} 次" "定速模式稳态必须 0 次"
# 反向对照：状态文件 ts 在这 60 秒里必须前进 —— 否则上面的 0 可能是守护卡死的假绿
age="$(( $(date +%s) - $(awk -F'[:,]' '/"ts"/{gsub(/[^0-9]/,"",$2);print $2;exit}' "${STATUS}") ))"
[ "${age}" -le 15 ] && ok "⭐反向：同一窗口内守护仍在巡检（状态 ${age}s 前更新）—— 0 次不是卡死" \
                    || bad "状态 ${age}s 未更新" "上面的 0 次写入可能是守护卡死的假绿"
ext="$(sed -n 's/.*"external_overrides"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "${STATUS}")"
[ "${ext:-0}" = "0" ] && ok "无外部程序改动风扇寄存器（external_overrides=0）" \
                      || bad "风扇被外部改动 ${ext} 次" "有别的风扇软件在跑？会互相抢写"

echo "═══ E. R7 资源预算（超标即失败） ═══"
P="$(pgrep -x fanpilotd | head -1)"
if [ -n "${P}" ]; then
  # 60s 窗口：守护 10s 才醒一次，20s 窗口里 ps 的 0.01s 分辨率测不出东西
  t1="$(ps -o time= -p "${P}" | tr -d ' ')"; sleep 60
  t2="$(ps -o time= -p "${P}" | tr -d ' ')"
  pct="$(awk -v a="${t1}" -v b="${t2}" 'BEGIN{
      split(a,x,":"); split(b,y,":");
      sa=(length(x)==3? x[1]*3600+x[2]*60+x[3] : x[1]*60+x[2]);
      sb=(length(y)==3? y[1]*3600+y[2]*60+y[3] : y[1]*60+y[2]);
      printf "%.3f", (sb-sa)/60*100 }')"
  awk -v p="${pct}" 'BEGIN{exit !(p < 0.05)}' && ok "CPU ${pct}% < 0.05%" \
                                              || bad "CPU ${pct}%" "超预算 0.05%（1.x 是 0.10%）"
  rss_mb="$(ps -o rss= -p "${P}" | awk '{printf "%.2f", $1/1024}')"
  awk -v r="${rss_mb}" 'BEGIN{exit !(r < 8)}' && ok "RSS ${rss_mb} MB < 8 MB" \
                                              || bad "RSS ${rss_mb} MB" "超预算 8 MB"
else
  bad "找不到守护进程" "无法测资源"
fi

echo "═══ F. 🔴 反向断言（不该能做的必须做不到） ═══"
if [ -x "${FANCTL}" ]; then
  # S2 值域校验：越界必须被拒（退出码 2）
  "${FANCTL}" rpm 0 99999 >/dev/null 2>&1
  chk "$([ $? = 2 ] && echo 0 || echo 1)" "超上限转速被拒绝" "值域校验失效"
  "${FANCTL}" rpm 0 100 >/dev/null 2>&1
  chk "$([ $? = 2 ] && echo 0 || echo 1)" "低于下限转速被拒绝" "值域校验失效"
fi
# S1 键白名单：源码里必须只有那 4 个键
wl="$(grep -c '"F0md","F1md","F0Tg","F1Tg"' "$(dirname "$0")/../src/fanpilotd.c" || true)"
[ "${wl}" != "0" ] && ok "守护源码键白名单仅 4 个键" || bad "白名单被改动" "S1 可能失效"
# 单实例锁：再起一个必须被拒（退出码 4）
"${BIN}" --config "${CONF}" --status /tmp/verify-dup.json >/dev/null 2>&1
chk "$([ $? = 4 ] && echo 0 || echo 1)" "第二个实例被拒绝启动" "单实例锁失效"
rm -f /tmp/verify-dup.json

# ⭐ 配置是不可信输入（它对用户可写，否则菜单栏 App 改不了）
#    ⇒ 安全阈值必须被硬夹，不能相信文件里写的值
EVIL=/tmp/verify-evil.conf
printf 'emergency_temp = 200\ncheck_interval = 0.01\npercent = 500\n' > "${EVIL}"
eff="$("${BIN}" --config "${EVIL}" --check-config 2>/dev/null)"
clamp(){ # $1=键 $2=期望值 $3=为什么
  got="$(printf '%s\n' "${eff}" | awk -F= -v k="$1" '$1==k{print $2;exit}')"
  if awk -v a="${got:-0}" -v b="$2" 'BEGIN{exit !(a-b<0.01 && b-a<0.01)}'; then
    ok "$1 被夹到 $2（$3）"
  else
    bad "$1 = ${got:-读不到}，期望 $2" "$3 —— 安全阈值可被配置绕过"
  fi
}
clamp emergency_temp 95  "紧急过热保护不许被调没"
clamp check_interval 5   "不许把守护自己写成 CPU 大户"
clamp percent 100 "百分比不许超过 100"
hw0="$(printf '%s\n' "${eff}" | sed -n 's/^fan0_hw_max=//p')"
clamp fan0_effective_target "${hw0:-x}" "100% 夹到风扇0 硬件上限"
printf 'percent = -5\n' > "${EVIL}"
eff="$("${BIN}" --config "${EVIL}" --check-config 2>/dev/null)"
hm1="$(printf '%s\n' "${eff}" | sed -n 's/^fan1_hw_min=//p')"
clamp fan1_effective_target "${hm1:-x}" "负百分比夹到风扇1 硬件下限（不会停转）"
rm -f "${EVIL}"

echo
echo "═══════════════════════════════"
printf '  通过 %d · 失败 %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = "0" ] && { echo "  ✅ 验收通过"; exit 0; } || { echo "  ❌ 验收失败"; exit 1; }

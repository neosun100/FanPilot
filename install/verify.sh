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
CONF="/usr/local/etc/fanpilot.conf"
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
  #    macOS 自带 BSD awk 不是多字节安全的，`$i=="目标"` 对几乎每个字段都返回真，
  #    2 个风扇被数成 12 个 —— 判据坏掉却看起来像真失败。
  #    ⭐ 通则：给人看的输出与给程序读的输出必须分开。
  kv="$("${FANCTL}" kv 2>/dev/null)"
  md_manual="$(printf '%s\n' "${kv}" | grep -c '^fan[0-9]*_mode=1' || true)"
  [ "${md_manual}" = "2" ] && ok "两个风扇均为手动模式（守护在控）" \
                           || bad "手动模式的风扇数 = ${md_manual}" "期望 2"

  # min_rpm 下限：既是需求(R2)也是失效安全(§4.1)
  # 🩸 从**状态文件**读生效值，不解析 fanpilot.conf ——
  #    那份带人写的注释，注释里的数字会被解析器吃进去（实测：min_rpm 被解析成 20009，
  #    因为注释里有 "kill -9"）。机器只读机器写的那一份。
  floor="$(sed -n 's/.*"min_rpm"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${STATUS}" | head -1)"
  low="$(printf '%s\n' "${kv}" | awk -F= -v f="${floor:-2000}" \
        '/^fan[0-9]*_target=/ && $2 < f-1 {c++} END{print c+0}')"
  [ "${low}" = "0" ] && ok "所有风扇目标 ≥ 下限 ${floor}" \
                     || bad "有 ${low} 个风扇目标低于下限 ${floor}" "min_rpm 未生效"
else
  bad "找不到 ${FANCTL}" "无法验证风扇状态"
fi

echo "═══ E. R7 资源预算（超标即失败） ═══"
P="$(pgrep -x fanpilotd | head -1)"
if [ -n "${P}" ]; then
  t1="$(ps -o time= -p "${P}" | tr -d ' ')"; sleep 20
  t2="$(ps -o time= -p "${P}" | tr -d ' ')"
  pct="$(awk -v a="${t1}" -v b="${t2}" 'BEGIN{
      split(a,x,":"); split(b,y,":");
      sa=(length(x)==3? x[1]*3600+x[2]*60+x[3] : x[1]*60+x[2]);
      sb=(length(y)==3? y[1]*3600+y[2]*60+y[3] : y[1]*60+y[2]);
      printf "%.3f", (sb-sa)/20*100 }')"
  awk -v p="${pct}" 'BEGIN{exit !(p < 0.3)}' && ok "CPU ${pct}% < 0.3%" \
                                             || bad "CPU ${pct}%" "超预算 0.3%"
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
printf 'emergency_temp = 200\npoll_interval = 0.01\nema_seconds = 9999\ndeadband = 99999\nslew_up = 1\n' > "${EVIL}"
eff="$("${BIN}" --config "${EVIL}" --check-config 2>/dev/null)"
clamp(){ # $1=键 $2=期望值 $3=为什么
  got="$(printf '%s\n' "${eff}" | awk -F= -v k="$1" '$1==k{print $2;exit}')"
  if awk -v a="${got:-0}" -v b="$2" 'BEGIN{exit !(a-b<0.01 && b-a<0.01)}'; then
    ok "$1 被夹到 $2（$3）"
  else
    bad "$1 = ${got:-读不到}，期望 $2" "$3 —— 安全阈值可被配置绕过"
  fi
}
clamp emergency_temp 95   "紧急过热保护不许被调没"
clamp poll_interval  0.50 "不许把守护自己写成 CPU 大户"
clamp ema_seconds    120  "平滑过久等于不响应升温"
clamp deadband       500  "死区过大等于不控制"
clamp slew_up        10   "升速过慢等于升不上去"
rm -f "${EVIL}"

echo
echo "═══════════════════════════════"
printf '  通过 %d · 失败 %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = "0" ] && { echo "  ✅ 验收通过"; exit 0; } || { echo "  ❌ 验收失败"; exit 1; }

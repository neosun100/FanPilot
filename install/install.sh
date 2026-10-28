#!/usr/bin/env bash
# FanPilot 安装脚本
#
# 直接沿用 NewMac modules/cpu-limiter 踩过的坑（那份 MANIFEST 记了 8 条）：
#   坑5 `set -o pipefail` + `grep -q`：大输出生产者会吃 SIGPIPE(141) 使判据恒假
#       ⇒ 一律用 `grep -c` 比数量（-c 读完全部输入，不提前关管道）
#   坑6 bootout 后立刻 bootstrap 必 EIO ⇒ **轮询等 label 真的消失**再 bootstrap
#       判据是「拆干净了」，不是「我睡够了」
#   坑2 回读要看 `runs` 计数，不只看 `state`：runs 暴涨 = KeepAlive 在救一个反复崩溃的守护
#   坑8 `${var}` 显式定界（中文全角标点会吞变量名）
set -euo pipefail

LABEL="com.newmac.fanpilotd"
BIN_SRC="$(cd "$(dirname "$0")/.." && pwd)/src/fanpilotd"
BIN_DST="/usr/local/sbin/fanpilotd"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
CONF_DIR="/usr/local/etc/fanpilot"
CONF_DST="${CONF_DIR}/fanpilot.conf"
STATUS="/var/run/fanpilot.status.json"
LOG="/var/log/fanpilotd.log"

die(){ printf '✗ %s\n' "$1" >&2; exit "${2:-1}"; }

[ "$(id -u)" = "0" ] || die "需要 root：sudo $0" 2
[ -x "${BIN_SRC}" ] || die "找不到已编译的守护 ${BIN_SRC}（先 make）" 3

echo "=== 1. 确认没有其他程序在抢写 SMC ==="
# 用 grep -c 而不是 grep -q（坑5）
n_other="$(ps ax -o args= | grep -c '[m]acsfancontrol.smcwrite' || true)"
if [ "${n_other}" != "0" ]; then
  die "Macs Fan Control 的 smcwrite helper 还在运行（${n_other} 个）—— 会与本守护互相抢写。
    先执行: sudo launchctl bootout system/com.crystalidea.macsfancontrol.smcwrite" 4
fi
echo "  ✅ 无竞争者"

echo "=== 2. 安装二进制与默认配置 ==="
install -d -m 755 /usr/local/sbin /usr/local/etc "${CONF_DIR}"
install -m 755 "${BIN_SRC}" "${BIN_DST}"
echo "  ✅ ${BIN_DST}"

# 旧配置没有 `percent` 行（1.x 全是曲线参数）⇒ 备份后换成 2.x 模板，不静默沿用
if [ -f "${CONF_DST}" ] && ! grep -Eq '^[[:space:]]*percent[[:space:]]*=' "${CONF_DST}"; then
  bak="${CONF_DST}.1x-$(date +%Y%m%d%H%M%S).bak"
  mv "${CONF_DST}" "${bak}"
  echo "  ↪ 旧配置已备份为 ${bak}（2.0 只保留定速百分比，旧参数不再使用）"
fi
if [ -f "${CONF_DST}" ]; then
  echo "  ⏭  ${CONF_DST} 已存在，保留用户配置不覆盖"
else
  cat > "${CONF_DST}" <<'CONF'
# FanPilot 2 配置（key = value）。菜单栏选档会改 percent 一行；手改保存后生效（≤10s）。

# 定速：各风扇**硬件上限的百分比**（0~100）。两风扇上限不同，按各自上限折算：
#   本机 85% ⇒ 风扇0 4547 / 风扇1 4910 RPM。低于硬件下限时按下限转，不会停转。
percent = 50

# 安全巡检间隔（秒，5~60）。每次巡检只**读** SMC：温度 + 回读风扇寄存器。
# 回读一致就什么都不写 ⇒ 稳态写 SMC 0 次。
check_interval = 10

# 紧急打满：温度 ≥ 此值时两风扇直接打满，降到「此值 - 5°C」以下恢复定速（70~95，硬夹）
emergency_temp = 90
# 紧急判据用哪个温度：max（最高核心）/ average（全核平均）/ min
emergency_source = average
CONF
  echo "  ✅ ${CONF_DST}（默认配置）"
fi

# 让配置对控制台用户可写 —— 否则菜单栏 App（无特权）改不了配置。
#
# 🔴 这是一个刻意做出的权衡，必须说清楚：
#   代价：配置成为**不可信输入**（手误或以用户身份运行的程序都能改）
#   为什么可接受：守护把所有安全相关的值**硬夹**在代码里，不相信配置文件 ——
#     · 目标转速夹在运行时读到的 F*Mn~F*Mx 内（S2）
#     · emergency_temp 夹在 70~95°C（不许把紧急保护调没）
#     · check_interval 夹在 5~60s；SMC 写入有令牌桶硬上限（防写入风暴）
#   ⇒ 最坏情况是风扇转速在合法范围内被改动，紧急过热保护**无法**被绕过。
# ⚠️ 必须用 /usr/bin/stat 绝对路径：若装了 GNU coreutils，`stat` 会被它抢占，
#    而 GNU stat 的 `-f` 是「查文件系统」不是「格式化输出」—— 会静默返回一堆
#    文件系统信息当成用户名。（本项目已被这个坑咬过 3 次：install.sh / 两处调研脚本。）
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || echo root)"
if [ -n "${CONSOLE_USER}" ] && [ "${CONSOLE_USER}" != "root" ]; then
  # 🩸 必须连**目录**一起 chown，不能只 chown 文件：
  #    原子写（临时文件 + rename）需要在同目录创建文件，目录不可写就会
  #    Permission denied —— 实测踩过，`sed -i` 与 App 的 replaceItemAt 都栽在这。
  #    所以给配置一个专属目录，而不是放宽 /usr/local/etc 本身的权限。
  chown "${CONSOLE_USER}" "${CONF_DIR}" "${CONF_DST}"
  echo "  ✅ 配置目录+文件属主 → ${CONSOLE_USER}（菜单栏 App 可原子写；安全阈值仍由守护硬夹）"
fi

echo "=== 3. 卸载旧实例（若有）——轮询等 label 真消失（坑6）==="
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  for _ in $(seq 30); do
    launchctl print "system/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    die "旧实例 15 秒内没拆干净，中止（避免 bootstrap EIO）" 5
  fi
  echo "  ✅ 旧实例已拆净"
else
  echo "  ⏭  无旧实例"
fi

echo "=== 4. 安装 plist 并 bootstrap ==="
install -m 644 "${PLIST_SRC}" "${PLIST_DST}"
# KeepAlive 是安全机制，装之前先断言它在（防止有人改坏了模板）
kacount="$(grep -c -A1 '<key>KeepAlive</key>' "${PLIST_DST}" || true)"
[ "${kacount}" != "0" ] || die "plist 里没有 KeepAlive —— 它是失效安全机制,拒绝安装" 6

# 🩸 2026-10-28 实测：做对照实验时 `launchctl disable` 过本服务 —— 这个开关**持久**（跨重启），
#    之后 bootstrap 一律报「5: Input/output error」，与「旧实例没拆净」的 EIO 长得一样。
#    判当前事实：被禁用就显式启用，并说出来（不静默改用户的设置）。
n_dis="$(launchctl print-disabled system 2>/dev/null | grep -c "\"${LABEL}\" => disabled" || true)"
if [ "${n_dis}" != "0" ]; then
  launchctl enable "system/${LABEL}"
  echo "  ↪ 服务曾被 launchctl disable（持久开关），已重新 enable"
fi

ok=0
for _ in 1 2 3; do
  if launchctl bootstrap system "${PLIST_DST}" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[ "${ok}" = "1" ] || die "bootstrap 失败（重试 3 次）" 7
echo "  ✅ 已 bootstrap"

echo "=== 5. 回读确认（判当前事实，不判我执行了命令）==="
sleep 3
state="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*state =/{print $2; exit}')"
runs_a="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*runs =/{print $2; exit}')"
echo "  state = ${state:-未知}"
sleep 5
runs_b="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= *' '/^[[:space:]]*runs =/{print $2; exit}')"
echo "  runs: ${runs_a:-?} → ${runs_b:-?}"
# 坑2：runs 短时暴涨 = KeepAlive 在救一个反复崩溃的守护（看着活着其实在崩）
if [ -n "${runs_a:-}" ] && [ -n "${runs_b:-}" ] && [ "${runs_b}" -gt "$((runs_a + 1))" ]; then
  die "runs 在 5 秒内从 ${runs_a} 涨到 ${runs_b} —— 守护在崩溃重启循环。看 ${LOG}" 8
fi

if [ ! -f "${STATUS}" ]; then
  die "状态文件 ${STATUS} 没生成 —— 守护没真正跑起来。看 ${LOG}" 9
fi
echo "  ✅ 状态文件已生成"
echo
echo "── 当前状态 ──"
cat "${STATUS}"
echo
echo "✅ 安装完成"
echo "   配置: ${CONF_DST}（保存即生效）"
echo "   状态: ${STATUS}"
echo "   日志: ${LOG}"
echo "   验收: sudo bash install/verify.sh"
echo "   卸载: sudo bash install/uninstall.sh"

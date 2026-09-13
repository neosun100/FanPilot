#!/usr/bin/env bash
# FanPilot 卸载
#
# 🔴 顺序是关键：**必须先让守护交还固件，再删它**。
#    顺序反了会把风扇永久留在手动模式（SMC 实测不会自动回退），
#    那正是本项目要治的病（Macs Fan Control 把风扇钉在 3400 两天）。
set -euo pipefail

LABEL="com.newmac.fanpilotd"
BIN="/usr/local/sbin/fanpilotd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
STATUS="/var/run/fanpilot.status.json"

[ "$(id -u)" = "0" ] || { echo "✗ 需要 root：sudo $0" >&2; exit 2; }

echo "=== 1. bootout（守护收到 SIGTERM 会自己写 F*md=0 交还固件）==="
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  for _ in $(seq 30); do
    launchctl print "system/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  echo "  ✅ 已卸载"
else
  echo "  ⏭  不在 launchd 中"
fi

echo "=== 2. 🔴 无条件确认风扇已交还固件（不信任上一步真的成功了）==="
# 判当前事实：即使 bootout 的 SIGTERM 处理没跑成，这里也要把它掰回来
FANCTL="$(cd "$(dirname "$0")/.." && pwd)/src/fanctl"
if [ -x "${FANCTL}" ]; then
  "${FANCTL}" auto || echo "  ⚠️ fanctl auto 失败，请手动确认 F0md/F1md 是 0"
  "${FANCTL}" status | grep '风扇' || true
else
  echo "  ⚠️ 找不到 ${FANCTL} —— 无法自动交还，请手动确认 F0md/F1md=0"
fi

echo "=== 3. 删除文件 ==="
rm -f "${PLIST}" "${BIN}" "${STATUS}"
echo "  ✅ 已删 ${PLIST}"
echo "  ✅ 已删 ${BIN}"
echo "  ⏭  保留配置 /usr/local/etc/fanpilot/fanpilot.conf 与日志 /var/log/fanpilotd.log"
echo
echo "✅ 卸载完成。风扇已回到出厂固件自动控制。"

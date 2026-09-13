#!/usr/bin/env bash
# 安装菜单栏 App 到 /Applications 并挂上开机自启（用户级 LaunchAgent）
#
# ⚠️ 刻意**不用** sudo：菜单栏 App 无任何特权，装在用户域即可。
#    （守护是另一回事，它是 root LaunchDaemon，走 install.sh）
set -euo pipefail

LABEL="com.newmac.fanpilot.menu"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../app/FanPilot.app"
DST="/Applications/FanPilot.app"
PLIST_SRC="${HERE}/${LABEL}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

die(){ printf '✗ %s\n' "$1" >&2; exit "${2:-1}"; }

[ "$(id -u)" != "0" ] || die "请**不要**用 sudo：菜单栏 App 装在用户域" 2
[ -d "${SRC}" ] || die "找不到 ${SRC}（先 cd app && swift build -c release && ./bundle.sh）" 3

echo "=== 1. 停掉正在运行的实例 ==="
if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  # 轮询等 label 真消失（同 cpu-limiter 坑6：判「拆干净了」不是「我睡够了」）
  for _ in $(seq 20); do
    launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi
pkill -x FanPilot 2>/dev/null || true
sleep 1
echo "  ✅ 已停"

echo "=== 2. 安装到 ${DST} ==="
rm -rf "${DST}"
cp -R "${SRC}" "${DST}"
echo "  ✅ 已复制"

echo "=== 3. 挂 LaunchAgent（开机自启）==="
mkdir -p "${HOME}/Library/LaunchAgents"
install -m 644 "${PLIST_SRC}" "${PLIST_DST}"
launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}" 2>/dev/null \
  || die "bootstrap 失败（看 /tmp/fanpilot-menu.log）" 4
echo "  ✅ 已 bootstrap"

echo "=== 4. 回读确认（判当前事实）==="
sleep 3
if ! pgrep -x FanPilot >/dev/null; then
  die "App 没跑起来。看 /tmp/fanpilot-menu.log" 5
fi
echo "  ✅ App 运行中 PID=$(pgrep -x FanPilot)"
# 用的必须是 /Applications 下那份，不是仓库里的开发版
running="$(ps -o comm= -p "$(pgrep -x FanPilot | head -1)")"
case "${running}" in
  "${DST}"*) echo "  ✅ 运行的是 ${DST}" ;;
  *)         echo "  ⚠️ 运行的是 ${running}（不是 /Applications 下那份）" ;;
esac
echo
echo "✅ 完成。重启后会自动出现在菜单栏。"
echo "   卸载: launchctl bootout gui/\$(id -u)/${LABEL} && rm -f ${PLIST_DST} && rm -rf ${DST}"

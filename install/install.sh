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

if [ -f "${CONF_DST}" ]; then
  echo "  ⏭  ${CONF_DST} 已存在，保留用户配置不覆盖"
else
  cat > "${CONF_DST}" <<'CONF'
# FanPilot 配置（key = value，改完 `sudo killall -HUP fanpilotd` 热加载）

# ═══ 转速模式（菜单栏可切）═══
fan_mode   = curve       # curve = 按温度自适应 / fixed = **定死转速**
fixed_rpm  = 3000        # fan_mode=fixed 时的转速（会按各风扇硬件范围夹取）
emergency_override = 1   # 定死模式下是否仍保留 emergency_temp 打满（1=保留，推荐）
#
# 🩸 为什么有 fixed 这一档：本机 2026-09-13~14 两天内发生 5 次 PMU 硬件看门狗
#    复位（SOCD/iBoot panic）。唯一有长期无崩溃记录的配置，是「把转速钉死、
#    之后基本不再写 SMC」那种用法。
#    · curve 模式：约 16 次/分 ≈ 2.3 万次/天 写 SMC
#    · fixed 模式：首次爬升到位后稳态 **0 次/分**
#    这是目前唯一能解释「崩溃间隔为何从 10 小时缩短到 1~2 小时」的单变量差异。
#    ⚠️ 相关不等于因果，根因仍未确定。这一档是**降低暴露面**，不是已证明的修复。
#    ⇒ fixed 模式下 min_rpm / max_rpm / ema_seconds / 曲线 全部不参与。

poll_interval  = 2.0     # 轮询间隔(秒)。实测 2.0s ⇒ CPU 0.100%
                         # fixed 模式下可放大（如 10）以进一步减少 SMC **读**取
min_rpm        = 2000    # 转速下限。⭐ 它本身就是失效安全：守护若被 kill -9,
                         #   风扇保持最后转速，最坏卡在 >=2000（比出厂空闲的 0 转风量还大）
max_rpm        = 0       # 上限；0 = 用各风扇的硬件上限(F0=5349 / F1=5777)
ema_seconds    = 15      # 温度平滑时间常数。实测 Tp00 在 70s 内极差 10.77°C,
                         #   不平滑风扇会跟着尖峰上下窜
slew_up        = 200     # 升速限幅 RPM/秒（实测硬件 0->2500 约 6~9s,200 不会超硬件能力）
slew_down      = 60      # 降速限幅 RPM/秒。非对称是「丝滑」的关键：散热要快、安静要稳
deadband       = 50      # 目标变化小于此值不写 SMC（硬件自身抖动 ±8~33 RPM,50 不损精度）
emergency_temp = 90      # 超过此温度直接打满并忽略限幅（用原始值,不用平滑值）
                         # 判据用哪个温度由下面的 temp_source 决定（两者同口径）

# 温度口径三档（菜单栏可直接切换，改完即刻生效）
temp_source      = average
                         #   max     = 最高核心温度（最保守，风扇最早升速）
                         #   average = 全核平均（默认，比最高低约 3~13°C）
                         #   min     = 最低核心温度（最安静，比最高低约 20~25°C）
                         # 它决定**曲线与菜单栏显示**用哪个温度。

emergency_source = average
                         # 🔴 90°C 紧急判据用哪个温度 —— **独立于 temp_source**。
                         # 为什么拆开：实测最高核与最低核温差约 24°C，
                         #   若紧急也用 min，最低核要到 90°C 意味着整机已彻底失控，
                         #   这道保护不是被削弱而是**等于关掉**。
                         # 想让它跟随曲线口径，把这里改成同一个值即可。
                         # ⚠️ 无论怎么设，macOS/SoC 自身的硬件过热保护都仍然生效

# 分段线性曲线 温度:转速
curve          = 45:2000, 55:2600, 65:3400, 75:4300, 85:5300
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
#     · 紧急路径忽略用户 max_rpm，只受硬件上限约束
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
echo "   配置: ${CONF_DST}（改完 sudo killall -HUP fanpilotd）"
echo "   状态: ${STATUS}"
echo "   日志: ${LOG}"
echo "   验收: sudo bash install/verify.sh"
echo "   卸载: sudo bash install/uninstall.sh"

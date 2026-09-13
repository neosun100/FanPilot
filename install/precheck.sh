#!/usr/bin/env bash
# precheck.sh —— 安装前兼容性预检
#
# ⭐ 为什么需要它：FanPilot 依赖 SMC 的 F*Tg 键可写、FNum 可读、Tp* 传感器存在。
#    这些在其他机型上可能不成立。**不能让用户先装一个 root 守护、再发现不兼容** ——
#    那个顺序是错的。
#
# 本脚本**完全只读**：不需要 root，不写任何 SMC 键，不装任何东西。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FANCTL="${HERE}/../src/fanctl"

PASS=0; WARN=0; FAIL=0
ok(){   printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
warn(){ printf '  ⚠️  %s\n' "$1"; WARN=$((WARN+1)); }
bad(){  printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "══════════════════════════════════════════"
echo "  FanPilot 兼容性预检（只读，不改动任何东西）"
echo "══════════════════════════════════════════"
echo
echo "── 系统"
[ "$(uname -s)" = "Darwin" ] && ok "macOS" || bad "不是 macOS"
ARCH="$(uname -m)"
[ "${ARCH}" = "arm64" ] && ok "Apple Silicon (${ARCH})" \
  || warn "架构 ${ARCH} —— 只在 Apple Silicon 上验证过"
OSV="$(sw_vers -productVersion)"
MAJ="${OSV%%.*}"
[ "${MAJ}" -ge 13 ] 2>/dev/null && ok "macOS ${OSV}（需要 13+）" || warn "macOS ${OSV} 可能过低"
MODEL="$(sysctl -n hw.model 2>/dev/null)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "     机型 ${MODEL} · ${CHIP}"
if [ "${MODEL}" = "Mac17,6" ]; then
  ok "与开发/实测机型完全一致"
else
  warn "本项目只在 Mac17,6 (M5 Max) 上实测过；你的机型未验证"
fi

echo
echo "── SMC 接口（决定能不能用）"
if [ ! -x "${FANCTL}" ]; then
  bad "找不到 ${FANCTL} —— 发布包应自带；从源码请先 make"
else
  KV="$("${FANCTL}" kv 2>/dev/null)"
  if [ -z "${KV}" ]; then
    bad "读不到 SMC —— 本机可能不支持 IOKit AppleSMC 用户客户端"
  else
    ok "SMC 可读（IOServiceMatching(\"AppleSMC\") 成功）"
    NF="$(printf '%s\n' "${KV}" | awk -F= '/^fan_count=/{print $2}')"
    if [ "${NF:-0}" -ge 1 ] 2>/dev/null; then
      ok "检测到 ${NF} 个风扇（FNum）"
    else
      bad "FNum 读不到或为 0 —— 无风扇或键不存在，无法使用"
    fi
    i=0
    while [ "${i}" -lt "${NF:-0}" ]; do
      mn="$(printf '%s\n' "${KV}" | awk -F= -v k="fan${i}_min" '$1==k{print $2}')"
      mx="$(printf '%s\n' "${KV}" | awk -F= -v k="fan${i}_max" '$1==k{print $2}')"
      ac="$(printf '%s\n' "${KV}" | awk -F= -v k="fan${i}_actual" '$1==k{print $2}')"
      md="$(printf '%s\n' "${KV}" | awk -F= -v k="fan${i}_mode" '$1==k{print $2}')"
      if [ -n "${mx}" ] && [ "${mx}" != "0" ]; then
        ok "风扇${i}: 范围 ${mn}~${mx} RPM · 当前 ${ac} RPM · 模式 ${md}（0=固件 1=手动）"
      else
        bad "风扇${i}: 读不到 F${i}Mx 上限 —— 无法安全设定转速"
      fi
      i=$((i+1))
    done
    T="$(printf '%s\n' "${KV}" | awk -F= '/^temp_hottest=/{print $2}')"
    if [ -n "${T}" ] && awk -v t="${T}" 'BEGIN{exit !(t>0 && t<150)}'; then
      ok "温度传感器可读（当前最热 ${T} °C）"
    else
      bad "读不到有效温度 —— 无法做温控"
    fi
  fi
fi

echo
echo "── 冲突检查（两个程序同时写 SMC 会互相抢，且不报错）"
CONFLICT=0
for proc in "Macs Fan Control" smcFanControl TGPro "iStat Menus"; do
  pgrep -x "${proc}" >/dev/null 2>&1 && { bad "正在运行：${proc}"; CONFLICT=1; }
done
for path in "/Applications/Macs Fan Control.app" "/Applications/smcFanControl.app" \
            "/Applications/TG Pro.app" \
            /Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite; do
  [ -e "${path}" ] && { bad "已安装：${path}"; CONFLICT=1; }
done
[ "${CONFLICT}" = "0" ] && ok "无其它风扇控制软件"

echo
echo "── 已装过 FanPilot？"
if [ -e /Library/LaunchDaemons/com.newmac.fanpilotd.plist ]; then
  warn "已安装 FanPilot —— 重新安装会先卸载旧实例（不会丢配置）"
else
  ok "全新安装"
fi

echo
echo "══════════════════════════════════════════"
printf '  通过 %d · 提醒 %d · 阻断 %d\n' "${PASS}" "${WARN}" "${FAIL}"
if [ "${FAIL}" != "0" ]; then
  echo "  ❌ 有阻断项，**不要**继续安装"
  exit 1
fi
if [ "${WARN}" != "0" ]; then
  echo "  ⚠️  可以安装，但上面的提醒请先读一遍"
  exit 0
fi
echo "  ✅ 完全兼容，可以安装"

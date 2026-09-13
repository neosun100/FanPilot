#!/usr/bin/env bash
# FanPilot 一键安装（发布包内使用）
#
# 发布包里的二进制是 **ad-hoc 签名**（自用工具，无 Developer ID）。
# 从网上下载的文件带 com.apple.quarantine 扩展属性，Gatekeeper 会拒绝执行，
# 报「无法打开，因为无法验证开发者」。所以第一步必须先脱隔离——
# 这不是绕过安全机制，而是用户对自己下载的东西做显式授信。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(cat "${HERE}/VERSION" 2>/dev/null || echo unknown)"

echo "══════════════════════════════════════════"
echo "  FanPilot ${VER} 安装"
echo "══════════════════════════════════════════"
echo

# ── 0. 环境检查
if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ 只支持 macOS" >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "⚠️  本工具只在 Apple Silicon 上验证过（当前 $(uname -m)）"
  printf "仍要继续吗？[y/N] "; read -r a; [ "${a}" = "y" ] || exit 1
fi

echo "=== 1. 解除下载隔离（Gatekeeper）==="
# -r 递归，|| true：本地构建的包本来就没有这个属性，不算错误
xattr -dr com.apple.quarantine "${HERE}" 2>/dev/null || true
echo "  ✅ 已解除"

echo
echo "=== 2. 检查是否有其他风扇控制软件在抢写 SMC ==="
# 🩸 不用 `ps | grep <名字>` 做检测。经典的 `[m]acsfancontrol` 括号技巧只能防止 grep
#    匹配**自己**的命令行；一旦这段脚本的文本本身出现在 ps 输出里（例如被内联进
#    `bash -c` 执行），它就会匹配到自己，**四个软件全部误报**（实测踩过）。
# ⇒ 改成两条不依赖"我的文本不出现在 ps 里"的判据：
#    ① `pgrep -x` 按**精确进程名**匹配（不看完整命令行）
#    ② 直接查已知的安装路径是否存在
CONFLICT=0
for proc in "Macs Fan Control" smcFanControl TGPro "iStat Menus"; do
  if pgrep -x "${proc}" >/dev/null 2>&1; then
    echo "  ⚠️  检测到正在运行：${proc}"; CONFLICT=1
  fi
done
for path in "/Applications/Macs Fan Control.app" \
            "/Applications/smcFanControl.app" \
            "/Applications/TG Pro.app" \
            /Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite; do
  if [ -e "${path}" ]; then
    echo "  ⚠️  检测到已安装：${path}"; CONFLICT=1
  fi
done
if [ "${CONFLICT}" = "1" ]; then
  echo
  echo "  🔴 两个程序同时写 SMC 会互相抢，转速会乱跳且不报错。"
  echo "     请先完全退出并卸载其它风扇控制软件，再运行本安装。"
  exit 2
fi
echo "  ✅ 无冲突"

echo
echo "=== 3. 安装控制守护（需要 sudo）==="
sudo bash "${HERE}/install/install.sh"

echo
echo "=== 4. 安装菜单栏 App（不需要 sudo）==="
bash "${HERE}/install/install-app.sh"

echo
echo "=== 5. 验收 ==="
sudo bash "${HERE}/install/verify.sh" || {
  echo
  echo "⚠️  验收未全绿。风扇控制可能仍在工作，但请检查上面的失败项。"
  echo "   卸载：sudo bash ${HERE}/install/uninstall.sh"
  exit 1
}

echo
echo "══════════════════════════════════════════"
echo "  ✅ 安装完成"
echo "══════════════════════════════════════════"
echo "  菜单栏已出现温度/转速，开机自动启动。"
echo
echo "  查看状态：cat /var/run/fanpilot.status.json"
echo "  卸载：    sudo bash ${HERE}/install/uninstall.sh"
echo "            （会先把风扇交还固件再删文件）"

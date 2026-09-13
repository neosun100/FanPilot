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
echo "=== 2. 兼容性预检（只读，含冲突检查）==="
# ⭐ 预检必须在装任何东西**之前** —— 不能让用户先装一个 root 守护再发现不兼容。
if ! bash "${HERE}/install/precheck.sh"; then
  echo
  echo "  🔴 预检有阻断项，安装中止。上面已列出原因。"
  exit 2
fi
echo
echo "=== 3. 安装控制守护（需要 sudo：它是 root LaunchDaemon）==="
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

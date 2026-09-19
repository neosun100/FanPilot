#!/usr/bin/env bash
# 从 assets/appicon.svg 生成 app 图标 FanPilot.icns，并装进 app bundle。
#
# 为什么要有这个脚本而不是手工做一次：
#   app bundle 由 `install/install-app.sh` 从 `app/FanPilot.app` 拷过去，
#   只在 /Applications 里手工塞图标，**下次重装就没了**。⇒ 图标必须是可复现产物。
#
# 🔴 改 bundle 内容会破坏 ad-hoc 签名 ⇒ 结尾必须重签，否则 Gatekeeper 拒绝执行。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG="${HERE}/appicon.svg"            # 128px 及以上
SVG_SMALL="${HERE}/appicon-small.svg"  # 16/32/64px：另一套美术，见该文件注释
APP="${HERE}/../app/FanPilot.app"
ICONSET="$(mktemp -d)/FanPilot.iconset"
trap 'rm -rf "$(dirname "${ICONSET}")"' EXIT

command -v rsvg-convert >/dev/null || { echo "缺 rsvg-convert（brew install librsvg）" >&2; exit 1; }
for f in "${SVG}" "${SVG_SMALL}"; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
[ -d "${APP}" ] || { echo "找不到 ${APP}" >&2; exit 1; }

mkdir -p "${ICONSET}"

# iconutil 要求的 10 个文件名（缺一个就报错）。
#
# 🔴 按尺寸档换美术：≤64px 用 appicon-small.svg（四叶负空间），≥128px 用 appicon.svg。
#    分界画在**逻辑尺寸对**之间（16x16 与 16x16@2x 同用小图；32x32 与 32x32@2x 同用小图），
#    否则同一逻辑尺寸的 @1x/@2x 会长得不一样，Retina 切换时图标会"变脸"。
for spec in "16 16x16 S" "32 16x16@2x S" "32 32x32 S" "64 32x32@2x S" \
            "128 128x128 L" "256 128x128@2x L" "256 256x256 L" "512 256x256@2x L" \
            "512 512x512 L" "1024 512x512@2x L"; do
  set -- ${spec}
  px="$1"; name="$2"; which="$3"
  src="${SVG}"; [ "${which}" = "S" ] && src="${SVG_SMALL}"
  rsvg-convert -w "${px}" -h "${px}" "${src}" -o "${ICONSET}/icon_${name}.png"
done

iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/FanPilot.icns"

# Info.plist 必须声明图标名，否则 Finder 照样显示空白
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "${APP}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string FanPilot" "${APP}/Contents/Info.plist"

# 🔴 重签（改了 Resources 与 Info.plist ⇒ 原 ad-hoc 签名已失效）
codesign --force --sign - --timestamp=none "${APP}" >/dev/null 2>&1

echo "✅ 已生成 $(du -h "${APP}/Contents/Resources/FanPilot.icns" | cut -f1) 的 FanPilot.icns"
echo "   CFBundleIconFile = $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist")"
echo "   签名: $(codesign -dv "${APP}" 2>&1 | grep -m1 Signature || echo '?')"

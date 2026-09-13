#!/usr/bin/env bash
# 把 SwiftPM 产物打成 .app 包
#
# 为什么必须打包：菜单栏 App 需要 Info.plist 里的 **LSUIElement=1** 才能
# 「只在菜单栏出现、不进 Dock、不抢焦点」。裸可执行文件虽然也能建 NSStatusItem，
# 但会在 Dock 里留一个图标，且开机自启不好挂。
set -euo pipefail

cd "$(dirname "$0")"
APP="FanPilot.app"
BIN=".build/release/FanPilotMenu"

[ -x "${BIN}" ] || { echo "✗ 先 swift build -c release" >&2; exit 1; }

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/FanPilot"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>FanPilot</string>
  <key>CFBundleDisplayName</key>           <string>FanPilot</string>
  <key>CFBundleIdentifier</key>            <string>com.newmac.fanpilot.menu</string>
  <key>CFBundleExecutable</key>            <string>FanPilot</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>1.0</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>LSMinimumSystemVersion</key>        <string>13.0</string>
  <!-- 只在菜单栏出现，不进 Dock、不抢焦点 -->
  <key>LSUIElement</key>                   <true/>
  <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名：自用够了，不需要 Developer ID
# （这也是我们选「守护自治 + App 只读」架构的收益之一：
#   不走 SMJobBless 就不需要 Developer ID 证书）
codesign --force --sign - "${APP}" 2>/dev/null || echo "  ⚠️ ad-hoc 签名失败（不影响本机运行）"

echo "✅ ${PWD}/${APP}"

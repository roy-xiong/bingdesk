#!/bin/bash
set -euo pipefail

# 所有编译、图标生成和封装均由 GitHub 的 macOS runner 执行。
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build --configuration release --arch arm64
task_bin="$(swift build --configuration release --arch arm64 --show-bin-path)"
task_app="$task_root/dist/BingDesk.app"
task_stage="$task_root/dist/dmg-stage"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_stage"
cp "$task_bin/BingDesk" "$task_app/Contents/MacOS/BingDesk"
cp Resources/Info.plist "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$task_app/Contents/Info.plist"
swift scripts/MakeIcon.swift "$task_root/dist/AppIcon.png"
task_iconset="$task_root/dist/AppIcon.iconset"
mkdir -p "$task_iconset"
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" dist/AppIcon.png --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_double=$((task_size * 2))
    sips -z "$task_double" "$task_double" dist/AppIcon.png --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil --convert icns "$task_iconset" --output "$task_app/Contents/Resources/AppIcon.icns"
# ad-hoc 只满足本机运行所需的代码完整性校验，不声称具备 Developer ID 或公证。
codesign --force --sign - --identifier com.royxiong.bingdesk "$task_app"
codesign --verify --deep --strict --verbose=2 "$task_app"
lipo "$task_app/Contents/MacOS/BingDesk" -verify_arch arm64
plutil -lint "$task_app/Contents/Info.plist"
ditto "$task_app" "$task_stage/BingDesk.app"
ln -s /Applications "$task_stage/Applications"
cp Resources/安装说明.txt "$task_stage/安装说明.txt"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
hdiutil create -volname BingDesk -srcfolder "$task_stage" -format UDZO -ov "dist/BingDesk-${task_version}-arm64.dmg"
hdiutil verify "dist/BingDesk-${task_version}-arm64.dmg"
cd dist
shasum -a 256 BingDesk-*.dmg > SHA256SUMS.txt

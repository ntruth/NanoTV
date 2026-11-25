#!/bin/sh
# 快速验证包：只重编 debug 二进制，复用上一次完整打包的 Luma.app 资源与内置 ffmpeg。
# 完整发布仍然用 PACKAGE=1 ./build.sh。
set -eu
cd "$(dirname "$0")/.."

APP="Luma.app"
IDENTITY="Luma Local Dev"

if [ ! -f "$APP/Contents/Info.plist" ] || [ ! -d "$APP/Contents/Resources" ]; then
    echo "Luma.app 不完整，先做一次完整打包…"
    PACKAGE=0 ./build.sh
    exit 0
fi

swift build --product Luma
BIN="$(swift build --show-bin-path)/Luma"

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Luma"
chmod +x "$APP/Contents/MacOS/Luma"

if ! codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

osascript -e 'tell application id "com.baymax.luma" to quit' >/dev/null 2>&1 || true
sleep 0.5
open "$APP"
echo "快速包已启动：${APP}（debug 构建，未打 zip）"

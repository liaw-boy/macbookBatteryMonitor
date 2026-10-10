#!/bin/bash
# 編譯並打包成 macbookBatteryMonitor.app
#   ./build.sh                 → 系統監控版（電池＋CPU／GPU、記憶體、磁碟、網路）
#   ./build.sh battery         → 電池版（只有電池資訊）
#   ./build.sh install         → 編好後安裝到 /Applications 並啟動（可與 battery 一起用）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="macbookBatteryMonitor"
APP="build/$APP_NAME.app"
EDITION="status"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        battery|status) EDITION="$arg" ;;
        install) INSTALL=1 ;;
        *) echo "用法：./build.sh [battery|status] [install]" >&2; exit 1 ;;
    esac
done

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace MBMEdition -string "$EDITION" "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --timestamp=none "$APP"
echo "✅ 已產生 $APP（$([[ $EDITION == battery ]] && echo 電池版 || echo 系統監控版)）"

if [[ $INSTALL == 1 ]]; then
    pkill -x "$APP_NAME" || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "✅ 已安裝到 /Applications/$APP_NAME.app"
fi

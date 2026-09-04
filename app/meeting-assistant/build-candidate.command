#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_NAME="会议助手"
RUNTIME_PROJECT="/path/to/joycon-voice-controller"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
BUILD_ROOT="$PROJECT_DIR/.build-candidate"
DIST_ROOT="$PROJECT_DIR/dist"
BUILD_BINARY="$BUILD_ROOT/arm64-apple-macosx/release/meeting-assistant"
INFO_TEMPLATE="$PROJECT_DIR/Resources/MeetingAssistant-Info.plist"
STAMP=$(/bin/date "+%Y%m%d-%H%M%S")
OUTPUT_APP="$DIST_ROOT/$APP_NAME-1.4-candidate-$STAMP.app"
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/meeting-assistant-candidate.XXXXXX")
TEMP_APP="$TEMP_ROOT/$APP_NAME.app"

cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$RUNTIME_PROJECT/整理最近会议.command" ]]; then
  echo "找不到现有本地转写入口：$RUNTIME_PROJECT/整理最近会议.command"
  exit 1
fi

if [[ ! -d "$SDK_PATH" ]]; then
  SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
fi

export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swiftpm-module-cache"

cd "$PROJECT_DIR"
/usr/bin/swift build \
  --disable-sandbox \
  --scratch-path "$BUILD_ROOT" \
  -c release \
  --product meeting-assistant

/bin/mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"
/bin/cp "$BUILD_BINARY" "$TEMP_APP/Contents/MacOS/$APP_NAME"
/bin/chmod 755 "$TEMP_APP/Contents/MacOS/$APP_NAME"
/bin/cp "$INFO_TEMPLATE" "$TEMP_APP/Contents/Info.plist"
/usr/bin/plutil -replace JoyConProjectPath -string "$RUNTIME_PROJECT" "$TEMP_APP/Contents/Info.plist"

ICON_PNG="$TEMP_ROOT/MeetingAssistant-1024.png"
/usr/bin/swift "$PROJECT_DIR/Scripts/generate_meeting_app_icon.swift" "$ICON_PNG"
/usr/bin/python3 "$PROJECT_DIR/Scripts/png_to_icns.py" \
  "$ICON_PNG" \
  "$TEMP_APP/Contents/Resources/MeetingAssistant.icns"

/usr/bin/plutil -lint "$TEMP_APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign - "$TEMP_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$TEMP_APP"

/bin/mkdir -p "$DIST_ROOT"
/usr/bin/ditto "$TEMP_APP" "$OUTPUT_APP"
echo "$OUTPUT_APP"

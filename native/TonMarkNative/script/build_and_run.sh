#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="TonMark"
EXECUTABLE_NAME="TonMarkNative"
APP_DIR="$ROOT/dist/$APP_DISPLAY_NAME.app"
EXECUTABLE="$ROOT/.build/debug/$EXECUTABLE_NAME"
WEB_ROOT="$ROOT/Resources/Web"
ICON_FILE="$ROOT/Resources/AppIcon.icns"
LAUNCH_AFTER_BUILD=true
VERIFY_AFTER_LAUNCH=false

for arg in "$@"; do
  case "$arg" in
    --no-launch)
      LAUNCH_AFTER_BUILD=false
      ;;
    --verify)
      VERIFY_AFTER_LAUNCH=true
      ;;
  esac
done

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

cd "$ROOT"
swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Web"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$WEB_ROOT" "$APP_DIR/Contents/Resources/Web"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TonMarkNative</string>
  <key>CFBundleIdentifier</key>
  <string>io.tonmark.native</string>
  <key>CFBundleName</key>
  <string>TonMark</string>
  <key>CFBundleDisplayName</key>
  <string>TonMark</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_DIR"

if [[ "$LAUNCH_AFTER_BUILD" == true ]]; then
  /usr/bin/open -n "$APP_DIR"
fi

if [[ "$VERIFY_AFTER_LAUNCH" == true ]]; then
  sleep 2
  pgrep -x "$EXECUTABLE_NAME" >/dev/null
fi

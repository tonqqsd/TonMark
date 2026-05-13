#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="TonMark"
EXECUTABLE_NAME="TonMarkNative"
CONFIGURATION="debug"
APP_DIR="$ROOT/dist/$APP_DISPLAY_NAME.app"
WEB_ROOT="$ROOT/Resources/Web"
ICON_FILE="$ROOT/Resources/AppIcon.icns"
TONMARK_VERSION="${TONMARK_VERSION:-0.2.0}"
TONMARK_BUILD_NUMBER="${TONMARK_BUILD_NUMBER:-2}"
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
    --release)
      CONFIGURATION="release"
      ;;
    --debug)
      CONFIGURATION="debug"
      ;;
  esac
done

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

cd "$ROOT"
if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release
else
  swift build
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Web"
EXECUTABLE="$ROOT/.build/$CONFIGURATION/$EXECUTABLE_NAME"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$WEB_ROOT" "$APP_DIR/Contents/Resources/Web"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
  <string>$TONMARK_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$TONMARK_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
        <string>mkd</string>
      </array>
      <key>CFBundleTypeIconFile</key>
      <string>AppIcon</string>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.markdown</string>
        <string>net.daringfireball.markdown</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Folder</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
        <string>public.text</string>
      </array>
      <key>UTTypeDescription</key>
      <string>Markdown Document</string>
      <key>UTTypeIdentifier</key>
      <string>net.daringfireball.markdown</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>md</string>
          <string>markdown</string>
          <string>mdown</string>
          <string>mkd</string>
        </array>
        <key>public.mime-type</key>
        <string>text/markdown</string>
      </dict>
    </dict>
  </array>
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

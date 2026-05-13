#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${TONMARK_VERSION:-0.2.0}"
BUILD_NUMBER="${TONMARK_BUILD_NUMBER:-2}"
APP_NAME="TonMark"
APP_DIR="$ROOT/dist/$APP_NAME.app"
STAGE_DIR="$ROOT/dist/dmg-stage"
DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME $VERSION"

TONMARK_VERSION="$VERSION" TONMARK_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/script/build_and_run.sh" --release --no-launch

rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
ditto "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

(cd "$(dirname "$DMG_PATH")" && shasum -a 256 "$(basename "$DMG_PATH")") | tee "$DMG_PATH.sha256"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

cd "$ROOT"
swift test

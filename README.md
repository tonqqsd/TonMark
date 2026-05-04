# TonMark

TonMark is a native macOS Markdown writing app. The active Swift Package lives in [`native/TonMarkNative`](native/TonMarkNative).

It combines a native AppKit/WebKit shell with a local web editor surface for workspace-based writing, quick navigation, full-text search, snapshots, theme switching, and export.

## Quick Start

```bash
cd native/TonMarkNative
swift build
swift test
node --check Resources/Web/app.js
script/build_and_run.sh
```

See [`native/TonMarkNative/README.md`](native/TonMarkNative/README.md) for the full project guide.

## Included

- macOS AppKit and WebKit application shell
- Markdown editor resources under `Resources/Web`
- workspace path-security core module
- XCTest and Swift Testing coverage for workspace boundary validation
- local build, test, and app-bundle scripts

## Excluded

Generated build output and local artifacts are ignored:

- `.build/`
- `.swiftpm/`
- `dist/`
- `.DS_Store`
- downloaded installer images

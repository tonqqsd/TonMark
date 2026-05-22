# TonMark Native

TonMark Native is the macOS application package for [TonMark](../../README.md): a local-first Markdown workspace built with Swift Package Manager, AppKit, WebKit, and a bundled web editor surface.

## What This Package Contains

- `Sources/TonMarkNative`: the native AppKit window, toolbar, sidebar, Dock menu, file opening, WebKit bridge, export, and workspace integration.
- `Sources/TonMarkCore`: shared path-security and workspace boundary logic.
- `Resources/Web`: the Markdown editor UI, themes, context menus, search panels, and rendering assets.
- `Resources/AppIcon.png`: the current 1024px source image for the macOS app icon.
- `Resources/AppIcon.icns`: the generated icon bundle copied into `TonMark.app`.
- `Tests/TonMarkCoreTests`: XCTest and Swift Testing coverage for workspace path security.
- `script`: repeatable build, test, app-bundle, and DMG packaging entrypoints.

## Requirements

- macOS 12 or later
- Xcode command line tools or Xcode
- Swift 5.9 or later
- Node.js for JavaScript syntax checks

## Build

```bash
swift build
```

Build a release app bundle:

```bash
script/build_and_run.sh --release --no-launch
```

The app bundle is written to:

```text
dist/TonMark.app
```

## Test

```bash
swift test
node --check Resources/Web/app.js
```

Or run the bundled test script:

```bash
script/test.sh
```

## Run Locally

```bash
script/build_and_run.sh
```

Useful variants:

```bash
script/build_and_run.sh --no-launch
script/build_and_run.sh --verify
script/build_and_run.sh --release
```

## Package DMG

```bash
script/package_dmg.sh
```

This creates:

```text
dist/TonMark-0.2.0.dmg
dist/TonMark-0.2.0.dmg.sha256
```

The package is ad-hoc signed for local distribution. A Developer ID certificate and notarization step can be added later for fully trusted public macOS distribution.

## Release Variables

```bash
TONMARK_VERSION=0.2.0 TONMARK_BUILD_NUMBER=2 script/package_dmg.sh
```

The same variables are respected by `script/build_and_run.sh`.

## App Icon

The checked-in icon source is `Resources/AppIcon.png`. `Resources/AppIcon.icns` is generated from that source and is the file consumed by `script/build_and_run.sh`.

The current icon is intentionally minimal: a white macOS-style background and border, a graphite document mark, and a small blue writing accent. It contains no text, account data, screenshots, or local file paths.

## Quality Checks

Before publishing a release, run:

```bash
swift build
swift test
node --check Resources/Web/app.js
script/package_dmg.sh
codesign --verify --deep --strict --verbose=2 dist/TonMark.app
```

## Notes

Generated output is intentionally not tracked:

- `.build/`
- `.swiftpm/`
- `dist/`
- `.DS_Store`
- local DMG files

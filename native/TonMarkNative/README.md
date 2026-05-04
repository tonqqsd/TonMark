# TonMark

TonMark is a native macOS Markdown writing app built with Swift Package Manager, AppKit, WebKit, and a local web editor surface. It focuses on workspace-based long-form writing, quick navigation, full-text search, theme switching, snapshots, and export.

## Features

- Native macOS window, toolbar, sidebar, and file workspace.
- Markdown editing with live preview behavior powered by `Resources/Web`.
- Quick open, workspace search, document outline, and sortable file tree.
- Light, dark, warm, and system-following editor themes.
- HTML and PDF export for the current document.
- Local document snapshots and snapshot history.
- Workspace path validation and WebView file-access hardening in `TonMarkCore`.
- Unit tests for path security and workspace boundary handling.

## Requirements

- macOS 12 or later
- Xcode command line tools or Xcode
- Swift 5.9 or later
- Node.js for JavaScript syntax checks

## Build

```bash
cd TonMarkNative
swift build
```

## Test

```bash
cd TonMarkNative
swift test
node --check Resources/Web/app.js
```

You can also use the bundled test script:

```bash
cd TonMarkNative
script/test.sh
```

## Run

Build an unsigned local app bundle in `dist/` and launch it:

```bash
cd TonMarkNative
script/build_and_run.sh
```

Build without launching:

```bash
cd TonMarkNative
script/build_and_run.sh --no-launch
```

Build, launch, and verify the process starts:

```bash
cd TonMarkNative
script/build_and_run.sh --verify
```

## Project Structure

```text
TonMarkNative/
  Package.swift
  Sources/
    TonMarkNative/     macOS AppKit and WebKit application shell
    TonMarkCore/       shared core logic and path security helpers
  Resources/
    AppIcon.icns
    Web/               editor UI, styles, and bundled web dependencies
  Tests/
    TonMarkCoreTests/  unit tests for core behavior
  Checks/
    TonMarkCoreChecks/ small executable checks for core validation
  script/
    build_and_run.sh
    test.sh
```

## Repository Notes

Generated build output is intentionally excluded from version control:

- `.build/`
- `.swiftpm/`
- `dist/`
- `.DS_Store`
- local Xcode and IDE state

Do not commit local packaged app bundles or downloaded installer images.

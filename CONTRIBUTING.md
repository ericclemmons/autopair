# Contributing

## Requirements

- macOS 14+
- Xcode 15+ (or Swift 5.9+ toolchain)

## Local development

```sh
# Debug build (default)
bash build-app.sh

# Run
open AutoPair.app

# Regression tests (no hardware required)
swift test
```

Debug builds show an unfilled menu bar icon (`link.circle`) to distinguish from the release version (`link.circle.fill`).

## Release build

```sh
bash build-app.sh release
```

Builds with optimizations and strips the binary.

## Releasing

Push to `main` — CI computes and publishes the next patch version automatically.
To build a release locally:

```sh
bash build-app.sh release
```

The release workflows:

1. Increment `Info.plist` and create a version tag
2. Build and notarize a release binary on `macos-14`
3. Create a GitHub Release
4. Update [`ericclemmons/homebrew-tap`](https://github.com/ericclemmons/homebrew-tap)

Users get the update via `brew upgrade ericclemmons/tap/autopair`.

## Project structure

```
Sources/AutoPair/
  AutoPairApp.swift      # App entry point, NSStatusItem + NSMenu
  AppState.swift         # Composition root and persisted selections
  OwnershipTrigger.swift # Trigger protocol, kinds, and factory
  DisplayMonitor.swift   # External-display ownership trigger
  CalDigitDockMonitor.swift # Event-driven IOKit dock trigger
  HandoffController.swift # Ordered peer release → local acquisition
  PeerManager.swift      # Bonjour discovery and handoff protocol
  BluetoothManager.swift # Native IOBluetooth pair/release/connect
  Log.swift              # Unified logging
Tests/AutoPairTests/      # Trigger matching and transaction tests
```

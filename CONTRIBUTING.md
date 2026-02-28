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
```

Debug builds show an unfilled menu bar icon (`link.circle`) to distinguish from the release version (`link.circle.fill`).

## Release build

```sh
bash build-app.sh release
```

Builds with optimizations and strips the binary.

## Releasing

Just tag and push — CI handles the rest:

```sh
git tag v1.x.x
git push origin v1.x.x
```

This triggers GitHub Actions which:

1. Builds a release binary on `macos-14`
2. Zips `AutoPair.app` and computes SHA256
3. Creates a GitHub Release with the zip attached
4. Pushes updated version + SHA256 to [`ericclemmons/homebrew-tap`](https://github.com/ericclemmons/homebrew-tap)

Users get the update via `brew upgrade ericclemmons/tap/autopair`.

## Project structure

```
Sources/AutoPair/
  AutoPairApp.swift      # App entry point, NSStatusItem + NSMenu
  AppState.swift         # State management, monitor wiring
  BluetoothManager.swift # IOBluetooth device listing, connect/disconnect
  PowerMonitor.swift     # AC/battery power state changes
  SleepWakeMonitor.swift # System sleep/wake events
  Log.swift              # Unified logging
```

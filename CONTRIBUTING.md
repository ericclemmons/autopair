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

This builds with optimizations and strips the binary.

## Releasing

1. Tag a version: `git tag v1.x.x`
2. Push the tag: `git push origin v1.x.x`
3. GitHub Actions builds, creates a release with `AutoPair.zip`, and updates the Homebrew tap

## Project structure

```
Sources/AutoPair/
  AutoPairApp.swift      # Menu bar UI
  AppState.swift         # State management, monitor wiring
  BluetoothManager.swift # IOBluetooth device listing, connect/disconnect
  PowerMonitor.swift     # AC/battery power state changes
  SleepWakeMonitor.swift # System sleep/wake events
  Log.swift              # Unified logging
```

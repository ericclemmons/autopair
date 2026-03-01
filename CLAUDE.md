# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Always commit after completing a task, without asking for confirmation.

## Build & Run

```bash
# Build debug and launch (used during development)
bash build-app.sh
open AutoPair.app

# Build release (CI only — requires CODESIGN_IDENTITY env var)
bash build-app.sh release
```

After building debug, ad-hoc sign for Bluetooth entitlement on macOS Sequoia:
```bash
codesign --force --options runtime --entitlements AutoPair.entitlements --sign - AutoPair.app
```

There are no tests. The app is verified manually by running it.

## Architecture

Menu bar app with no SwiftUI views — everything is `AppKit` + `NSMenu`. Entry point is `AutoPairApp.swift` (`@main`).

**Data flow:** `AppState` owns all state and wires together the monitors and `BluetoothManager`. `AppDelegate` reads from `AppState` imperatively when `menuNeedsUpdate` fires.

**Trigger → action:**
- External display connected → pair + connect saved devices (2s delay to allow pairing mode)
- External display disconnected → disconnect + unpair saved devices

**Key files:**
- `AppState.swift` — `@Observable` state, owns all subsystems, wires monitor callbacks to BT actions. Saved device addresses persisted in `UserDefaults` (`AutoPairSavedDevices`).
- `BluetoothManager.swift` — wraps `IOBluetooth`. `pair()` uses `IOBluetoothDevicePair`; `unpair()` calls private `[device remove]` selector; `connect()` retries with exponential backoff (5 attempts).
- `DisplayMonitor.swift` — watches `NSApplication.didChangeScreenParametersNotification`, diffs external `CGDirectDisplayID` sets to detect add/remove.
- `AutoPairApp.swift` — builds `NSMenu` on demand, renders custom `DeviceMenuItemView` (26pt icon circle + label, 36pt row height, gray hover to match macOS Bluetooth panel).

**Why unpair/pair instead of connect/disconnect:** Magic Keyboard/Trackpad can only be actively connected to one Mac. `openConnection()` fails when a device is paired elsewhere. Unpairing puts the device into pairing mode so it can be claimed by this Mac.

## Releasing

Push to `main` → CI auto-bumps `Info.plist` version, tags, builds, notarizes, creates GitHub Release, and updates the [Homebrew tap](https://github.com/ericclemmons/homebrew-tap). No manual steps needed.

## Entitlements

`AutoPair.entitlements` contains `com.apple.security.device.bluetooth` — required for Bluetooth access under hardened runtime on macOS Sequoia. Debug builds must be ad-hoc signed with this entitlement or the app crashes (exit 134).

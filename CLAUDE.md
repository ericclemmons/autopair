# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Always commit after completing a task, without asking for confirmation.

## Build & Run

```bash
make run      # build, sign, kill existing, relaunch
make build    # build only

# Release builds (CI only — requires CODESIGN_IDENTITY env var)
bash build-app.sh release
```

Run `swift test` for the trigger and handoff state-machine regression suite. Hardware
handoffs still require manual verification with two Macs and a selected peripheral.

## Architecture

Menu bar app with no SwiftUI views — everything is `AppKit` + `NSMenu`. Entry point is `AutoPairApp.swift` (`@main`).

**Data flow:** `AppState` owns all state and wires a selected `OwnershipTrigger` to
`HandoffController`, `PeerManager`, and `BluetoothManager`. `AppDelegate` reads from
`AppState` imperatively when `menuNeedsUpdate` fires.

**Trigger → action:**
- Selected trigger becomes active → ask Bonjour peers to release → pair/connect locally
- Peer release request → unpair locally → acknowledge only after release completes
- Trigger becomes inactive → release immediately before a closed-lid Mac can sleep

**Key files:**
- `AppState.swift` — composition root; persists selected devices and trigger.
- `OwnershipTrigger.swift` — pluggable ownership signal protocol, enum, and factory.
- `DisplayMonitor.swift` — external-display trigger using screen notifications.
- `CalDigitDockMonitor.swift` — CalDigit trigger using IOKit notifications.
- `HandoffController.swift` — testable ordered release/acquire state machine.
- `PeerManager.swift` — Bonjour discovery and acknowledgment protocol between Macs.
- `BluetoothManager.swift` — native pairing, connection verification, and private `remove`; no `blueutil` or radio power cycle.
- `AutoPairApp.swift` — builds `NSMenu` on demand, renders custom `DeviceMenuItemView` (26pt icon circle + label, 36pt row height, gray hover to match macOS Bluetooth panel).

**Why coordinated unpair/pair instead of connect/disconnect:** Magic Keyboard/Trackpad
can invalidate the other Mac's bond. The destination waits for an explicit peer
release acknowledgment, then tries an existing bond and falls back to native pairing.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The repo uses the default five-role triage vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

## Releasing

Push to `main` → CI auto-bumps `Info.plist` version, tags, builds, notarizes, creates GitHub Release, and updates the [Homebrew tap](https://github.com/ericclemmons/homebrew-tap). No manual steps needed.

## Entitlements

`AutoPair.entitlements` contains `com.apple.security.device.bluetooth` — required for Bluetooth access under hardened runtime on macOS Sequoia. Debug builds must be ad-hoc signed with this entitlement or the app crashes (exit 134).

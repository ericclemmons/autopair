# ADR 0004: Detect external displays with CoreGraphics

## Status

Accepted

## Context

An Acer X34 appeared in macOS Display Settings while AutoPair's `NSScreen`-only monitor
remained inactive. AppKit screen notifications can be missed or expose an incomplete
screen set around login, clamshell, and WindowServer display-session transitions.

## Decision

- Subscribe to `CGDisplayRegisterReconfigurationCallback` as the primary display event.
- Enumerate `CGGetOnlineDisplayList` and classify displays with `CGDisplayIsBuiltin`.
- Reconcile 350 ms after the last event so WindowServer can finish applying display modes.
- Retain `NSApplication.didChangeScreenParametersNotification` as a fallback.
- Record the GUI process's display IDs and classification in Copy Diagnostics.

## Consequences

External-display ownership no longer depends solely on `NSScreen` or one AppKit
notification. Display names still come from `NSScreen` when available; otherwise the
trigger uses the generic name “External display.” Actual hot-plug behavior remains a
hardware-in-the-loop test.

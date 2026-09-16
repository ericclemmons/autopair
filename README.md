<p align="center">
  <img src="icon.png" width="128" height="128" alt="AutoPair icon">
</p>

# AutoPair

AutoPair hands Apple Bluetooth peripherals between Macs when a physical ownership
signal appears. Use an external display or any attached USB/Thunderbolt device as
the signal; the Mac with that signal asks its trusted peer to release the devices.

## Install

```sh
brew install --cask ericclemmons/tap/autopair
open /Applications/AutoPair.app
```

Install and run AutoPair on **both Macs**. Approve Bluetooth and Local Network
access when macOS asks.

## Set up both Macs

1. Pair the keyboard, mouse, or trackpad normally with each Mac at least once.
2. Open AutoPair and select the same devices on each Mac.
3. On one Mac, choose **Trusted Computers → Show Pairing Code…**.
4. On the other, choose **Trusted Computers → Pair Another Mac**, select the first
   Mac, and enter its temporary six-digit code.
5. Open **Ownership Trigger** and choose one of:
   - **External Display** — preserves AutoPair's original behavior.
   - **Connected Hardware** — select a currently attached USB/Thunderbolt device.
6. Attach the chosen display or hardware to the Mac that should own the devices.

If a device was asleep during a handoff, wake it and choose **Retry Handoff**.

## How handoff works

```text
Selected trigger becomes active on Mac B
        ↓
Mac B sends an authenticated release request to its trusted peer
        ↓
Mac A removes its pairing and confirms the devices are disconnected
        ↓
Mac B pairs and connects through Apple's native IOBluetooth framework
```

The losing Mac releases when its trigger disappears. For a closed-lid Mac, AutoPair
also participates in macOS power notifications: it briefly delays the final sleep
acknowledgement until the selected devices are released (with a 12-second safety
limit). A destination that is still acquiring, or acquired within the last 10 seconds,
keeps its devices through transient clamshell/login sleep notifications. A stable owner
also keeps its pairing through ordinary sleep while the dock still supplies power. If
dock power disappears, it releases before sleep even when macOS has not yet removed the
external display from its online-display list. The winning Mac requests peer release if the old
Mac becomes unreachable. AutoPair no longer embeds `blueutil` or power-cycles Bluetooth.
Transient dock re-enumeration is debounced, duplicate ownership events are ignored, and
a Mac with an active physical trigger will not honor a peer's release request. AutoPair
also re-evaluates current ownership after wake instead of preserving a stale menu state.
Pairing completion is based on macOS's observed device state rather than a delegate
callback, and an open menu updates its handoff status live. If the initial pairing burst
fails while the ownership trigger remains active, AutoPair starts a new coordinated
handoff after a 10-second cooldown and keeps recovering until ownership changes.

Hardware detection is event-driven (IOKit first-match and termination notifications),
not polling. AutoPair records serial number when available, otherwise vendor/product
IDs, so the trigger survives restarts and changing ports. Docks exposing multiple
components also get a vendor-level hardware choice. Existing CalDigit configuration
is migrated automatically.

External-display detection uses CoreGraphics display-reconfiguration events and its
online-display list, with AppKit screen notifications as a fallback. Diagnostics include
the display IDs and built-in/external classification observed inside AutoPair.

Pairing codes expire after five minutes and allow five attempts. Successful pairing
creates a random 256-bit shared secret. Handoff messages are authenticated with
HMAC-SHA256, expire after 60 seconds, and include replay-protected nonces. Unpaired
AutoPair instances can be discovered for setup but cannot release devices.

## Caveats

- Both Macs must be awake, running AutoPair, and on the same local network during
  initial computer pairing. Proactive release handles the closed-lid cable move later.
- Apple Magic devices may need a click or key press to wake before pairing.
- Legacy saved addresses whose Bluetooth metadata is no longer available appear as
  **Unknown Saved Device** so they can be removed instead of silently participating
  in handoffs.
- Choose **Collect Diagnostics from All Macs…** after a failed handoff to copy AutoPair's
  recent trigger, sleep, release, and acquisition timelines from this Mac and every
  reachable trusted Mac. Sleeping, offline, and older peers are marked unavailable.
- AutoPair uses IOBluetooth's private `remove` selector to release a pairing. This is
  suitable for a directly distributed/notarized app, but not for the Mac App Store,
  and a future macOS release could change it.
- Bonjour discovery triggers macOS's Local Network permission prompt. Bluetooth
  permission is also required. Neither Accessibility nor Full Disk Access is needed.
- The six-digit code is intended for quick, in-person pairing. Generate it only while
  both Macs are present and cancel the code window when setup is finished.

## Adding another trigger

Implement `OwnershipTrigger`, add its case to `OwnershipTriggerKind`, and construct it
in `OwnershipTriggerFactory`. The built-in Connected Hardware trigger already supports
new USB and Thunderbolt products without code changes.

## Development

```sh
make run
swift test
```

## Releasing

Every push to `main` auto-creates the next patch tag. CI builds, signs, notarizes,
creates the GitHub Release, and updates the
[Homebrew tap](https://github.com/ericclemmons/homebrew-tap).

## Uninstall

```sh
brew uninstall autopair
```

Or delete `/Applications/AutoPair.app` and remove
`~/Library/Preferences/com.ericclemmons.AutoPair.plist`.

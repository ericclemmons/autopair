<p align="center">
  <img src="icon.png" width="128" height="128" alt="AutoPair icon">
</p>

# AutoPair

AutoPair hands Apple Bluetooth peripherals between Macs when a physical ownership
signal appears. Use an external display or a CalDigit dock as the signal; the Mac
with that signal asks the other Mac to release the devices before connecting them.

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
3. Open **Ownership Trigger** and choose one of:
   - **External Display** — preserves AutoPair's original behavior.
   - **CalDigit Dock** — watches the macOS I/O Registry for a CalDigit USB device.
4. Confirm that the menu says `1 other Mac found` on both Macs.
5. Attach the chosen display or dock to the Mac that should own the devices.

If a device was asleep during a handoff, wake it and choose **Retry Handoff**.

## How handoff works

```text
Selected trigger becomes active on Mac B
        ↓
Mac B asks every AutoPair peer to release the selected devices
        ↓
Mac A removes its pairing and confirms the devices are disconnected
        ↓
Mac B pairs and connects through Apple's native IOBluetooth framework
```

The losing Mac releases immediately when its trigger disappears. This is important
for a closed-lid Mac that will sleep and may lose dock Ethernet as soon as the cable
is unplugged. The winning Mac also requests and waits for peer release when the old
Mac remains reachable. AutoPair no longer embeds `blueutil` or power-cycles Bluetooth.

CalDigit detection is event-driven (IOKit first-match and termination notifications),
not polling. It matches CalDigit's USB vendor ID (`0x2188`) and also accepts registry
manufacturer/product names containing `CalDigit`, which covers docks whose USB
bridge reports a different vendor ID.

## Caveats

- Both Macs must be awake, running AutoPair, and on the same trusted local network.
- Apple Magic devices may need a click or key press to wake before pairing.
- AutoPair uses IOBluetooth's private `remove` selector to release a pairing. This is
  suitable for a directly distributed/notarized app, but not for the Mac App Store,
  and a future macOS release could change it.
- Bonjour discovery triggers macOS's Local Network permission prompt. Bluetooth
  permission is also required. Neither Accessibility nor Full Disk Access is needed.
- Peer messages are limited to AutoPair's Bonjour service and locally selected device
  addresses, but are not cryptographically authenticated. Use this on a trusted LAN.

## Adding another trigger

Implement `OwnershipTrigger`, add its case to `OwnershipTriggerKind`, and construct it
in `OwnershipTriggerFactory`. Handoff and Bluetooth code do not need to change.

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

<p align="center">
  <img src="icon.png" width="128" height="128" alt="AutoPair icon">
</p>

# AutoPair

macOS menu bar app that automatically connects and disconnects Bluetooth devices based on power state and sleep/wake events.

When you plug into AC power or wake your Mac on AC, AutoPair connects your selected devices. When you switch to battery or sleep, it disconnects them.

## Install

```sh
brew install --cask ericclemmons/tap/autopair
open /Applications/AutoPair.app
```

## Usage

1. Click the link icon in the menu bar
2. Select Bluetooth devices to auto-connect (hover **More Devices...** to add)
3. That's it — AutoPair handles connect/disconnect automatically

## How it works

- **AC power detected** → connects saved devices
- **Battery detected** → disconnects saved devices
- **Wake on AC** → connects saved devices
- **Sleep** → disconnects saved devices

## Releasing

Every push to `main` auto-creates a **Release PR**. Merge it and CI handles the rest — tags, builds, GitHub Release, and [Homebrew tap](https://github.com/ericclemmons/homebrew-tap) update.

## Uninstall

```sh
brew uninstall autopair
```

Or delete `/Applications/AutoPair.app` and remove `~/Library/Preferences/com.ericclemmons.AutoPair.plist`.

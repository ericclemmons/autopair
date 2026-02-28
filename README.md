# AutoPair

macOS menu bar app that automatically connects and disconnects Bluetooth devices based on power state and sleep/wake events.

When you plug into AC power or wake your Mac on AC, AutoPair connects your selected devices. When you switch to battery or sleep, it disconnects them.

## Install

```sh
brew install --cask ericclemmons/tap/autopair
xattr -rd com.apple.quarantine /Applications/AutoPair.app
open /Applications/AutoPair.app
```

The `xattr` step is needed once because the app is not signed. Alternatively, right-click the app and choose **Open** on first launch.

## Usage

1. Click the link icon in the menu bar
2. Check the Bluetooth devices you want to auto-connect
3. That's it — AutoPair handles connect/disconnect automatically

## How it works

- **AC power detected** → connects saved devices
- **Battery detected** → disconnects saved devices
- **Wake on AC** → connects saved devices
- **Sleep** → disconnects saved devices

## Uninstall

```sh
brew uninstall autopair
```

Or delete `/Applications/AutoPair.app` and remove `~/Library/Preferences/com.ericclemmons.AutoPair.plist`.

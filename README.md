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
2. Select Bluetooth devices to auto-connect (hover **More Devices...** to add)
3. That's it — AutoPair handles connect/disconnect automatically

## How it works

- **AC power detected** → connects saved devices
- **Battery detected** → disconnects saved devices
- **Wake on AC** → connects saved devices
- **Sleep** → disconnects saved devices

## Releasing

Push a version tag and everything is automated:

```sh
git tag v1.x.x && git push origin v1.x.x
```

GitHub Actions builds a release `.zip`, creates a GitHub Release, and updates the [Homebrew tap](https://github.com/ericclemmons/homebrew-tap) — no manual steps.

## Uninstall

```sh
brew uninstall autopair
```

Or delete `/Applications/AutoPair.app` and remove `~/Library/Preferences/com.ericclemmons.AutoPair.plist`.

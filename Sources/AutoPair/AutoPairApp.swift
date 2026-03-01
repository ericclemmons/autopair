import AppKit

@main
enum AutoPairApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #if DEBUG
        let iconName = "link.circle"
        #else
        let iconName = "link.circle.fill"
        #endif
        statusItem.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "AutoPair")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appState.refreshDevices()

        let saved = appState.pairedDevices.filter { appState.isDeviceSaved($0.address) }
        let others = appState.pairedDevices.filter { !appState.isDeviceSaved($0.address) }

        // Header
        let header = NSMenuItem(title: "Auto-connect when display attached", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Saved devices
        if saved.isEmpty {
            let empty = NSMenuItem(title: "No devices selected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for device in saved {
                menu.addItem(makeDeviceMenuItem(device))
            }
        }

        // More Devices submenu
        if !others.isEmpty {
            menu.addItem(.separator())

            let moreItem = NSMenuItem(title: "More Devices...", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for device in others {
                submenu.addItem(makeDeviceMenuItem(device))
            }
            moreItem.submenu = submenu
            menu.addItem(moreItem)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Devices", action: #selector(refreshDevices), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - NSMenuDelegate

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            (menuItem.view as? DeviceMenuItemView)?.needsDisplay = true
        }
    }

    // MARK: - Actions

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        appState.toggleDevice(address)
    }

    private func makeDeviceMenuItem(_ device: BluetoothDevice) -> NSMenuItem {
        let name = device.name.isEmpty ? device.address : device.name
        let icon = makeDeviceIcon(symbolName: device.deviceIcon, isConnected: device.isConnected)
        let item = NSMenuItem(title: name, action: #selector(toggleDevice(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.address
        item.view = DeviceMenuItemView(address: device.address, name: name, icon: icon)
        return item
    }

    @objc private func refreshDevices() {
        appState.refreshDevices()
    }

    // MARK: - Device Icon Rendering

    private func makeDeviceIcon(symbolName: String, isConnected: Bool) -> NSImage {
        let size: CGFloat = 26
        let symbolPt: CGFloat = 14
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Full circle — blue (connected) or gray (disconnected), matches Bluetooth panel
            let bgColor: NSColor = isConnected ? .controlAccentColor : NSColor(white: 0.55, alpha: 1.0)
            bgColor.setFill()
            NSBezierPath(ovalIn: rect).fill()

            // White SF Symbol — render at fixed point size, draw centered in circle
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: symbolPt, weight: .semibold)) else { return true }

            // Tint white by compositing over a white fill
            let tinted = NSImage(size: symbol.size, flipped: false) { symRect in
                symbol.draw(in: symRect)
                NSColor.white.setFill()
                symRect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false

            let x = ((rect.width - tinted.size.width) / 2).rounded()
            let y = ((rect.height - tinted.size.height) / 2).rounded()
            tinted.draw(in: NSRect(x: x, y: y, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        result.isTemplate = false
        return result
    }
}

// MARK: - Custom menu item view (gray hover, matches Bluetooth panel)

private final class DeviceMenuItemView: NSView {
    let address: String
    private let deviceName: String
    private let iconImage: NSImage

    init(address: String, name: String, icon: NSImage) {
        self.address = address
        self.deviceName = name
        self.iconImage = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            let hoverRect = bounds.insetBy(dx: 6, dy: 3)
            NSColor(white: 0.0, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: hoverRect, xRadius: 5, yRadius: 5).fill()
        }

        let iconSize: CGFloat = 26
        let iconX: CGFloat = 16
        let iconY = (bounds.height - iconSize) / 2
        iconImage.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ]
        let str = NSAttributedString(string: deviceName, attributes: attrs)
        let textX = iconX + iconSize + 8
        let textY = (bounds.height - str.size().height) / 2
        str.draw(at: NSPoint(x: textX, y: textY))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem else { return }
        NSApp.sendAction(item.action!, to: item.target, from: item)
        item.menu?.cancelTracking()
    }
}

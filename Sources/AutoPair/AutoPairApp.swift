import SwiftUI
import AppKit

@main
struct AutoPairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
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
                let item = NSMenuItem(
                    title: device.name.isEmpty ? device.address : device.name,
                    action: #selector(toggleDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.address
                item.image = makeDeviceIcon(symbolName: device.deviceIcon, isConnected: device.isConnected)
                menu.addItem(item)
            }
        }

        // More Devices submenu
        if !others.isEmpty {
            menu.addItem(.separator())

            let moreItem = NSMenuItem(title: "More Devices...", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for device in others {
                let item = NSMenuItem(
                    title: device.name.isEmpty ? device.address : device.name,
                    action: #selector(toggleDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.address
                item.image = makeDeviceIcon(symbolName: device.deviceIcon, isConnected: device.isConnected)
                submenu.addItem(item)
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

    // MARK: - Actions

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        appState.toggleDevice(address)
    }

    @objc private func refreshDevices() {
        appState.refreshDevices()
    }

    // MARK: - Device Icon Rendering

    private func makeDeviceIcon(symbolName: String, isConnected: Bool) -> NSImage {
        let size: CGFloat = 20
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Light gray filled circle — matches macOS Bluetooth menu style
            let circle = NSBezierPath(ovalIn: rect)
            NSColor(white: 0.58, alpha: 1.0).setFill()
            circle.fill()

            // Dark icon centered in circle — same contrast as macOS Bluetooth
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {

                let tinted = NSImage(size: symbol.size, flipped: false) { symRect in
                    symbol.draw(in: symRect)
                    NSColor(white: 0.25, alpha: 1.0).setFill()
                    symRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.isTemplate = false

                let x = (rect.width - tinted.size.width) / 2
                let y = (rect.height - tinted.size.height) / 2
                tinted.draw(
                    in: NSRect(x: x, y: y, width: tinted.size.width, height: tinted.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1.0
                )
            }

            return true
        }
        result.isTemplate = false
        return result
    }
}

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
    private weak var statusHeader: NSMenuItem?
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
        statusItem.button?.toolTip = "AutoPair: \(appState.statusText)"
        appState.onStatusChange = { [weak self] in self?.updateStatusPresentation() }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appState.refreshDevices()

        let saved = appState.menuSavedDevices
        let others = appState.pairedDevices.filter { !appState.isDeviceSaved($0.address) }

        // Header
        let header = NSMenuItem(title: "AutoPair: \(appState.statusText)", action: nil, keyEquivalent: "")
        statusHeader = header
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

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

        let triggerItem = NSMenuItem(title: "Ownership Trigger", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()

        let display = NSMenuItem(title: OwnershipTriggerKind.externalDisplay.title,
                                 action: #selector(selectDisplayTrigger), keyEquivalent: "")
        display.target = self
        display.state = appState.triggerKind == .externalDisplay ? .on : .off
        triggerMenu.addItem(display)

        let hardware = NSMenuItem(title: OwnershipTriggerKind.connectedHardware.title,
                                  action: nil, keyEquivalent: "")
        hardware.state = appState.triggerKind == .connectedHardware ? .on : .off
        let hardwareMenu = NSMenu()
        let availableHardware = appState.availableHardware()
        if let selected = appState.selectedHardware,
           !availableHardware.contains(where: selected.matches) {
            let current = NSMenuItem(title: "\(selected.title) — Disconnected",
                                     action: nil, keyEquivalent: "")
            current.state = appState.triggerKind == .connectedHardware ? .on : .off
            current.isEnabled = false
            hardwareMenu.addItem(current)
            hardwareMenu.addItem(.separator())
        }
        if availableHardware.isEmpty {
            let empty = NSMenuItem(title: "No external hardware found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            hardwareMenu.addItem(empty)
        } else {
            for candidate in availableHardware {
                let item = NSMenuItem(title: candidate.title,
                                      action: #selector(selectHardwareTrigger(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = try? JSONEncoder().encode(candidate)
                item.state = appState.triggerKind == .connectedHardware
                    && appState.selectedHardware?.matches(candidate) == true ? .on : .off
                hardwareMenu.addItem(item)
            }
        }
        hardware.submenu = hardwareMenu
        triggerMenu.addItem(hardware)
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        menu.addItem(makeComputersMenuItem())

        if appState.handoffState == .failed {
            let retry = NSMenuItem(title: "Retry Handoff", action: #selector(retryHandoff), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())

        let diagnostics = NSMenuItem(title: "Copy Diagnostics",
                                     action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = NSMutableAttributedString(string: "Quit")
        title.append(NSAttributedString(string: "  v\(version)", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
        ]))
        quitItem.attributedTitle = title
        menu.addItem(quitItem)
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

    @objc private func selectDisplayTrigger() {
        appState.setTriggerKind(.externalDisplay)
    }

    @objc private func selectHardwareTrigger(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? Data,
              let hardware = try? JSONDecoder().decode(HardwareIdentity.self, from: data) else { return }
        appState.setHardwareTrigger(hardware)
    }

    @objc private func retryHandoff() {
        appState.retryHandoff()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.contents(), forType: .string)
    }

    private func updateStatusPresentation() {
        let title = "AutoPair: \(appState.statusText)"
        statusItem?.button?.toolTip = title
        statusHeader?.title = title
    }

    @objc private func showPairingCode() {
        let code = appState.generatePairingCode()
        let codeField = NSTextField(labelWithString: code)
        codeField.alignment = .center
        codeField.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        codeField.isSelectable = true
        codeField.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
        let alert = NSAlert()
        alert.messageText = "Pair This Mac"
        alert.informativeText = "On your other Mac, choose Pair Another Mac and enter this code. It expires in 5 minutes."
        alert.accessoryView = codeField
        alert.addButton(withTitle: "Done")
        present(alert)
        appState.cancelPairingCode()
    }

    @objc private func pairComputer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let computer = appState.discoveredComputers.first(where: { $0.id == id }) else { return }
        let input = NSTextField(string: "")
        input.placeholderString = "6-digit code"
        input.alignment = .center
        input.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)

        let alert = NSAlert()
        alert.messageText = "Pair with \(computer.name)"
        alert.informativeText = "Enter the code shown by AutoPair on \(computer.name)."
        alert.accessoryView = input
        alert.addButton(withTitle: "Pair Computer")
        alert.addButton(withTitle: "Not Now")
        guard present(alert) == .alertFirstButtonReturn else { return }

        let code = input.stringValue.filter(\.isNumber)
        guard code.count == 6 else {
            showResult(title: "Code Needs 6 Digits",
                       message: "Show a new pairing code on \(computer.name) and enter all 6 digits.")
            return
        }
        appState.pairComputer(id, code: code) { [weak self] result in
            switch result {
            case .success(let trusted):
                self?.showResult(title: "\(trusted.name) Is Trusted",
                                 message: "Only paired computers can now request Bluetooth handoffs.")
            case .failure(let error):
                self?.showResult(title: "Couldn't Pair Computers",
                                 message: error.localizedDescription)
            }
        }
    }

    @objc private func forgetComputer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        appState.forgetComputer(id)
    }

    private func makeComputersMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Trusted Computers", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let thisMac = NSMenuItem(title: "This Mac: \(appState.thisComputer.name)",
                                 action: nil, keyEquivalent: "")
        thisMac.isEnabled = false
        submenu.addItem(thisMac)
        submenu.addItem(.separator())

        if appState.trustedComputers.isEmpty {
            let empty = NSMenuItem(title: "No trusted computers", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for computer in appState.trustedComputers {
                let trusted = NSMenuItem(title: computer.name, action: nil, keyEquivalent: "")
                trusted.state = .on
                let computerMenu = NSMenu()
                let forget = NSMenuItem(title: "Forget Computer",
                                        action: #selector(forgetComputer(_:)), keyEquivalent: "")
                forget.target = self
                forget.representedObject = computer.id
                computerMenu.addItem(forget)
                trusted.submenu = computerMenu
                submenu.addItem(trusted)
            }
        }

        submenu.addItem(.separator())
        let add = NSMenuItem(title: "Pair Another Mac", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        if appState.discoveredComputers.isEmpty {
            let none = NSMenuItem(title: "No unpaired Macs found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            addMenu.addItem(none)
        } else {
            for computer in appState.discoveredComputers {
                let peer = NSMenuItem(title: computer.name,
                                      action: #selector(pairComputer(_:)), keyEquivalent: "")
                peer.target = self
                peer.representedObject = computer.id
                addMenu.addItem(peer)
            }
        }
        add.submenu = addMenu
        submenu.addItem(add)

        let showCode = NSMenuItem(title: "Show Pairing Code…",
                                  action: #selector(showPairingCode), keyEquivalent: "")
        showCode.target = self
        submenu.addItem(showCode)
        item.submenu = submenu
        return item
    }

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func showResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Done")
        present(alert)
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

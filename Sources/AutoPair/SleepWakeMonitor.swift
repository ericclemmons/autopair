import AppKit

final class SleepWakeMonitor {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    init() {
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func willSleep(_ notification: Notification) {
        onSleep?()
    }

    @objc private func didWake(_ notification: Notification) {
        onWake?()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

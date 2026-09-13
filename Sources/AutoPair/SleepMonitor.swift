import Foundation
import IOKit
import IOKit.pwr_mgt

// These public IOKit macros are not imported into Swift because they compose
// C error-system bit fields. Expanded values from IOMessage.h/IOReturn.h.
private let messageCanSystemSleep: natural_t = 0xe0000270
private let messageSystemWillSleep: natural_t = 0xe0000280

/// Delays imminent sleep long enough to release selected Bluetooth devices.
final class SleepMonitor {
    var onWillSleep: ((@escaping () -> Void) -> Void)?
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pendingAcknowledgement: (port: io_connect_t, token: Int)?

    func start() {
        guard rootPort == 0 else { return }
        var port: IONotificationPortRef?
        var object: io_object_t = 0
        let connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port, sleepPowerCallback, &object
        )
        guard connection != 0, let port else {
            Diagnostics.record("power registration failed")
            return
        }
        rootPort = connection
        notificationPort = port
        notifier = object
        IONotificationPortSetDispatchQueue(port, .main)
        Diagnostics.record("power notifications started")
    }

    fileprivate func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch messageType {
        case messageSystemWillSleep:
            Diagnostics.record("system will sleep; beginning final release")
            pendingAcknowledgement = (rootPort, token)
            var finished = false
            let finish = { [weak self] in
                guard !finished else { return }
                finished = true
                self?.acknowledgeSleep()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: finish)
            if let onWillSleep { onWillSleep(finish) } else { finish() }
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPort, token)
        default:
            break
        }
    }

    private func acknowledgeSleep() {
        guard let pending = pendingAcknowledgement else { return }
        pendingAcknowledgement = nil
        Diagnostics.record("final release finished; allowing sleep")
        IOAllowPowerChange(pending.port, pending.token)
    }

    func stop() {
        acknowledgeSleep()
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notifier = 0
        rootPort = 0
        notificationPort = nil
    }

    deinit { stop() }
}

private func sleepPowerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t,
                                _ messageType: natural_t,
                                _ messageArgument: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<SleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .handle(messageType: messageType, argument: messageArgument)
}

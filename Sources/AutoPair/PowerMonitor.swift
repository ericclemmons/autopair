import Foundation
import IOKit.ps

final class PowerMonitor {
    var onACPower: (() -> Void)?
    var onBattery: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var wasOnAC: Bool

    init() {
        wasOnAC = Self.isOnACPower()

        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.powerSourceDidChange()
        }, context).takeRetainedValue()

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        log.info("PowerMonitor: initialized, onAC=\(self.wasOnAC)")
    }

    var isOnAC: Bool { Self.isOnACPower() }

    private func powerSourceDidChange() {
        let nowOnAC = Self.isOnACPower()
        log.info("PowerMonitor: power changed, wasOnAC=\(self.wasOnAC) nowOnAC=\(nowOnAC)")
        defer { wasOnAC = nowOnAC }

        if nowOnAC && !wasOnAC {
            log.info("PowerMonitor: → AC power")
            onACPower?()
        } else if !nowOnAC && wasOnAC {
            log.info("PowerMonitor: → battery")
            onBattery?()
        }
    }

    private static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
              let powerSource = desc[kIOPSPowerSourceStateKey] as? String
        else {
            log.warning("PowerMonitor: can't read power source, assuming AC")
            return true
        }
        return powerSource == kIOPSACPowerValue
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}

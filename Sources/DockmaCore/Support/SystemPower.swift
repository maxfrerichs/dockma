import Foundation
import IOKit.pwr_mgt

// shortcut: no HasPoweredOn arrived on a dark wake (seen once, macOS 27.2), so
// the 30 s timer syncs the guest then; revisit if containers need the right time in dark wakes.
/// Calls a handler on the main run loop each time the Mac fully wakes from sleep.
@MainActor
public final class SystemPower {
    /// What to do with an IOKit system power message.
    enum Action: Equatable {
        /// Let the sleep go ahead. A registered client that doesn't answer
        /// holds up every sleep by 30 s.
        case allowSleep
        case wake
        case ignore
    }

    // iokit_common_msg() values; Swift doesn't import the function-like macro.
    nonisolated static let canSystemSleep: UInt32 = 0xE000_0270
    nonisolated static let systemWillSleep: UInt32 = 0xE000_0280
    nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: () -> Void
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// Registers for power messages, or returns nil when IOKit refuses. The
    /// observer stays registered until it is released, which must happen on
    /// the main actor: a deinit queued from elsewhere could race a callback.
    public init?(onWake: @escaping () -> Void) {
        self.onWake = onWake
        // Unretained: deinit deregisters before IOKit could use a dangling pointer.
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort, { refcon, _, message, argument in
            guard let refcon else { return }
            let power = Unmanaged<SystemPower>.fromOpaque(refcon).takeUnretainedValue()
            // The source is on the main run loop.
            MainActor.assumeIsolated { power.handle(message, notificationID: Int(bitPattern: argument)) }
        }, &notifier)
        guard rootPort != 0, let notificationPort else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(), .defaultMode)
    }

    // Also runs after a failed init, so it checks what was registered.
    isolated deinit {
        if let notificationPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(), .defaultMode)
        }
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    /// The action for one power message.
    nonisolated static func action(for message: UInt32) -> Action {
        switch message {
        case canSystemSleep, systemWillSleep: .allowSleep
        case systemHasPoweredOn: .wake
        default: .ignore
        }
    }

    /// Answers or forwards one power message.
    private func handle(_ message: UInt32, notificationID: Int) {
        switch Self.action(for: message) {
        case .allowSleep: IOAllowPowerChange(rootPort, notificationID)
        case .wake: onWake()
        case .ignore: break
        }
    }
}

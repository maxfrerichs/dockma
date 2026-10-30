import Foundation

/// Blocking waits for kernel events through a kqueue: a process exiting.
public final class KernelEvents {
    /// What woke a `wait(timeout:)`.
    public enum Event: Equatable, Sendable {
        case processExited
    }

    private let queue: Int32

    /// Creates an empty kqueue.
    public init() throws {
        queue = kqueue()
        guard queue >= 0 else { throw DockmaError.posix("kqueue") }
    }

    deinit {
        close(queue)
    }

    /// Watches for `pid` to exit. Returns false when the process is already
    /// gone, so no event will follow.
    public func watchExit(ofProcess pid: Int32) -> Bool {
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// Blocks until a watched event happens or `timeout` passes (nil).
    public func wait(timeout: Duration) -> Event? {
        let (seconds, attoseconds) = max(timeout, .zero).components
        var limit = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
        var event = kevent()
        var count: Int32
        repeat {
            count = kevent(queue, nil, 0, &event, 1, &limit)
        } while count < 0 && errno == EINTR
        guard count > 0 else { return nil }
        return .processExited
    }
}

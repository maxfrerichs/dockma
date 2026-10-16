import Foundation

/// Blocking waits for kernel events through a kqueue: a process exiting or a
/// directory gaining or losing entries.
public final class KernelEvents {
    /// What woke a `wait(timeout:)`.
    public enum Event: Equatable, Sendable {
        case processExited
        case directoryChanged
    }

    private let queue: Int32
    private var directoryFDs: [Int32] = []

    /// Creates an empty kqueue.
    public init() throws {
        queue = kqueue()
        guard queue >= 0 else { throw DockmaError.posix("kqueue") }
    }

    deinit {
        directoryFDs.forEach { close($0) }
        close(queue)
    }

    /// Watches for `pid` to exit. Returns false when the process is already
    /// gone, so no event will follow.
    public func watchExit(ofProcess pid: Int32) -> Bool {
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// Watches the directory at `url` for entries being added or removed.
    public func watchWrites(toDirectory url: URL) throws {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw DockmaError.posix("open \(url.path)") }
        directoryFDs.append(fd)
        var change = kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_WRITE), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            throw DockmaError.posix("watch \(url.path)")
        }
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
        return event.filter == Int16(EVFILT_PROC) ? .processExited : .directoryChanged
    }
}

import Foundation

/// Exclusive `flock` locks that a process holds until it closes the descriptor.
enum FileLock {
    /// Opens and locks `url` without waiting, returning the descriptor. It
    /// is close-on-exec, so a child that outlives the process doesn't keep
    /// holding the lock. A held lock throws `busyMessage`.
    static func acquire(at url: URL, busyMessage: String) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DockmaError.posix("open \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno == EWOULDBLOCK
                ? DockmaError("\(busyMessage) (\(url.path) is locked)")
                : DockmaError.posix("lock \(url.path)")
            close(fd)
            throw error
        }
        return fd
    }
}

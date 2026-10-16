import Foundation

/// Copies bytes both ways between two connected socket descriptors on two
/// threads, forwarding EOF as a half-close (`shutdown(SHUT_WR)`), which
/// docker's hijacked attach/exec streams rely on. Takes ownership of both fds.
public enum SocketCopier {
    public static func pipe(_ a: Int32, _ b: Int32, onClose: (@Sendable () -> Void)? = nil) {
        let state = PipeState(a: a, b: b, onClose: onClose)
        Thread.detachNewThread { copy(from: a, to: b, state: state) }
        Thread.detachNewThread { copy(from: b, to: a, state: state) }
    }

    private static func copy(from src: Int32, to dst: Int32, state: PipeState) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var failed = false
        loop: while true {
            let n = buffer.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { write(dst, $0.baseAddress! + offset, n - offset) }
                if w < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break loop
                }
                offset += w
            }
        }
        if failed {
            // Unblock the other direction too.
            shutdown(src, SHUT_RDWR)
            shutdown(dst, SHUT_RDWR)
        } else {
            shutdown(dst, SHUT_WR)
        }
        state.finishOne()
    }
}

private final class PipeState: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private let a: Int32
    private let b: Int32
    private let onClose: (@Sendable () -> Void)?

    init(a: Int32, b: Int32, onClose: (@Sendable () -> Void)?) {
        self.a = a
        self.b = b
        self.onClose = onClose
    }

    func finishOne() {
        let done = lock.withLock {
            remaining -= 1
            return remaining == 0
        }
        if done {
            close(a)
            close(b)
            onClose?()
        }
    }
}

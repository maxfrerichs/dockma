import Foundation

/// `setsockopt` calls shared by the socket code; failures are ignored, as a
/// socket without the option still works.
enum SocketOptions {
    /// Makes a write to `fd` after the peer closed fail with EPIPE instead of
    /// raising SIGPIPE.
    static func disableSIGPIPE(on fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Makes blocking reads and writes on `fd` (or only those `options`
    /// names: `SO_RCVTIMEO`, `SO_SNDTIMEO`) fail after `seconds`.
    static func setTimeout(seconds: Int, on fd: Int32, for options: [Int32] = [SO_RCVTIMEO, SO_SNDTIMEO]) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        for option in options {
            setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}

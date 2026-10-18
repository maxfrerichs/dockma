import Foundation
@testable import DockmaCore

/// Polls `condition` for up to `timeout`, for teardown that finishes on
/// another queue or thread.
func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Whether a TCP connection to `127.0.0.1:port` is accepted; false once
/// nothing listens there.
func acceptsTCPConnection(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = loopbackSocketAddress(port: port)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// Whether UDP `127.0.0.1:port` can be bound, that is, no socket holds it.
func isFreeUDPPort(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var addr = loopbackSocketAddress(port: port)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// A port that TCP and UDP on 127.0.0.1 and ::1 could all bind a moment ago.
///
/// Picked outside macOS's ephemeral range (49152–65535): binding port 0 hands
/// out a port from that range, and so does every connection or datagram that
/// tests running in parallel send, so such a port can be taken before the
/// test binds it.
func makeFreePort() throws -> UInt16 {
    for _ in 0..<100 {
        let port = UInt16.random(in: 20000..<32000)
        if [SOCK_STREAM, SOCK_DGRAM].allSatisfy({ canBind(type: $0, port: port) }) { return port }
    }
    throw DockmaError("cannot find a free port")
}

/// Whether a socket of `type` can bind `port` on both 127.0.0.1 and ::1.
private func canBind(type: Int32, port: UInt16) -> Bool {
    let v4 = socket(AF_INET, type, 0), v6 = socket(AF_INET6, type, 0)
    defer { close(v4); close(v6) }
    var on: Int32 = 1
    setsockopt(v6, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr4 = loopbackSocketAddress(port: port)
    var addr6 = sockaddr_in6()
    addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    addr6.sin6_family = sa_family_t(AF_INET6)
    addr6.sin6_port = port.bigEndian
    addr6.sin6_addr = in6addr_loopback
    let bound4 = withUnsafePointer(to: &addr4) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    let bound6 = withUnsafePointer(to: &addr6) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(v6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
    }
    return bound4 == 0 && bound6 == 0
}

/// Runs `body` again while it fails on a lock that is still held, for up to
/// 2 s, and returns its result; any other error is thrown at once.
///
/// A lock can outlive the `close()` that should release it: a process that
/// another test spawns at that moment briefly shares every open file of this
/// process, close-on-exec or not, until it execs. Measured on macOS 27 with
/// `O_CLOEXEC`: 129 of 100,000 close-then-relock cycles failed while one
/// thread spawned processes, 853 with four, none with none.
func retryingWhileLockIsHeld<Value>(_ body: () throws -> Value) throws -> Value {
    let deadline = ContinuousClock.now + .seconds(2)
    while true {
        do {
            return try body()
        } catch let error as DockmaError where error.description.hasSuffix(" is locked)") && ContinuousClock.now < deadline {
            usleep(10_000)
        }
    }
}

/// `127.0.0.1:port`.
private func loopbackSocketAddress(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// An object whose only job is to be captured by a closure, so a `weak`
/// reference to it shows whether that closure was released.
final class Sentinel: Sendable {}

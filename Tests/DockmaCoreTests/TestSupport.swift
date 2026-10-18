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

/// A random port for a test to bind, away from macOS's ephemeral range
/// (49152–65535) that client sockets draw from.
func randomTestPort() -> UInt16 {
    UInt16.random(in: 20000..<32000)
}

/// Calls `make` with random ports until it doesn't fail on a port in use,
/// and returns what it made with its port; any other error is thrown at once.
///
/// There is no check that a port is free first: a probe socket closed just
/// before the real bind can still hold the port (see
/// `retryingWhileLockIsHeld(_:)`), so the real bind is the only check.
func bindRandomPort<Value>(_ make: (UInt16) throws -> Value) throws -> (Value, UInt16) {
    var attempt = 0
    while true {
        attempt += 1
        let port = randomTestPort()
        do {
            return (try make(port), port)
        } catch let error as DockmaError where error.description.hasSuffix(": Address already in use") && attempt < 50 {
            continue
        }
    }
}

/// Runs `body` again while it fails on a lock that is still held, for up to
/// 2 s, and returns its result; any other error is thrown at once.
///
/// A descriptor can outlive the `close()` that should release it: a process
/// that another test spawns at that moment briefly shares every open file of
/// this process, close-on-exec or not, until it execs. That keeps a lock held,
/// or a closed socket's port bound, for a moment. Measured on macOS 27 with
/// `O_CLOEXEC`: 129 of 100,000 close-then-relock cycles failed while one
/// thread spawned processes, 853 with four, none with none; binding a port
/// right after closing a socket on it failed 149 and 678 times in 50,000.
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

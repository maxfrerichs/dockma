import Foundation
import Testing
@testable import DockmaCore

/// Reads until EOF; returns nil on timeout.
private func readToEOF(_ fd: Int32) -> Data? {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n == 0 { return out }
        if n < 0 { return nil }
        out.append(contentsOf: buffer[0..<n])
    }
}

/// client ⇄ [a | copier | b] ⇄ server: a half-close by the client must reach
/// the server while the server can still answer, like `docker run -i`.
@Test func forwardsDataAndHalfClose() throws {
    var left: [Int32] = [0, 0]
    var right: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &left) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &right) == 0)
    let client = left[0], server = right[0]
    let closed = Mutex(false)
    SocketCopier.pipe(left[1], right[1]) { closed.set(true) }

    writeAll(Data("request".utf8), to: client)
    shutdown(client, SHUT_WR)
    #expect(readToEOF(server) == Data("request".utf8))

    writeAll(Data("response".utf8), to: server)
    shutdown(server, SHUT_WR)
    #expect(readToEOF(client) == Data("response".utf8))

    close(client)
    close(server)
    for _ in 0..<50 where !closed.get() { usleep(20_000) }
    #expect(closed.get())
}

/// A connected socket pair whose ends report EPIPE instead of raising
/// SIGPIPE.
private func makeSocketPair() -> (Int32, Int32) {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    var on: Int32 = 1
    for fd in pair { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
    return (pair[0], pair[1])
}

/// A connected TCP pair on 127.0.0.1, as `(client, server)`.
private func makeTCPPair() throws -> (Int32, Int32) {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(listener) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    let rc = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            guard bind(listener, $0, length) == 0, getsockname(listener, $0, &length) == 0,
                  listen(listener, 1) == 0 else { return Int32(-1) }
            return connect(client, $0, length)
        }
    }
    let server = accept(listener, nil, nil)
    guard rc == 0, server >= 0 else {
        close(client)
        throw DockmaError.posix("TCP pair")
    }
    return (client, server)
}

/// A failed read, here a reset by the server, ends both directions, including
/// the one blocked reading from a client that never closes, so neither thread
/// nor descriptor outlives the pipe.
@Test func failedReadEndsBothDirectionsAndReportsOnce() async throws {
    let (client, clientSide) = makeSocketPair()
    let (serverSide, server) = try makeTCPPair()
    defer { close(client) }
    let closes = Mutex(0)
    SocketCopier.pipe(clientSide, serverSide) { closes.set(closes.get() + 1) }

    var reset = linger(l_onoff: 1, l_linger: 0)
    setsockopt(server, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
    close(server)
    #expect(try await eventually { closes.get() == 1 })
    #expect(await runOnThread { readToEOF(client) } == Data())
    try await Task.sleep(for: .milliseconds(100))
    #expect(closes.get() == 1)
}

private final class Mutex<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

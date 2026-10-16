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

private final class Mutex<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

import Foundation
import Testing
@testable import DockmaCore

/// `127.0.0.1:port`.
private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// The first non-loopback IPv4 address of an interface that is up, if any.
func nonLoopbackIPv4Address() -> in_addr? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var entry = list
    while let current = entry?.pointee {
        defer { entry = current.ifa_next }
        guard let address = current.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              current.ifa_flags & UInt32(IFF_UP) != 0, current.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
    return nil
}

/// Connects to `127.0.0.1:port`, from `source` when given, and reads until
/// EOF; nil on a reset or timeout.
private func exchange(port: UInt16, from source: in_addr? = nil) -> Data? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    if let source {
        var local = loopbackAddress(port: 0)
        local.sin_addr = source
        let rc = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return nil }
    }
    var remote = loopbackAddress(port: port)
    let rc = withUnsafePointer(to: &remote) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { return nil }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n == 0 { return out }
        if n < 0 { return nil }
        out.append(contentsOf: buffer[0..<n])
    }
}

/// A loopback-only listener serves a loopback client and closes a client
/// whose source is a non-loopback address. Both connect to 127.0.0.1, so the
/// test never listens on the network and needs no firewall exception.
@Test func loopbackOnlyListenerClosesNonLoopbackPeers() throws {
    let port = try makeFreePort()
    let accepted = Counter()
    let listener = try SocketListener.tcp(address: IPAddress("127.0.0.1")!, port: port, acceptsOnlyLoopback: true) { client in
        accepted.increment()
        writeAll(Data("ok".utf8), to: client)
        close(client)
    }
    defer { listener.cancel() }
    #expect(listener.description == "127.0.0.1:\(port) (loopback only)")

    #expect(exchange(port: port) == Data("ok".utf8))
    #expect(accepted.value == 1)

    guard let lan = nonLoopbackIPv4Address() else { return }  // no network interface up
    let reply = exchange(port: port, from: lan)
    #expect(reply == nil || reply == Data())
    #expect(accepted.value == 1)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A listener dropped without `cancel()` closes its socket in `deinit`, and
/// dispatch releases the handler with whatever it captured.
@Test func droppedTCPListenerClosesItsPortAndReleasesItsHandler() async throws {
    let port = try makeFreePort()
    var sentinel: Sentinel? = Sentinel()
    weak let weakSentinel = sentinel
    var listener: SocketListener? = try SocketListener.tcp(address: IPAddress("127.0.0.1")!, port: port) {
        [sentinel] client in
        _ = sentinel
        close(client)
    }
    weak let weakListener = listener
    sentinel = nil
    #expect(acceptsTCPConnection(port: port))
    #expect(weakSentinel != nil)

    listener = nil
    #expect(weakListener == nil)
    #expect(try await eventually { !acceptsTCPConnection(port: port) && weakSentinel == nil })
}

/// A dropped unix listener removes its socket file.
@Test func droppedUnixListenerRemovesItsSocket() throws {
    let path = NSTemporaryDirectory() + "dockma-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    var listener: SocketListener? = try SocketListener.unix(path: path) { close($0) }
    #expect(FileManager.default.fileExists(atPath: path))
    _ = listener
    listener = nil
    #expect(!FileManager.default.fileExists(atPath: path))
}

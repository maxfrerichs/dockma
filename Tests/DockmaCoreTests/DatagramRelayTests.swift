import Foundation
import Testing
@testable import DockmaCore

/// The agent's TestDatagramFrameGolden (vm/agent/internal/relay/udp_test.go) asserts the
/// same bytes.
@Test func datagramFramesMatchTheAgent() throws {
    let bytes = DatagramFrame.encode(Data("hi!".utf8)) + DatagramFrame.encode(Data())
    #expect([UInt8](bytes) == [0x00, 0x03, 0x68, 0x69, 0x21, 0x00, 0x00])

    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { close(pair[0]) }
    #expect(writeAll(bytes, to: pair[1]))
    close(pair[1])
    var buffer = [UInt8](repeating: 0, count: DatagramFrame.maxPayload)
    let first = DatagramFrame.readPayload(from: pair[0], into: &buffer)
    #expect(first == 3 && String(decoding: buffer[0..<3], as: UTF8.self) == "hi!")
    #expect(DatagramFrame.readPayload(from: pair[0], into: &buffer) == 0)
    #expect(DatagramFrame.readPayload(from: pair[0], into: &buffer) == nil)
}

/// Stands in for dockma-agent: each connection reads the tunnel header and
/// answers every frame with "echo:" + payload until the host closes it.
private final class FakeAgent: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []
    private var closedCount = 0
    let connectDelay: Duration

    init(connectDelay: Duration = .zero) {
        self.connectDelay = connectDelay
    }

    var receivedHeaders: [String] { lock.withLock { headers } }
    var closedConnections: Int { lock.withLock { closedCount } }

    /// Opens a tunnel connection, as `VMHost.connect(port:)` does.
    func connect() async throws -> Int32 {
        try await Task.sleep(for: connectDelay)
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw DockmaError.posix("socketpair") }
        let agent = pair[1]
        Thread.detachNewThread { [self] in serve(agent) }
        return pair[0]
    }

    private func serve(_ fd: Int32) {
        defer {
            close(fd)
            lock.withLock { closedCount += 1 }
        }
        // Byte by byte: the relay sends the first frames in the same write
        // as the header.
        var header = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { header.append(byte) }
        lock.withLock { headers.append(String(decoding: header, as: UTF8.self)) }
        var buffer = [UInt8](repeating: 0, count: DatagramFrame.maxPayload)
        while let n = DatagramFrame.readPayload(from: fd, into: &buffer) {
            guard writeAll(DatagramFrame.encode(Data("echo:".utf8) + Data(buffer[0..<n])), to: fd) else { return }
        }
    }
}

/// `127.0.0.1:port`.
private func loopback(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// A UDP client socket with a 2 s receive timeout.
private func makeClient() -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// A UDP client socket bound to `source`, with a 1 s receive timeout.
private func makeClient(boundTo source: in_addr) -> Int32? {
    let fd = makeClient()
    var local = loopback(port: 0)
    local.sin_addr = source
    let rc = withUnsafePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else {
        close(fd)
        return nil
    }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// Sends `text` from `client` to `127.0.0.1:port`.
private func send(_ text: String, from client: Int32, to port: UInt16) {
    var addr = loopback(port: port)
    let bytes = Array(text.utf8)
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(client, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

/// The next datagram `client` receives; nil after the timeout.
private func receive(on client: Int32) async -> String? {
    await runOnThread {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(client, &buffer, buffer.count, 0)
        return n < 0 ? nil : String(decoding: buffer[0..<n], as: UTF8.self)
    }
}

/// Counts calls from any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Serialized so the relays' sockets and timers don't compete; `receive(on:)`
/// blocks on its own thread because the relay's connect tasks need the
/// cooperative pool.
@Suite(.serialized) struct DatagramRelayTests {
    @Test func relayTunnelsEachClientAndKeepsDatagramsSentWhileConnecting() async throws {
        let agent = FakeAgent(connectDelay: .milliseconds(150))
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "127.0.0.1:53") {
                try await agent.connect()
            }
        }
        defer { relay.cancel() }
        let first = makeClient(), second = makeClient()
        defer { close(first); close(second) }

        // Both arrive before the tunnel is up.
        send("a", from: first, to: port)
        send("b", from: first, to: port)
        #expect(await receive(on: first) == "echo:a")
        #expect(await receive(on: first) == "echo:b")

        send("c", from: second, to: port)
        #expect(await receive(on: second) == "echo:c")
        #expect(relay.flowCount == 2)
        #expect(agent.receivedHeaders == ["udp 127.0.0.1:53", "udp 127.0.0.1:53"])
    }

    @Test func relayEndsIdleFlows() async throws {
        let agent = FakeAgent()
        var limits = DatagramRelay.Limits.standard
        limits.idleTimeout = .milliseconds(200)
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1", limits: limits) {
                try await agent.connect()
            }
        }
        defer { relay.cancel() }
        let client = makeClient()
        defer { close(client) }

        send("x", from: client, to: port)
        #expect(await receive(on: client) == "echo:x")
        #expect(try await eventually { relay.flowCount == 0 && agent.closedConnections == 1 })

        // A later datagram starts a new flow.
        send("y", from: client, to: port)
        #expect(await receive(on: client) == "echo:y")
    }

    @Test func newClientAtTheLimitEndsTheLeastRecentlyActiveFlow() async throws {
        let agent = FakeAgent()
        var limits = DatagramRelay.Limits.standard
        limits.maxFlows = 2
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1", limits: limits) {
                try await agent.connect()
            }
        }
        defer { relay.cancel() }
        let first = makeClient(), second = makeClient(), third = makeClient()
        defer { close(first); close(second); close(third) }

        send("a", from: first, to: port)
        #expect(await receive(on: first) == "echo:a")
        send("b", from: second, to: port)
        #expect(await receive(on: second) == "echo:b")
        send("a2", from: first, to: port)  // now `second` is the least recently active
        #expect(await receive(on: first) == "echo:a2")

        send("c", from: third, to: port)
        #expect(await receive(on: third) == "echo:c")
        #expect(relay.flowCount == 2)
        #expect(try await eventually { agent.closedConnections == 1 })

        // `first` kept its flow: no new tunnel header.
        send("a3", from: first, to: port)
        #expect(await receive(on: first) == "echo:a3")
        #expect(agent.receivedHeaders.count == 3)
    }

    @Test func cancelledRelayClosesItsTunnels() async throws {
        let agent = FakeAgent()
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1") {
                try await agent.connect()
            }
        }
        let client = makeClient()
        defer { close(client) }
        send("a", from: client, to: port)
        #expect(await receive(on: client) == "echo:a")

        relay.cancel()
        #expect(try await eventually { agent.closedConnections == 1 })
        // The port is free again, once the socket's close has taken effect.
        #expect(try await eventually {
            guard let rebound = try? DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1", connect: {
                try await agent.connect()
            }) else { return false }
            rebound.cancel()
            return true
        })
    }

    @Test func connectFailureEndsTheFlow() async throws {
        let attempts = Counter()
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1") {
                attempts.increment()
                throw DockmaError("no VM")
            }
        }
        defer { relay.cancel() }
        let client = makeClient()
        defer { close(client) }
        send("a", from: client, to: port)
        #expect(try await eventually { attempts.value == 1 && relay.flowCount == 0 })
        // The next datagram tries again.
        send("b", from: client, to: port)
        #expect(try await eventually { attempts.value == 2 && relay.flowCount == 0 })
        #expect(relay.queuedByteCount == 0)
    }

    @Test func relayDropsDatagramsBeyondTheByteBudget() async throws {
        let agent = FakeAgent(connectDelay: .milliseconds(300))
        var limits = DatagramRelay.Limits.standard
        limits.maxQueuedBytes = 100  // two 40-byte datagrams plus their 2-byte headers
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1", limits: limits) {
                try await agent.connect()
            }
        }
        defer { relay.cancel() }
        let client = makeClient()
        defer { close(client) }

        let payloads = (0..<3).map { String(repeating: Character(String($0)), count: 40) }
        payloads.forEach { send($0, from: client, to: port) }
        #expect(await receive(on: client) == "echo:" + payloads[0])
        #expect(await receive(on: client) == "echo:" + payloads[1])
        #expect(try await eventually { relay.queuedByteCount == 0 })

        // The third was dropped, and written frames free the budget: the next
        // reply is for a later datagram.
        send("late", from: client, to: port)
        #expect(await receive(on: client) == "echo:late")
    }

    @Test func loopbackOnlyRelayDropsDatagramsFromOtherAddresses() async throws {
        let attempts = Counter()
        let agent = FakeAgent()
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1",
                                          acceptsOnlyLoopback: true) {
                attempts.increment()
                return try await agent.connect()
            }
        }
        defer { relay.cancel() }
        #expect(relay.description == "127.0.0.1:\(port)/udp (loopback only)")

        let client = makeClient()
        defer { close(client) }
        send("a", from: client, to: port)
        #expect(await receive(on: client) == "echo:a")
        #expect(attempts.value == 1)

        guard let lan = nonLoopbackIPv4Address(), let remote = makeClient(boundTo: lan) else { return }  // no network interface up
        defer { close(remote) }
        send("b", from: remote, to: port)
        #expect(await receive(on: remote) == nil)
        #expect(attempts.value == 1)
        #expect(relay.flowCount == 1)
    }

    /// Reply threads and connect tasks hold the relay while its flows run, so
    /// it is freed only once `cancel()` has ended them.
    @Test func cancelledRelayIsReleasedWithItsFlows() async throws {
        let agent = FakeAgent()
        var relay: DatagramRelay?
        let port: UInt16
        (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1") {
                try await agent.connect()
            }
        }
        weak let weakRelay = relay
        let first = makeClient(), second = makeClient()
        defer { close(first); close(second) }
        send("a", from: first, to: port)
        #expect(await receive(on: first) == "echo:a")
        send("b", from: second, to: port)
        #expect(await receive(on: second) == "echo:b")
        #expect(relay?.flowCount == 2)
        #expect(!isFreeUDPPort(port))

        relay?.cancel()
        relay = nil
        #expect(try await eventually { weakRelay == nil })
        #expect(try await eventually { agent.closedConnections == 2 && isFreeUDPPort(port) })
    }

    /// Without `cancel()`, a dropped relay's live flows keep it, and its port,
    /// until they idle out; then `deinit` closes the socket.
    @Test func droppedRelayIsReleasedOnceItsFlowsIdleOut() async throws {
        let agent = FakeAgent()
        var limits = DatagramRelay.Limits.standard
        limits.idleTimeout = .milliseconds(1500)
        var relay: DatagramRelay?
        let port: UInt16
        (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1",
                                                          limits: limits) {
                try await agent.connect()
            }
        }
        weak let weakRelay = relay
        let client = makeClient()
        defer { close(client) }
        send("a", from: client, to: port)
        #expect(await receive(on: client) == "echo:a")

        relay = nil
        #expect(weakRelay != nil)  // the flow's reply thread holds it
        #expect(try await eventually(within: .seconds(5)) { weakRelay == nil })
        #expect(try await eventually(within: .seconds(5)) { agent.closedConnections == 1 && isFreeUDPPort(port) })
    }

    /// Ended flows give back their share of the byte budget, or a relay that
    /// has seen enough traffic would drop everything.
    @Test func endedFlowsReturnTheirQueuedBytes() async throws {
        let agent = FakeAgent(connectDelay: .seconds(1))
        var limits = DatagramRelay.Limits.standard
        limits.maxFlows = 2
        let (relay, port) = try bindRandomPort { port in
            try DatagramRelay(address: IPAddress("127.0.0.1")!, port: port, target: "t:1", limits: limits) {
                try await agent.connect()
            }
        }
        defer { relay.cancel() }
        let clients = (0..<3).map { _ in makeClient() }
        defer { clients.forEach { close($0) } }

        // The third client evicts the first while all are still connecting.
        for client in clients { send("x", from: client, to: port) }
        #expect(try await eventually { relay.flowCount == 2 && relay.queuedByteCount > 0 })
        #expect(await receive(on: clients[2]) == "echo:x")
        #expect(try await eventually { relay.queuedByteCount == 0 })
    }
}

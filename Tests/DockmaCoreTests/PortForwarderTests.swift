import Foundation
import Testing
@testable import DockmaCore

/// The key of TCP port `port`.
private func tcp(_ port: UInt16) -> ForwardedPort.Key { ForwardedPort.Key(port: port, transport: .tcp) }

/// The key of UDP port `port`.
private func udp(_ port: UInt16) -> ForwardedPort.Key { ForwardedPort.Key(port: port, transport: .udp) }

@Test func planOpensNewAndClosesRemovedPorts() {
    let plan = PortForwarder.plan(
        current: [tcp(80): "127.0.0.1:80", tcp(443): "127.0.0.1:443"],
        desired: [ForwardedPort(port: 443, target: "127.0.0.1:443"), ForwardedPort(port: 5432, target: "127.0.0.1:5432")])
    #expect(plan.toClose == [tcp(80)])
    #expect(plan.toOpen == [ForwardedPort(port: 5432, target: "127.0.0.1:5432")])
}

@Test func planReopensPortWhoseTargetChanged() {
    let plan = PortForwarder.plan(current: [tcp(80): "127.0.0.1:80"], desired: [ForwardedPort(port: 80, target: "[::1]:80")])
    #expect(plan.toClose == [tcp(80)])
    #expect(plan.toOpen == [ForwardedPort(port: 80, target: "[::1]:80")])
}

@Test func planIsEmptyWhenNothingChanged() {
    let plan = PortForwarder.plan(current: [tcp(80): "127.0.0.1:80"], desired: [ForwardedPort(port: 80, target: "127.0.0.1:80")])
    #expect(plan == PortForwarder.Plan(toOpen: [], toClose: []))
}

@Test func planClosesEverythingForEmptySet() {
    let plan = PortForwarder.plan(current: [tcp(80): "a:80", tcp(81): "a:81"], desired: [])
    #expect(plan.toClose == [tcp(80), tcp(81)])
    #expect(plan.toOpen.isEmpty)
}

@Test func planTreatsTCPAndUDPOnOnePortAsSeparateForwards() {
    let both = [
        ForwardedPort(port: 53, transport: .udp, target: "127.0.0.1:53"),
        ForwardedPort(port: 53, transport: .tcp, target: "127.0.0.1:53"),
    ]
    let opened = PortForwarder.plan(current: [:], desired: both)
    #expect(opened.toOpen == [both[1], both[0]])
    #expect(opened.toClose.isEmpty)

    let udpRemoved = PortForwarder.plan(current: [tcp(53): "127.0.0.1:53", udp(53): "127.0.0.1:53"], desired: [both[1]])
    #expect(udpRemoved == PortForwarder.Plan(toOpen: [], toClose: [udp(53)]))
}

@Test func portKeysSortByPortThenTransportAndDescribeUDP() {
    #expect([udp(53), tcp(80), tcp(53)].sorted() == [tcp(53), udp(53), tcp(80)])
    #expect(tcp(8080).description == "8080")
    #expect(udp(5353).description == "5353/udp")
}

@Test func bindAddressesAddIPv6Counterpart() {
    #expect(PortForwarder.bindAddresses(for: "127.0.0.1") == [IPAddress("127.0.0.1")!, IPAddress("::1")!])
    #expect(PortForwarder.bindAddresses(for: "0.0.0.0") == [IPAddress("0.0.0.0")!, IPAddress("::")!])
    #expect(PortForwarder.bindAddresses(for: "192.168.1.5") == [IPAddress("192.168.1.5")!])
}

@Test func privilegedLoopbackPortsListenOnWildcardForLoopbackOnly() {
    #expect(PortForwarder.listenAddresses(for: "127.0.0.1", port: 80) == [
        .init(address: IPAddress("0.0.0.0")!, acceptsOnlyLoopback: true),
        .init(address: IPAddress("::")!, acceptsOnlyLoopback: true),
    ])
    #expect(PortForwarder.listenAddresses(for: "::1", port: 443) == [.init(address: IPAddress("::")!, acceptsOnlyLoopback: true)])
}

@Test func otherPortsListenOnTheBindAddresses() {
    #expect(PortForwarder.listenAddresses(for: "127.0.0.1", port: 1024) == [
        .init(address: IPAddress("127.0.0.1")!, acceptsOnlyLoopback: false),
        .init(address: IPAddress("::1")!, acceptsOnlyLoopback: false),
    ])
    #expect(PortForwarder.listenAddresses(for: "0.0.0.0", port: 80) == [
        .init(address: IPAddress("0.0.0.0")!, acceptsOnlyLoopback: false),
        .init(address: IPAddress("::")!, acceptsOnlyLoopback: false),
    ])
    #expect(PortForwarder.listenAddresses(for: "192.168.1.5", port: 80) == [
        .init(address: IPAddress("192.168.1.5")!, acceptsOnlyLoopback: false),
    ])
}

@Test(arguments: [
    ("127.0.0.1", true), ("127.5.5.5", true), ("::1", true), ("::ffff:127.0.0.1", true),
    ("192.168.1.5", false), ("0.0.0.0", false), ("::", false), ("::ffff:192.168.1.5", false), ("fe80::1", false),
])
func loopbackAddresses(address: String, isLoopback: Bool) {
    #expect(IPAddress(address)!.isLoopback == isLoopback)
}

@Test func socketAddressYieldsItsIPAddress() {
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { raw in
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        raw.storeBytes(of: addr, as: sockaddr_in.self)
    }
    #expect(IPAddress(socketAddress: storage) == IPAddress("127.0.0.1"))
    storage.ss_family = sa_family_t(AF_UNIX)
    #expect(IPAddress(socketAddress: storage) == nil)
}

@Test func ipAddressDescriptionIsTheStandardTextForm() {
    #expect(IPAddress("127.0.0.1")!.description == "127.0.0.1")
    #expect(IPAddress("::1")!.description == "::1")
    #expect(IPAddress("::ffff:127.0.0.1")!.description == "::ffff:127.0.0.1")
}

/// A listener on 127.0.0.1 at a free port, which holds that port.
@MainActor
private func holdLoopbackPort() throws -> (listener: SocketListener, port: UInt16) {
    for _ in 0..<50 {
        let port = randomTestPort()
        if let listener = try? SocketListener.tcp(address: IPAddress("127.0.0.1")!, port: port, handler: { close($0) }) {
            return (listener, port)
        }
    }
    throw DockmaError("no free port")
}

@MainActor
@Test func portHeldOnTheHostIsReportedAndForwardedOnceFree() throws {
    let held = try holdLoopbackPort()
    let forwarder = PortForwarder(bindAddress: "127.0.0.1") { throw DockmaError("no VM in this test") }
    defer { forwarder.removeAll() }
    forwarder.update([ForwardedPort(port: held.port, target: "127.0.0.1:80")])
    #expect(forwarder.hasFailures)
    let warning = try #require(forwarder.failureWarnings.first)
    #expect(warning.hasPrefix("port \(held.port) is "))

    // Still held: retrying changes nothing.
    forwarder.retryFailed()
    #expect(forwarder.hasFailures)

    // The listener closes its socket asynchronously after cancel().
    held.listener.cancel()
    for _ in 0..<100 where forwarder.hasFailures {
        Thread.sleep(forTimeInterval: 0.01)
        forwarder.retryFailed()
    }
    #expect(forwarder.hasFailures == false)
    #expect(forwarder.ports == [tcp(held.port)])
}

@MainActor
@Test func removedPortIsNoLongerReportedAsFailed() throws {
    let held = try holdLoopbackPort()
    defer { held.listener.cancel() }
    let forwarder = PortForwarder(bindAddress: "127.0.0.1") { throw DockmaError("no VM in this test") }
    forwarder.update([ForwardedPort(port: held.port, target: "127.0.0.1:80")])
    #expect(forwarder.hasFailures)
    forwarder.update([])
    #expect(forwarder.hasFailures == false)
    #expect(forwarder.ports.isEmpty)
}

/// A forwarder bound to a TCP and a UDP port that were free on 127.0.0.1 and
/// ::1, with tunnels that always fail.
@MainActor
private func makeBoundForwarder() throws -> (forwarder: PortForwarder, port: UInt16) {
    for _ in 0..<50 {
        let port = randomTestPort()
        let forwarder = PortForwarder(bindAddress: "127.0.0.1") { throw DockmaError("no VM in this test") }
        forwarder.update([
            ForwardedPort(port: port, transport: .tcp, target: "127.0.0.1:80"),
            ForwardedPort(port: port, transport: .udp, target: "127.0.0.1:53"),
        ])
        if !forwarder.hasFailures && forwarder.ports == [tcp(port), udp(port)] { return (forwarder, port) }
        forwarder.removeAll()
    }
    throw DockmaError("no free port")
}

@MainActor
@Test func removeAllFreesEveryPort() async throws {
    let (forwarder, port) = try makeBoundForwarder()
    #expect(acceptsTCPConnection(port: port))
    #expect(!isFreeUDPPort(port))

    forwarder.removeAll()
    #expect(forwarder.ports.isEmpty)
    #expect(try await eventually { !acceptsTCPConnection(port: port) && isFreeUDPPort(port) })
}

/// A forwarder dropped without `removeAll()` takes its listeners and relays
/// with it.
@MainActor
@Test func droppedForwarderFreesEveryPort() async throws {
    var bound: (forwarder: PortForwarder, port: UInt16)? = try makeBoundForwarder()
    let port = bound!.port
    weak let weakForwarder = bound?.forwarder
    #expect(acceptsTCPConnection(port: port))

    bound = nil
    #expect(weakForwarder == nil)
    #expect(try await eventually { !acceptsTCPConnection(port: port) && isFreeUDPPort(port) })
}

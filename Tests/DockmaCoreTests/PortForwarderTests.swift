import Testing
@testable import DockmaCore

@Test func planOpensNewAndClosesRemovedPorts() {
    let plan = PortForwarder.plan(
        current: [80: "127.0.0.1:80", 443: "127.0.0.1:443"],
        desired: [ForwardedPort(port: 443, target: "127.0.0.1:443"), ForwardedPort(port: 5432, target: "127.0.0.1:5432")])
    #expect(plan.close == [80])
    #expect(plan.open == [ForwardedPort(port: 5432, target: "127.0.0.1:5432")])
}

@Test func planReopensPortWhoseTargetChanged() {
    let plan = PortForwarder.plan(current: [80: "127.0.0.1:80"], desired: [ForwardedPort(port: 80, target: "[::1]:80")])
    #expect(plan.close == [80])
    #expect(plan.open == [ForwardedPort(port: 80, target: "[::1]:80")])
}

@Test func planIsEmptyWhenNothingChanged() {
    let plan = PortForwarder.plan(current: [80: "127.0.0.1:80"], desired: [ForwardedPort(port: 80, target: "127.0.0.1:80")])
    #expect(plan == PortForwarder.Plan(open: [], close: []))
}

@Test func planClosesEverythingForEmptySet() {
    let plan = PortForwarder.plan(current: [80: "a:80", 81: "a:81"], desired: [])
    #expect(plan.close == [80, 81])
    #expect(plan.open.isEmpty)
}

@Test func bindAddressesAddIPv6Counterpart() {
    #expect(PortForwarder.bindAddresses(for: "127.0.0.1") == [IPAddress("127.0.0.1")!, IPAddress("::1")!])
    #expect(PortForwarder.bindAddresses(for: "0.0.0.0") == [IPAddress("0.0.0.0")!, IPAddress("::")!])
    #expect(PortForwarder.bindAddresses(for: "192.168.1.5") == [IPAddress("192.168.1.5")!])
}

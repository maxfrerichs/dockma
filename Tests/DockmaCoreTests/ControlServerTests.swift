import Foundation
import Testing
@testable import DockmaCore

/// A short socket path; sun_path holds only 104 bytes.
private func makeSocketPath() -> String {
    "/tmp/dockma-test-\(UUID().uuidString.prefix(8)).sock"
}

/// A control handler that hands `wait` replies to `onWait`.
@MainActor
private final class TestHandler: ControlHandler {
    var onWait: @MainActor (@escaping @Sendable (DaemonStatus?) -> Void) -> Void = { _ in }
    var pending: [@Sendable (DaemonStatus?) -> Void] = []
    var stopCount = 0

    func status() -> DaemonStatus { testStatus }
    func stop() { stopCount += 1 }
    func waitUntilReady(reply: @escaping @Sendable (DaemonStatus?) -> Void) { onWait(reply) }
}

/// An anonymous control server, served on the main actor as the daemon
/// serves its Mach service.
@MainActor
private func makeServer(_ handler: TestHandler) -> ControlServer {
    ControlServer(listener: NSXPCListener.anonymous(), handler: handler)
}

/// Waits for Docker off the main actor, which serves the replies.
private func waitUntilReady(endpoint: NSXPCListenerEndpoint, timeout: Duration,
                            outcome: ExchangeOutcome<DaemonStatus?> = ExchangeOutcome()) async -> ControlClient.WaitOutcome {
    await runOnThread {
        ControlClient.waitUntilReady(over: NSXPCConnection(listenerEndpoint: endpoint), timeout: timeout, outcome: outcome)
    }
}

private let testStatus = DaemonStatus(
    state: .running, pid: 1, startedAt: Date(timeIntervalSince1970: 0), cpus: 2, memoryMiB: 1024,
    agentConnected: true, agentVersion: nil, guestKernel: nil, forwardedPorts: [80], forwardedUDPPorts: [53],
    warnings: ["w"], version: "1.0.0")

@MainActor
@Test func waitIsAnsweredWhenTheServerReplies() async throws {
    let handler = TestHandler()
    handler.onWait = { reply in
        // Reply later, as the daemon does once Docker is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reply(testStatus) }
    }
    let server = makeServer(handler)
    defer { server.invalidate() }
    guard case .ready(let reply) = await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not ready")
        return
    }
    #expect(reply == testStatus)
}

@MainActor
@Test func waitSeesTheDaemonStopping() async throws {
    let handler = TestHandler()
    handler.onWait = { $0(nil) }
    let server = makeServer(handler)
    defer { server.invalidate() }
    guard case .stopping = await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not stopping")
        return
    }
}

@MainActor
@Test func waitSeesTheServerGoAway() async throws {
    let handler = TestHandler()
    let server = makeServer(handler)
    // Invalidated before the client connects: like a daemon that exited.
    server.invalidate()
    guard case .closed = await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not closed")
        return
    }
}

@MainActor
@Test func waitTimesOut() async throws {
    let handler = TestHandler()
    handler.onWait = { handler.pending.append($0) }
    let server = makeServer(handler)
    defer {
        server.invalidate()
        handler.pending.forEach { $0(nil) }
    }
    guard case .timedOut = await waitUntilReady(endpoint: server.endpoint, timeout: .milliseconds(100)) else {
        Issue.record("did not time out")
        return
    }
}

/// The daemon's exit ends a wait the daemon never took.
@MainActor
@Test func waitEndsWhenTheDaemonExits() async throws {
    let handler = TestHandler()
    handler.onWait = { handler.pending.append($0) }
    let server = makeServer(handler)
    defer {
        server.invalidate()
        handler.pending.forEach { $0(nil) }
    }
    let outcome = ExchangeOutcome<DaemonStatus?>()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { outcome.set(.exited) }
    guard case .exited = await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5), outcome: outcome) else {
        Issue.record("did not see the exit")
        return
    }
}

@MainActor
@Test func statusAndStopAreAnswered() async throws {
    let handler = TestHandler()
    let server = makeServer(handler)
    defer { server.invalidate() }
    let endpoint = server.endpoint
    let status = await runOnThread {
        ControlClient.exchange(over: NSXPCConnection(listenerEndpoint: endpoint), timeout: .seconds(5)) { control, reply in
            control.status { reply($0.status) }
        }
    }
    guard case .reply(testStatus) = status else {
        Issue.record("status not answered: \(status)")
        return
    }
    let stop = await runOnThread {
        ControlClient.exchange(over: NSXPCConnection(listenerEndpoint: endpoint), timeout: .seconds(5)) { control, reply in
            control.stop { reply(()) }
        }
    }
    guard case .reply = stop else {
        Issue.record("stop not answered: \(stop)")
        return
    }
    // The stop itself runs once the reply has been sent.
    for _ in 0..<50 where handler.stopCount == 0 {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(handler.stopCount == 1)
}

/// Speaks `DaemonControl`'s selectors, but replies with a message that
/// claims to be a `DaemonStatusMessage` and lacks its required fields.
@objc(DockmaTestBrokenControl)
private protocol BrokenControl {
    func status(reply: @escaping @Sendable (BrokenStatusMessage) -> Void)
    func waitUntilReady(reply: @escaping @Sendable (BrokenStatusMessage?) -> Void)
}

@objc(DockmaTestBrokenStatus)
private final class BrokenStatusMessage: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    override init() {}
    required init?(coder: NSCoder) { nil }
    override var classForCoder: AnyClass { DaemonStatusMessage.self }
    func encode(with coder: NSCoder) {
        coder.encode("running" as NSString, forKey: "state")
    }
}

private final class BrokenServer: NSObject, NSXPCListenerDelegate, BrokenControl {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BrokenControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func status(reply: @escaping @Sendable (BrokenStatusMessage) -> Void) { reply(BrokenStatusMessage()) }
    func waitUntilReady(reply: @escaping @Sendable (BrokenStatusMessage?) -> Void) { reply(BrokenStatusMessage()) }
}

/// A reply that doesn't decode closes the call; a wait doesn't read it as nil
/// (stopping).
@Test func undecodableReplyCloses() async {
    let server = BrokenServer()
    let listener = NSXPCListener.anonymous()
    listener.delegate = server
    listener.resume()
    defer { listener.invalidate() }
    let endpoint = listener.endpoint
    guard case .closed = await waitUntilReady(endpoint: endpoint, timeout: .seconds(5)) else {
        Issue.record("wait not closed")
        return
    }
    let status = await runOnThread {
        ControlClient.exchange(over: NSXPCConnection(listenerEndpoint: endpoint), timeout: .seconds(5)) { control, reply in
            control.status { reply($0.status) }
        }
    }
    guard case .closed = status else {
        Issue.record("status not closed: \(status)")
        return
    }
    withExtendedLifetime(server) {}
}

/// Encodes chosen keys under `DaemonStatusMessage`'s wire class name.
@objc(DockmaTestRawStatus)
private final class RawStatus: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        // Scalars as the real encoder writes them, not as boxed objects.
        for (key, value) in fields {
            switch value {
            case let value as Bool: coder.encode(value, forKey: key)
            case let value as Int32: coder.encode(value, forKey: key)
            case let value as Int64: coder.encode(value, forKey: key)
            case let value as Int: coder.encode(value, forKey: key)
            default: coder.encode(value, forKey: key)
            }
        }
    }
}

/// Decodes `fields` as a `DaemonStatusMessage` would arrive from a peer;
/// nil when it doesn't decode.
private func decodeStatus(_ fields: [String: Any]) -> DaemonStatus? {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.setClassName("DockmaDaemonStatus", for: RawStatus.self)
    archiver.encode(RawStatus(fields), forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: DaemonStatusMessage.self, from: archiver.encodedData)?.status
}

private var requiredFields: [String: Any] {[
    "state": "running", "pid": Int32(7), "startedAt": Date(timeIntervalSince1970: 0), "cpus": 2,
    "memoryMiB": Int64(1024), "agentConnected": true, "forwardedPorts": [NSNumber(value: 80)], "warnings": [String](),
]}

@Test func statusMessageRoundTrips() throws {
    let data = try NSKeyedArchiver.archivedData(withRootObject: DaemonStatusMessage(testStatus), requiringSecureCoding: true)
    #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: DaemonStatusMessage.self, from: data)?.status == testStatus)
}

/// Optional fields may be missing, and an unknown state isn't an error.
@Test func statusMessageDecodesLeniently() throws {
    var fields = requiredFields
    fields["state"] = "hibernating"
    let status = try #require(decodeStatus(fields))
    #expect(status.state == .unknown)
    #expect(status.pid == 7)
    #expect(status.forwardedPorts == [80])
    #expect(status.forwardedUDPPorts == nil)
    #expect(status.version == nil)
}

@Test func statusMessageNeedsTheRequiredFields() {
    #expect(decodeStatus(requiredFields) != nil)
    for key in requiredFields.keys {
        var fields = requiredFields
        fields[key] = nil
        #expect(decodeStatus(fields) == nil, "decoded without \(key)")
    }
}

@Test func peerRequirementAddsTheTeamWhenSigned() {
    #expect(CodeSigning.requirement(forPeer: "io.dockma.cli", team: nil) == #"identifier "io.dockma.cli""#)
    #expect(CodeSigning.requirement(forPeer: "io.dockma.cli", team: "ABCDE12345")
        == #"identifier "io.dockma.cli" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
}

/// Serves one HTTP `response` per connection on a unix socket at `path`.
private func fakeDocker(path: String, response: String) throws -> SocketListener {
    try SocketListener.unix(path: path) { client in
        var request = [UInt8](repeating: 0, count: 4096)
        _ = read(client, &request, request.count)
        writeAll(Data(response.utf8), to: client)
        close(client)
    }
}

@Test func dockerPingWantsA200WithOK() async throws {
    let healthy = makeSocketPath()
    let healthyListener = try fakeDocker(path: healthy, response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
    defer { healthyListener.cancel() }
    let failing = makeSocketPath()
    let failingListener = try fakeDocker(path: failing, response: "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
    defer { failingListener.cancel() }

    #expect(await runOnThread { DockerPing.isResponding(socketPath: healthy) })
    #expect(await runOnThread { !DockerPing.isResponding(socketPath: failing) })
    #expect(await runOnThread { !DockerPing.isResponding(socketPath: makeSocketPath()) })
}

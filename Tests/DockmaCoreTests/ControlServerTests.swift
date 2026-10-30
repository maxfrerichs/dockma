import Foundation
import Testing
// XPC objects are thread-safe, but the module predates Sendable.
@preconcurrency import XPC
@testable import DockmaCore

/// A short socket path; sun_path holds only 104 bytes.
private func makeSocketPath() -> String {
    "/tmp/dockma-test-\(UUID().uuidString.prefix(8)).sock"
}

/// An anonymous control server on the main queue, as the daemon serves its
/// Mach service, and an endpoint that clients connect through.
@MainActor
private func makeServer(respond: @escaping @MainActor (ControlRequest, ControlReply) -> Void) -> (listener: xpc_connection_t, endpoint: xpc_endpoint_t) {
    let listener = xpc_connection_create(nil, .main)
    ControlServer.serve(listener, respond: respond)
    return (listener, xpc_endpoint_create(listener))
}

/// Waits for Docker off the main actor, which serves the replies.
private func waitUntilReady(endpoint: xpc_endpoint_t, timeout: Duration) async throws -> ControlClient.WaitOutcome {
    try await runOnThread {
        try ControlClient.waitUntilReady(over: xpc_connection_create_from_endpoint(endpoint), timeout: timeout)
    }
}

private let status = DaemonStatus(
    state: .running, pid: 1, startedAt: Date(timeIntervalSince1970: 0), cpus: 2, memoryMiB: 1024,
    agentConnected: true, agentVersion: nil, guestKernel: nil, forwardedPorts: [], warnings: [])

@MainActor
@Test func waitIsAnsweredWhenTheServerReplies() async throws {
    var pending: [ControlReply] = []
    let server = makeServer { request, reply in
        #expect(request.command == .wait)
        pending.append(reply)
        // Reply later, as the daemon does once Docker is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                pending.forEach { $0.send(try! JSONEncoder().encode(status)) }
            }
        }
    }
    defer { xpc_connection_cancel(server.listener) }
    guard case .ready(let reply) = try await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not ready")
        return
    }
    #expect(reply == status)
}

@MainActor
@Test func waitSeesAClosedReply() async throws {
    let server = makeServer { _, reply in reply.close() }
    defer { xpc_connection_cancel(server.listener) }
    guard case .closed = try await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not closed")
        return
    }
}

@MainActor
@Test func waitSeesTheServerGoAway() async throws {
    let server = makeServer { _, _ in }
    // Cancelled before the client connects: like a daemon that exited.
    xpc_connection_cancel(server.listener)
    guard case .closed = try await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5)) else {
        Issue.record("not closed")
        return
    }
}

@MainActor
@Test func waitTimesOut() async throws {
    var pending: [ControlReply] = []
    let server = makeServer { _, reply in pending.append(reply) }
    defer {
        xpc_connection_cancel(server.listener)
        pending.forEach { $0.close() }
    }
    guard case .timedOut = try await waitUntilReady(endpoint: server.endpoint, timeout: .milliseconds(100)) else {
        Issue.record("did not time out")
        return
    }
}

/// The daemon's exit ends a wait the daemon never took.
@MainActor
@Test func waitEndsWhenTheDaemonExits() async throws {
    var pending: [ControlReply] = []
    let server = makeServer { _, reply in pending.append(reply) }
    defer {
        xpc_connection_cancel(server.listener)
        pending.forEach { $0.close() }
    }
    let outcome = ExchangeOutcome()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { outcome.set(.exited) }
    let result = try await runOnThread {
        try ControlClient.waitUntilReady(over: xpc_connection_create_from_endpoint(server.endpoint),
                                         timeout: .seconds(5), outcome: outcome)
    }
    guard case .exited = result else {
        Issue.record("did not see the exit")
        return
    }
}

/// A reply this version can't decode is an error, not a closed connection.
@MainActor
@Test func undecodableReplyThrows() async throws {
    let server = makeServer { _, reply in reply.send(Data(#"{"state":1}"#.utf8)) }
    defer { xpc_connection_cancel(server.listener) }
    await #expect(throws: (any Error).self) {
        try await waitUntilReady(endpoint: server.endpoint, timeout: .seconds(5))
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

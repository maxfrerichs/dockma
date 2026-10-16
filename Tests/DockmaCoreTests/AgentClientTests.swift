import Foundation
import Testing
@testable import DockmaCore

/// A connected pair: `host` goes to `AgentClient.accept`, `agent` plays the
/// guest agent.
private func makeConnection() throws -> (host: Int32, agent: Int32) {
    var fds: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (fds[0], fds[1])
}

private func send(_ lines: String, to fd: Int32) {
    writeAll(Data(lines.utf8), to: fd)
}

/// Readiness changes that `client` reported, in order.
@MainActor
private final class ReadinessLog {
    private(set) var changes: [Bool] = []

    init(_ client: AgentClient) {
        client.onDockerReadyChange = { [weak self] in self?.changes.append($0) }
    }
}

/// Waits until `condition` holds; the client delivers on the main actor.
@MainActor
private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func agentReportsReadinessUntilItDisconnects() async throws {
    let client = AgentClient()
    let log = ReadinessLog(client)
    let connection = try makeConnection()
    client.accept(connection.host)
    #expect(client.isConnected)

    send(#"{"type":"hello","version":"0.4.0","kernel":"6.18.57"}"# + "\n" + #"{"type":"docker","ready":true}"# + "\n", to: connection.agent)
    try await waitUntil { log.changes == [true] }
    #expect(client.isDockerReady)
    #expect(client.version == "0.4.0")

    // Losing the agent means Docker's state is unknown: not ready.
    close(connection.agent)
    try await waitUntil { log.changes == [true, false] }
    #expect(client.isConnected == false)
}

@MainActor
@Test func newAgentConnectionReplacesTheOldOne() async throws {
    let client = AgentClient()
    let log = ReadinessLog(client)
    let old = try makeConnection()
    client.accept(old.host)
    send(#"{"type":"docker","ready":true}"# + "\n", to: old.agent)
    try await waitUntil { log.changes == [true] }

    // The agent restarted: the new connection replaces the old one, which
    // the client shuts down.
    let new = try makeConnection()
    client.accept(new.host)
    var byte: UInt8 = 0
    #expect(read(old.agent, &byte, 1) == 0)
    close(old.agent)
    // Give the old connection's detach time to run on the main actor; it must
    // not mark the new connection disconnected or Docker not ready.
    try await Task.sleep(for: .milliseconds(100))
    #expect(client.isConnected)
    #expect(log.changes == [true])

    send(#"{"type":"docker","ready":false}"# + "\n", to: new.agent)
    try await waitUntil { log.changes == [true, false] }
    close(new.agent)
    try await waitUntil { !client.isConnected }
}

@MainActor
@Test func stoppedClientRefusesConnections() throws {
    let client = AgentClient()
    client.stop()
    let connection = try makeConnection()
    defer { close(connection.agent) }
    client.accept(connection.host)
    #expect(client.isConnected == false)
    // The client closed its end.
    var byte: UInt8 = 0
    #expect(read(connection.agent, &byte, 1) == 0)
}

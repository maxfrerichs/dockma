import Foundation
import Testing
@testable import DockmaCore

/// A short socket path; sun_path holds only 104 bytes.
private func makeSocketPath() -> String {
    "/tmp/dockma-test-\(UUID().uuidString.prefix(8)).sock"
}

/// Connects and waits off the main actor, which serves the replies.
private func waitUntilReady(path: String, timeout: Duration) async throws -> ControlClient.WaitOutcome {
    try await runOnThread {
        let fd = try UnixSocket.connect(path: path, timeoutSeconds: 5)
        return try ControlClient.waitUntilReady(fd: fd, timeout: timeout)
    }
}

private let status = DaemonStatus(
    state: .running, pid: 1, startedAt: Date(timeIntervalSince1970: 0), cpus: 2, memoryMiB: 1024,
    agentConnected: true, agentVersion: nil, guestKernel: nil, forwardedPorts: [], warnings: [])

@MainActor
@Test func waitIsAnsweredWhenTheServerReplies() async throws {
    let path = makeSocketPath()
    var pending: [ControlReply] = []
    let listener = try ControlServer.listen(path: path) { request, reply in
        #expect(request.command == .wait)
        pending.append(reply)
        // Reply later, as the daemon does once Docker is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                pending.forEach { $0.send(try! JSONEncoder().encode(status)) }
            }
        }
    }
    defer { listener.cancel() }
    guard case .ready(let reply) = try await waitUntilReady(path: path, timeout: .seconds(5)) else {
        Issue.record("not ready")
        return
    }
    #expect(reply == status)
}

@MainActor
@Test func waitSeesAClosedReply() async throws {
    let path = makeSocketPath()
    let listener = try ControlServer.listen(path: path) { _, reply in reply.close() }
    defer { listener.cancel() }
    guard case .closed = try await waitUntilReady(path: path, timeout: .seconds(5)) else {
        Issue.record("not closed")
        return
    }
}

@MainActor
@Test func waitTimesOut() async throws {
    let path = makeSocketPath()
    var pending: [ControlReply] = []
    let listener = try ControlServer.listen(path: path) { _, reply in pending.append(reply) }
    defer {
        listener.cancel()
        pending.forEach { $0.close() }
    }
    guard case .timedOut = try await waitUntilReady(path: path, timeout: .milliseconds(100)) else {
        Issue.record("did not time out")
        return
    }
}

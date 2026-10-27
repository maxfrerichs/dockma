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

/// A daemon whose reply doesn't decode is still a running daemon, not none.
@MainActor
@Test func daemonWithAnUndecodableReplyIsAnswering() async throws {
    let root = URL(fileURLWithPath: "/tmp/dockma-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root, home: root)
    let listener = try ControlServer.listen(path: paths.controlSocket.path) { _, reply in reply.send(Data(#"{"state":1}"#.utf8)) }
    defer { listener.cancel() }
    let (answering, decodes) = try await runOnThread {
        (ControlClient.isDaemonAnswering(paths: paths), (try? ControlClient.status(paths: paths)) != nil)
    }
    #expect(answering)
    #expect(!decodes)
}

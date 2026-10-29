import Foundation

/// The control connection that dockma-agent dials to the host. It takes each
/// new connection as the agent (re)starts, and dispatches the agent's
/// messages on the main actor.
@MainActor
public final class AgentClient {
    /// How long a write to the agent may block before the connection is dropped.
    nonisolated static let sendTimeoutSeconds = 5

    private var fd: Int32 = -1
    private var isStopped = false

    public private(set) var version: String?
    public private(set) var kernel: String?
    /// Whether the agent last reported dockerd's API as answering; false while
    /// the agent is disconnected.
    public private(set) var isDockerReady = false
    public var isConnected: Bool { fd >= 0 }
    public var onPorts: (([ForwardedPort]) -> Void)?
    /// Called with the bind-mount sources the agent wants watched for changes.
    public var onWatch: (([String]) -> Void)?
    public var onConnect: (() -> Void)?
    /// Called when `isDockerReady` changes.
    public var onDockerReadyChange: ((Bool) -> Void)?

    /// Creates a client with no connection yet.
    public init() {}

    /// Closes the connection and refuses later ones.
    public func stop() {
        isStopped = true
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Sends a message; returns false when the agent isn't connected or the
    /// write timed out, which drops the connection.
    @discardableResult
    public func send(_ message: AgentMessage) -> Bool {
        guard fd >= 0, let data = try? jsonLine(message) else { return false }
        guard writeAll(data, to: fd) else {
            // The reader thread sees EOF and detaches it; the agent redials.
            shutdown(fd, SHUT_RDWR)
            return false
        }
        return true
    }

    /// Takes a connection the agent opened. It replaces an existing one,
    /// which belongs to an agent that has since restarted.
    public func accept(_ newFD: Int32) {
        guard !isStopped else {
            close(newFD)
            return
        }
        if fd >= 0 {
            // The reader thread sees EOF and detaches the old descriptor.
            shutdown(fd, SHUT_RDWR)
        }
        fd = newFD
        // This runs on the main actor: a guest that stops reading mustn't block it.
        SocketOptions.setTimeout(seconds: Self.sendTimeoutSeconds, on: newFD, for: [SO_SNDTIMEO])
        Log.info("agent connected")
        onConnect?()
        Thread.detachNewThread { [newFD] in
            let reader = LineReader(fd: newFD)
            while let line = reader.readLine() {
                guard let message = try? JSONDecoder().decode(AgentMessage.self, from: line) else { continue }
                // The main queue keeps messages in order; Task hops don't promise that.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(message, from: newFD) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.detach(newFD) } }
        }
    }

    /// Closes a connection whose reader hit EOF, and marks the agent
    /// disconnected if it was the current one.
    private func detach(_ oldFD: Int32) {
        // A replaced connection only needs closing.
        defer { close(oldFD) }
        guard fd == oldFD else { return }
        fd = -1
        Log.info("agent disconnected")
        setDockerReady(false)
    }

    /// Applies one message from the agent connection `sender`.
    private func handle(_ message: AgentMessage, from sender: Int32) {
        // Late messages from a replaced connection would overwrite the
        // current agent's state.
        guard sender == fd else { return }
        switch message.type {
        case "hello":
            version = message.version
            kernel = message.kernel
            Log.info("agent \(message.version ?? "?") on kernel \(message.kernel ?? "?")")
        case "docker":
            setDockerReady(message.ready ?? false)
        case "ports":
            onPorts?(message.ports ?? [])
        case "watch":
            onWatch?(message.paths ?? [])
        default:
            Log.info("agent sent unknown message type \(message.type)")
        }
    }

    /// Records Docker's readiness and reports a change.
    private func setDockerReady(_ ready: Bool) {
        guard ready != isDockerReady else { return }
        isDockerReady = ready
        Log.info(ready ? "Docker ready" : "Docker not ready")
        onDockerReadyChange?(ready)
    }
}

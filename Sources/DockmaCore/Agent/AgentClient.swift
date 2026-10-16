import Foundation

/// Keeps a connection to dockma-agent's control port open, reconnecting when
/// the agent restarts, and dispatches its messages on the main actor.
@MainActor
public final class AgentClient {
    private let host: VMHost
    private var fd: Int32 = -1
    private var stopped = false

    public private(set) var version: String?
    public private(set) var kernel: String?
    public var isConnected: Bool { fd >= 0 }
    public var onPorts: (([ForwardedPort]) -> Void)?
    public var onConnect: (() -> Void)?

    public init(host: VMHost) {
        self.host = host
    }

    public func start() {
        Task { await connectLoop() }
    }

    public func stop() {
        stopped = true
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Sends a message; returns false when the agent isn't connected.
    @discardableResult
    public func send(_ message: AgentMessage) -> Bool {
        guard fd >= 0, let data = try? jsonLine(message) else { return false }
        return writeAll(fd, data)
    }

    private func connectLoop() async {
        while !stopped && fd < 0 {
            do {
                let fd = try await host.connect(port: VMConfigurationBuilder.Port.control)
                attach(fd)
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func attach(_ newFD: Int32) {
        fd = newFD
        Log.info("agent connected")
        onConnect?()
        Thread.detachNewThread { [newFD] in
            let reader = LineReader(fd: newFD)
            while let line = reader.readLine() {
                guard let message = try? JSONDecoder().decode(AgentMessage.self, from: line) else { continue }
                Task { @MainActor in self.handle(message) }
            }
            Task { @MainActor in self.detach(newFD) }
        }
    }

    private func detach(_ oldFD: Int32) {
        guard fd == oldFD else { return }
        close(oldFD)
        fd = -1
        Log.info("agent disconnected")
        if !stopped {
            Task { await connectLoop() }
        }
    }

    private func handle(_ message: AgentMessage) {
        switch message.type {
        case "hello":
            version = message.version
            kernel = message.kernel
            Log.info("agent \(message.version ?? "?") on kernel \(message.kernel ?? "?")")
        case "ports":
            onPorts?(message.ports ?? [])
        default:
            Log.info("agent sent unknown message type \(message.type)")
        }
    }
}

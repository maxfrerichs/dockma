import Foundation

/// A published container port, as reported by dockma-agent. `target` is the
/// guest address the agent dials for tunnelled connections.
public struct ForwardedPort: Codable, Hashable, Sendable {
    public let port: UInt16
    public let target: String

    public init(port: UInt16, target: String) {
        self.port = port
        self.target = target
    }
}

/// JSON-lines message on the vsock control channel (port 1025). Mirrors the
/// `message` struct in vm/agent/main.go.
public struct AgentMessage: Codable, Equatable, Sendable {
    public var type: String
    public var version: String?
    public var kernel: String?
    public var ports: [ForwardedPort]?
    public var unixNanos: Int64?

    public init(type: String, version: String? = nil, kernel: String? = nil, ports: [ForwardedPort]? = nil, unixNanos: Int64? = nil) {
        self.type = type
        self.version = version
        self.kernel = kernel
        self.ports = ports
        self.unixNanos = unixNanos
    }

    public static func setTime(_ date: Date) -> AgentMessage {
        AgentMessage(type: "settime", unixNanos: Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    public static let shutdown = AgentMessage(type: "shutdown")
}

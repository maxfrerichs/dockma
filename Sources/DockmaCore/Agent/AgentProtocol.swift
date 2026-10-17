import Foundation

/// A published container port, as reported by dockma-agent. `target` is the
/// guest address the agent dials for tunnelled connections.
public struct ForwardedPort: Codable, Hashable, Sendable {
    /// The transport of a published port; raw values are wire strings.
    public enum Transport: String, Codable, Comparable, Sendable {
        case tcp, udp

        /// Orders TCP before UDP, as the agent sorts them.
        public static func < (lhs: Transport, rhs: Transport) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A host port and its transport, which together identify a forward.
    public struct Key: Hashable, Comparable, Sendable, CustomStringConvertible {
        /// The host port number.
        public var port: UInt16
        /// The port's transport.
        public var transport: Transport

        /// Creates a key; `transport` defaults to TCP.
        public init(port: UInt16, transport: Transport = .tcp) {
            self.port = port
            self.transport = transport
        }

        /// Orders by port, then transport.
        public static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.port, lhs.transport) < (rhs.port, rhs.transport)
        }

        /// The port as `dockma status` shows it: `8080` or `5353/udp`.
        public var description: String {
            transport == .tcp ? "\(port)" : "\(port)/\(transport.rawValue)"
        }
    }

    /// The host port to listen on.
    public let port: UInt16
    /// Whether the port carries TCP or UDP.
    public let transport: Transport
    /// The guest address the agent dials, such as `127.0.0.1:8080`.
    public let target: String

    /// The port and transport that identify this forward.
    public var key: Key { Key(port: port, transport: transport) }

    /// Creates a forwarded port; `transport` defaults to TCP.
    public init(port: UInt16, transport: Transport = .tcp, target: String) {
        self.port = port
        self.transport = transport
        self.target = target
    }

    private enum CodingKeys: String, CodingKey { case port, transport, target }

    /// Decodes a port; a missing `transport` means TCP.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(UInt16.self, forKey: .port)
        transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .tcp
        target = try container.decode(String.self, forKey: .target)
    }
}

/// JSON-lines message on the vsock control channel (port 1025). Mirrors the
/// `message` struct in vm/agent/main.go.
public struct AgentMessage: Codable, Equatable, Sendable {
    public var type: String
    public var version: String?
    public var kernel: String?
    public var ports: [ForwardedPort]?
    /// Whether dockerd's API answers; set on `docker` messages.
    public var ready: Bool?
    public var unixNanos: Int64?

    public init(type: String, version: String? = nil, kernel: String? = nil, ports: [ForwardedPort]? = nil, ready: Bool? = nil, unixNanos: Int64? = nil) {
        self.type = type
        self.version = version
        self.kernel = kernel
        self.ports = ports
        self.ready = ready
        self.unixNanos = unixNanos
    }

    public static func setTime(_ date: Date) -> AgentMessage {
        AgentMessage(type: "settime", unixNanos: Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    public static let shutdown = AgentMessage(type: "shutdown")
}

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
    /// The bind-mount sources on the home share to watch; set on `watch` messages.
    public var paths: [String]?
    /// Changes made on the Mac; set on `files` messages.
    public var files: [FileEvent]?

    public init(type: String, version: String? = nil, kernel: String? = nil, ports: [ForwardedPort]? = nil, ready: Bool? = nil, unixNanos: Int64? = nil, paths: [String]? = nil, files: [FileEvent]? = nil) {
        self.type = type
        self.version = version
        self.kernel = kernel
        self.ports = ports
        self.ready = ready
        self.unixNanos = unixNanos
        self.paths = paths
        self.files = files
    }

    public static func setTime(_ date: Date) -> AgentMessage {
        AgentMessage(type: "settime", unixNanos: Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    public static let shutdown = AgentMessage(type: "shutdown")

    /// Creates a `files` message carrying changes made on the Mac.
    public static func files(_ events: [FileEvent]) -> AgentMessage {
        AgentMessage(type: "files", files: events)
    }
}

/// One change made on the Mac below a watched path. Mirrors `Event` in
/// vm/agent/internal/fileevents/fileevents.go.
public struct FileEvent: Codable, Equatable, Sendable {
    /// What happened to the path; raw values are wire strings.
    public enum Op: String, Codable, Sendable {
        /// Content or metadata changed.
        case modified = "M"
        /// Created, or renamed to this path.
        case created = "C"
        /// Deleted, or renamed away from this path.
        case deleted = "D"
    }

    /// What happened.
    public var op: Op
    /// The absolute path, which is the same on the Mac and in the guest.
    public var path: String
    /// The file's modification time after the change; nil for a deletion.
    public var mtimeNanos: Int64?
    /// The file's size after the change; nil for a deletion.
    public var size: Int64?

    /// Creates an event; a deletion carries no mtime or size.
    public init(op: Op, path: String, mtimeNanos: Int64? = nil, size: Int64? = nil) {
        self.op = op
        self.path = path
        self.mtimeNanos = mtimeNanos
        self.size = size
    }
}

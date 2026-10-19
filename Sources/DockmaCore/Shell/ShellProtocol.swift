import Foundation

/// Parameters of a shell session, sent as the payload of the first frame.
public struct ShellStart: Codable, Equatable, Sendable {
    /// Command to run; empty means a login shell (`/bin/sh -l`).
    public var argv: [String]
    public var tty: Bool
    public var rows: UInt16
    public var cols: UInt16
    public var term: String
    /// Asks for stdin flow control: the agent grants stdin credit with
    /// `window` frames, so it never stops reading the connection and signals
    /// can't get stuck behind stdin the command doesn't read. Older agents
    /// ignore the field and never send `window`.
    public var flow: Bool

    public init(argv: [String], tty: Bool, rows: UInt16, cols: UInt16, term: String, flow: Bool = true) {
        self.argv = argv
        self.tty = tty
        self.rows = rows
        self.cols = cols
        self.term = term
        self.flow = flow
    }
}

/// One frame of the shell protocol on vsock port 1027:
/// `[type u8][length u32 big-endian][payload]`. Mirrors the constants in
/// vm/agent/shell.go; keep the two in sync. Specified in docs/shell-protocol.md.
public enum ShellFrame: Equatable, Sendable {
    // client → agent
    case start(ShellStart)
    case stdin(Data)
    case stdinEOF
    case resize(rows: UInt16, cols: UInt16)
    case signal(Int32)
    // agent → client
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
    case error(String)
    /// The command is running; sent once, before any output.
    case started
    /// Stdin credit in bytes. With flow control the first one arrives before
    /// `started`; later ones return credit as the agent writes stdin.
    case window(UInt32)

    public static let maxPayloadSize = 1 << 20

    var type: UInt8 {
        switch self {
        case .start: 1
        case .stdin: 2
        case .stdinEOF: 3
        case .resize: 4
        case .signal: 5
        case .stdout: 16
        case .stderr: 17
        case .exit: 18
        case .error: 19
        case .started: 20
        case .window: 21
        }
    }

    func payload() throws -> Data {
        switch self {
        case .start(let start):
            return try JSONEncoder().encode(start)
        case .stdin(let data), .stdout(let data), .stderr(let data):
            return data
        case .stdinEOF, .started:
            return Data()
        case let .resize(rows, cols):
            return Self.bigEndian(rows) + Self.bigEndian(cols)
        case .signal(let number):
            return Data([UInt8(truncatingIfNeeded: number)])
        case .exit(let code):
            return Self.bigEndian(UInt32(bitPattern: code))
        case .window(let bytes):
            return Self.bigEndian(bytes)
        case .error(let message):
            return Data(message.utf8)
        }
    }

    public func encode() throws -> Data {
        let body = try payload()
        return Data([type]) + Self.bigEndian(UInt32(body.count)) + body
    }

    static func decode(type: UInt8, payload: Data) throws -> ShellFrame {
        func uint16(_ offset: Int) -> UInt16 {
            payload.dropFirst(offset).prefix(2).reduce(0) { $0 << 8 | UInt16($1) }
        }
        func uint32() -> UInt32 {
            payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
        switch type {
        case 1: return .start(try JSONDecoder().decode(ShellStart.self, from: payload))
        case 2: return .stdin(payload)
        case 3: return .stdinEOF
        case 4:
            guard payload.count == 4 else { throw DockmaError("malformed resize frame") }
            return .resize(rows: uint16(0), cols: uint16(2))
        case 5:
            guard payload.count == 1 else { throw DockmaError("malformed signal frame") }
            return .signal(Int32(payload[payload.startIndex]))
        case 16: return .stdout(payload)
        case 17: return .stderr(payload)
        case 18:
            guard payload.count == 4 else { throw DockmaError("malformed exit frame") }
            return .exit(Int32(bitPattern: uint32()))
        case 19: return .error(String(decoding: payload, as: UTF8.self))
        case 20: return .started
        case 21:
            guard payload.count == 4 else { throw DockmaError("malformed window frame") }
            return .window(uint32())
        default: throw DockmaError("unknown shell frame type \(type)")
        }
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

/// Incremental frame parser: feed it bytes as they arrive, then drain frames.
public struct ShellFrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or nil until more bytes arrive.
    public mutating func next() throws -> ShellFrame? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
        guard length <= ShellFrame.maxPayloadSize else {
            throw DockmaError("shell frame of \(length) bytes exceeds the limit")
        }
        guard buffer.count >= 5 + length else { return nil }
        let type = buffer[start]
        let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
        buffer.removeSubrange(start..<(start + 5 + length))
        return try ShellFrame.decode(type: type, payload: payload)
    }
}

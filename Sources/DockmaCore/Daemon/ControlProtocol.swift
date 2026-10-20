import Foundation

/// CLI → daemon request on ~/.dockma/control.sock (one JSON line each way).
public struct ControlRequest: Codable, Sendable {
    /// `wait` is answered with a `DaemonStatus` once Docker is ready, and
    /// closed without a reply if the daemon stops first.
    public enum Command: String, Codable, Sendable { case status, stop, wait }
    public var command: Command
    public init(command: Command) { self.command = command }
}

/// Daemon → CLI status reply.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case starting, running, stopping }

    public var state: State
    public var pid: Int32
    public var startedAt: Date
    public var cpus: Int
    public var memoryMiB: UInt64
    public var agentConnected: Bool
    public var agentVersion: String?
    public var guestKernel: String?
    /// Forwarded TCP ports.
    public var forwardedPorts: [UInt16]
    /// Forwarded UDP ports; nil from a daemon that predates UDP forwarding.
    public var forwardedUDPPorts: [UInt16]? = nil
    public var warnings: [String]
    /// The daemon's dockma version; nil from a daemon that predates it.
    public var version: String? = nil

    /// Every forwarded port, sorted by port and then transport.
    public var forwardedPortKeys: [ForwardedPort.Key] {
        (forwardedPorts.map { ForwardedPort.Key(port: $0, transport: .tcp) }
            + (forwardedUDPPorts ?? []).map { ForwardedPort.Key(port: $0, transport: .udp) }).sorted()
    }
}

/// Talks to a running daemon. Every call fails fast when none is listening.
public enum ControlClient {
    /// Whether a daemon answers a status request. A socket round trip with
    /// a 5 s timeout.
    public static func isDaemonAnswering(paths: Paths) -> Bool {
        (try? status(paths: paths)) != nil
    }

    public static func status(paths: Paths) throws -> DaemonStatus {
        let data = try roundTrip(paths: paths, request: ControlRequest(command: .status))
        let decoder = JSONDecoder()
        return try decoder.decode(DaemonStatus.self, from: data)
    }

    public static func stop(paths: Paths) throws {
        _ = try roundTrip(paths: paths, request: ControlRequest(command: .stop))
    }

    /// How a `wait` request ended.
    public enum WaitOutcome: Sendable {
        /// Docker is ready.
        case ready(DaemonStatus)
        /// The daemon closed the connection without replying: it exited or
        /// is stopping, or it is too old to know `wait`.
        case closed
        /// Nothing arrived within the timeout.
        case timedOut
    }

    /// Asks the daemon on an already connected `fd` to reply once Docker is
    /// ready, and blocks until it does, closes, or `timeout` passes. Takes
    /// ownership of `fd`.
    public static func waitUntilReady(fd: Int32, timeout: Duration) throws -> WaitOutcome {
        defer { close(fd) }
        guard writeAll(try jsonLine(ControlRequest(command: .wait)), to: fd) else {
            // The daemon went away between connect and write.
            return .closed
        }
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pending, 1, Int32(clamping: max(0, Int(timeout / .milliseconds(1)))))
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return .timedOut }
        // Readable means a reply or EOF, and the reply is a single short line.
        guard let line = LineReader(fd: fd).readLine() else { return .closed }
        return .ready(try JSONDecoder().decode(DaemonStatus.self, from: line))
    }

    static func roundTrip(paths: Paths, request: ControlRequest) throws -> Data {
        let fd = try UnixSocket.connect(path: paths.controlSocket.path, timeoutSeconds: 5)
        defer { close(fd) }
        guard writeAll(try jsonLine(request), to: fd) else { throw DockmaError.posix("write control socket") }
        guard let line = LineReader(fd: fd).readLine() else {
            throw DockmaError("daemon closed the control connection")
        }
        return line
    }
}

/// The pending reply to one control request. It owns the client descriptor
/// until `send(_:)` or `close()`; a request that is never answered stays
/// open, so the owner must eventually call one of them.
@MainActor
public final class ControlReply {
    private var fd: Int32

    /// Takes ownership of the client descriptor `fd`.
    init(fd: Int32) {
        self.fd = fd
    }

    /// Writes `data` as one line and closes the connection.
    public func send(_ data: Data) {
        guard fd >= 0 else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        writeAll(line, to: fd)
        close()
    }

    /// Closes the connection without a reply; the client reads EOF.
    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

/// Serves the control socket; `respond` runs on the main actor and answers
/// through the `ControlReply`, at once or later.
@MainActor
public enum ControlServer {
    public static func listen(path: String, respond: @escaping @MainActor (ControlRequest, ControlReply) -> Void) throws -> SocketListener {
        try SocketListener.unix(path: path) { client in
            // Read off the accept loop, so a client that sends nothing can't
            // hold up the others for the 5 s timeout.
            // A thread, not global(): the read blocks, and global() workers
            // also run the accept and UDP read sources.
            Thread.detachNewThread {
                SocketOptions.setTimeout(seconds: 5, on: client)
                guard let line = LineReader(fd: client).readLine(),
                      let request = try? JSONDecoder().decode(ControlRequest.self, from: line)
                else {
                    close(client)
                    return
                }
                Task { @MainActor in
                    respond(request, ControlReply(fd: client))
                }
            }
        }
    }
}

public enum UnixSocket {
    /// The socket address of `path`; throws if it doesn't fit `sun_path`.
    static func makeAddress(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DockmaError("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Connects to a unix socket, with send/receive timeouts unless
    /// `timeoutSeconds` is nil (interactive sessions).
    public static func connect(path: String, timeoutSeconds: Int?) throws -> Int32 {
        var addr = try makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockmaError.posix("socket") }
        SocketOptions.disableSIGPIPE(on: fd)
        if let timeoutSeconds { SocketOptions.setTimeout(seconds: timeoutSeconds, on: fd) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let error = DockmaError.posix("connect \(path)")
            close(fd)
            throw error
        }
        return fd
    }
}

/// Minimal Docker API health check over a unix socket.
public enum DockerPing {
    /// Whether dockerd answers `GET /_ping` on the unix socket at `socketPath`.
    public static func isResponding(socketPath: String) -> Bool {
        guard let fd = try? UnixSocket.connect(path: socketPath, timeoutSeconds: 3) else { return false }
        defer { close(fd) }
        let request = "GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        guard writeAll(Data(request.utf8), to: fd) else { return false }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        let text = String(decoding: response, as: UTF8.self)
        return text.hasPrefix("HTTP/1.1 200") && text.hasSuffix("OK")
    }
}

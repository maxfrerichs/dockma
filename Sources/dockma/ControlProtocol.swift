import Foundation

/// CLI → daemon request on ~/.dockma/control.sock (one JSON line each way).
public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case status, stop }
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
    public var forwardedPorts: [UInt16]
    public var warnings: [String]
}

/// Talks to a running daemon. Every call fails fast when none is listening.
public enum ControlClient {
    public static func status(paths: Paths) throws -> DaemonStatus {
        let data = try roundTrip(paths: paths, request: ControlRequest(command: .status))
        let decoder = JSONDecoder()
        return try decoder.decode(DaemonStatus.self, from: data)
    }

    public static func stop(paths: Paths) throws {
        _ = try roundTrip(paths: paths, request: ControlRequest(command: .stop))
    }

    static func roundTrip(paths: Paths, request: ControlRequest) throws -> Data {
        let fd = try UnixSocket.connect(path: paths.controlSocket.path, timeoutSeconds: 5)
        defer { close(fd) }
        guard writeAll(fd, try jsonLine(request)) else { throw posixError("write control socket") }
        guard let line = LineReader(fd: fd).readLine() else {
            throw DockmaError("daemon closed the control connection")
        }
        return line
    }
}

/// Serves the control socket; `respond` runs on the main actor.
@MainActor
public enum ControlServer {
    public static func listen(path: String, respond: @escaping @MainActor (ControlRequest) -> Data?) throws -> SocketListener {
        try SocketListener.unix(path: path) { client in
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let line = LineReader(fd: client).readLine(),
                  let request = try? JSONDecoder().decode(ControlRequest.self, from: line)
            else {
                close(client)
                return
            }
            Task { @MainActor in
                if var reply = respond(request) {
                    reply.append(UInt8(ascii: "\n"))
                    writeAll(client, reply)
                }
                close(client)
            }
        }
    }
}

public enum UnixSocket {
    /// Connects to a unix socket, with send/receive timeouts unless
    /// `timeoutSeconds` is nil (interactive sessions).
    public static func connect(path: String, timeoutSeconds: Int?) throws -> Int32 {
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if let timeoutSeconds {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let error = posixError("connect \(path)")
            close(fd)
            throw error
        }
        return fd
    }
}

/// Minimal Docker API health check over a unix socket.
public enum DockerPing {
    public static func ping(socketPath: String) -> Bool {
        guard let fd = try? UnixSocket.connect(path: socketPath, timeoutSeconds: 3) else { return false }
        defer { close(fd) }
        let request = "GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        guard writeAll(fd, Data(request.utf8)) else { return false }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        let text = String(decoding: response, as: UTF8.self)
        return text.hasPrefix("HTTP/1.1 200") && text.hasSuffix("OK")
    }
}

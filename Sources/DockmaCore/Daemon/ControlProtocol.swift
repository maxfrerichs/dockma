import Foundation
// XPC objects are thread-safe, but the module predates Sendable.
@preconcurrency import XPC

/// CLI → daemon request, sent as JSON in an XPC message (`ControlMessage`).
public struct ControlRequest: Codable, Sendable {
    /// `wait` is answered with a `DaemonStatus` once Docker is ready, and
    /// closed without a reply if the daemon stops first.
    public enum Command: String, Codable, Sendable { case status, stop, wait }
    public var command: Command
    public init(command: Command) { self.command = command }
}

/// Daemon → CLI status reply.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case starting, running, stopping
        /// A state from a newer daemon that this CLI doesn't know.
        case unknown

        /// Decodes a state, mapping one this version doesn't know to `unknown`.
        public init(from decoder: any Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

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

/// Talks to the daemon over its launchd Mach service, which is named after
/// the job label (`LaunchAgent.label(for:)`).
public enum ControlClient {
    /// The daemon's status, or nil when its job has no process. Throws when
    /// a running daemon doesn't answer or its reply doesn't decode: it is
    /// another version, or one of the two signatures doesn't match.
    public static func status(paths: Paths) throws -> DaemonStatus? {
        // A lookup of a loaded job whose process exited makes launchd start
        // it again, booting the VM; check first. A daemon that exits between
        // the check and the lookup can still be restarted this way.
        guard LaunchAgent(paths: paths).state().pid != nil else { return nil }
        switch exchange(ControlRequest(command: .status), over: makeConnection(paths: paths), timeout: .seconds(5)) {
        case .reply(let data): return try JSONDecoder().decode(DaemonStatus.self, from: data)
        case .closed, .exited: throw DockmaError("the dockma daemon closed the control connection")
        case .timedOut: throw DockmaError("the dockma daemon did not answer")
        }
    }

    /// How a `wait` request ended.
    public enum WaitOutcome: Sendable {
        /// Docker is ready.
        case ready(DaemonStatus)
        /// The daemon's process exited, or launchd reports the job gone.
        case exited
        /// The connection ended without a reply: the daemon is stopping or
        /// exited, it is too old to serve XPC, or a signature check failed.
        case closed
        /// Nothing arrived within the timeout.
        case timedOut
    }

    /// Asks the daemon to reply once Docker is ready, and blocks until it
    /// does, the connection ends, its process exits, or `timeout` passes.
    /// launchd queues the request until the daemon checks in, and starts a
    /// loaded job that isn't running.
    public static func waitUntilReady(paths: Paths, timeout: Duration) throws -> WaitOutcome {
        let outcome = ExchangeOutcome()
        // A daemon that fails before it takes the request leaves it queued,
        // and no error reaches this side; the exit is the only sign.
        let watch = DaemonExitWatch(agent: LaunchAgent(paths: paths)) { outcome.set(.exited) }
        defer { watch.stop() }
        return try waitUntilReady(over: makeConnection(paths: paths), timeout: timeout, outcome: outcome)
    }

    /// `waitUntilReady(paths:timeout:)` on the given unactivated `connection`.
    static func waitUntilReady(over connection: xpc_connection_t, timeout: Duration,
                               outcome: ExchangeOutcome = ExchangeOutcome()) throws -> WaitOutcome {
        switch exchange(ControlRequest(command: .wait), over: connection, timeout: timeout, outcome: outcome) {
        case .reply(let data): return .ready(try JSONDecoder().decode(DaemonStatus.self, from: data))
        case .closed: return .closed
        case .exited: return .exited
        case .timedOut: return .timedOut
        }
    }

    /// A connection to the daemon of `paths` that accepts only a peer signed
    /// as the daemon.
    static func makeConnection(paths: Paths) -> xpc_connection_t {
        let connection = xpc_connection_create_mach_service(LaunchAgent.label(for: paths), nil, 0)
        ControlPeer.require(CodeSigning.daemonIdentifier, on: connection)
        return connection
    }

    /// How one request ended.
    enum Exchange: Equatable {
        case reply(Data)
        case closed
        /// Set from outside the exchange, by a `DaemonExitWatch`.
        case exited
        case timedOut
    }

    /// Sends `request` on the unactivated `connection`, waits for the reply
    /// or another result set on `outcome`, and cancels the connection.
    static func exchange(_ request: ControlRequest, over connection: xpc_connection_t, timeout: Duration,
                         outcome: ExchangeOutcome = ExchangeOutcome()) -> Exchange {
        // A private serial queue, not global(): the caller blocks below, and
        // global() shares its threads with the cooperative pool.
        let queue = DispatchQueue(label: "io.dockma.control-client")
        xpc_connection_set_target_queue(connection, queue)
        // Errors also arrive as the reply, which is all this needs.
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }

        let message = xpc_dictionary_create(nil, nil, 0)
        guard let json = try? JSONEncoder().encode(request) else { return .closed }
        ControlMessage.setJSON(json, in: message)
        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            outcome.set(ControlMessage.json(in: reply).map(Exchange.reply) ?? .closed)
        }
        return outcome.wait(timeout: timeout) ?? .timedOut
    }
}

/// The result of one exchange, handed from the reply handler or an exit
/// watch to the caller. The first result wins.
final class ExchangeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: ControlClient.Exchange?

    /// Stores the result, unless one is already stored, and wakes the caller.
    func set(_ value: ControlClient.Exchange) {
        let isFirst = lock.withLock {
            guard self.value == nil else { return false }
            self.value = value
            return true
        }
        if isFirst { done.signal() }
    }

    /// The result, or nil if none arrives within `timeout`.
    func wait(timeout: Duration) -> ControlClient.Exchange? {
        guard done.wait(timeout: .now() + timeout / .seconds(1)) == .success else { return nil }
        return lock.withLock { value }
    }
}

/// Watches a job's daemon on a thread of its own and calls `onExit` once,
/// when its process exits or launchd reports the job gone.
private final class DaemonExitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false

    /// Starts watching the daemon of `agent`, whose process may not exist yet.
    init(agent: LaunchAgent, onExit: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [self] in
            guard let events = try? KernelEvents() else { return }
            var isWatchingExit = false
            while !lock.withLock({ isStopped }) {
                if !isWatchingExit {
                    let job = agent.state()
                    if job.hasExited { return onExit() }
                    if let pid = job.pid {
                        guard events.watchExit(ofProcess: pid) else { return onExit() }
                        isWatchingExit = true
                    }
                }
                // Until the pid is known, launchd is asked again each round.
                if events.wait(timeout: isWatchingExit ? .seconds(1) : .milliseconds(200)) == .processExited {
                    return onExit()
                }
            }
        }
    }

    /// Stops watching within a second; `onExit` isn't called after that.
    func stop() {
        lock.withLock { isStopped = true }
    }
}

/// The peer check both ends of the control connection set.
enum ControlPeer {
    /// Makes the unactivated `connection` accept only a peer signed as
    /// `identifier`. Stops the process if the requirement doesn't take: the
    /// connection must not accept any peer instead, and an inactive one
    /// can't be safely released.
    static func require(_ identifier: String, on connection: xpc_connection_t) {
        let requirement = CodeSigning.requirement(forPeer: identifier)
        precondition(xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0,
                     "invalid code signing requirement: \(requirement)")
    }
}

/// The control payload in an XPC message: the request's or reply's JSON as
/// data under one key.
enum ControlMessage {
    static let key = "json"

    /// Stores `json` in the dictionary `message`.
    static func setJSON(_ json: Data, in message: xpc_object_t) {
        json.withUnsafeBytes { xpc_dictionary_set_data(message, key, $0.baseAddress!, $0.count) }
    }

    /// The JSON in `message`, or nil for an error or a message without it.
    static func json(in message: xpc_object_t) -> Data? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return nil }
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &length) else { return nil }
        return Data(bytes: bytes, count: length)
    }
}

/// The pending reply to one control request. A request that is never
/// answered stays pending, so the owner must eventually call `send(_:)` or
/// `close()`.
@MainActor
public final class ControlReply {
    private var peer: xpc_connection_t?
    private let request: xpc_object_t

    /// The reply to `request`, which arrived on `peer`.
    init(peer: xpc_connection_t, request: xpc_object_t) {
        self.peer = peer
        self.request = request
    }

    /// Sends `data` as the reply.
    public func send(_ data: Data) {
        guard let peer, let reply = xpc_dictionary_create_reply(request) else { return }
        ControlMessage.setJSON(data, in: reply)
        xpc_connection_send_message(peer, reply)
        self.peer = nil
    }

    /// Ends the connection without a reply; the client sees it close.
    public func close() {
        guard let peer else { return }
        xpc_connection_cancel(peer)
        self.peer = nil
    }
}

/// Serves control requests; `respond` runs on the main actor and answers
/// through the `ControlReply`, at once or later.
@MainActor
public enum ControlServer {
    /// Checks in the launchd Mach service `name`, admitting only clients
    /// signed as the dockma CLI. Returns the listener, which the caller
    /// cancels to stop serving.
    public static func listen(machService name: String, respond: @escaping @MainActor (ControlRequest, ControlReply) -> Void) -> xpc_connection_t {
        let listener = xpc_connection_create_mach_service(name, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        ControlPeer.require(CodeSigning.cliIdentifier, on: listener)
        serve(listener, respond: respond)
        return listener
    }

    /// Activates the unactivated `listener`, whose target queue is the main
    /// queue, and hands each request of each peer to `respond`.
    static func serve(_ listener: xpc_connection_t, respond: @escaping @MainActor (ControlRequest, ControlReply) -> Void) {
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
                // The service can't be checked in, or the listener was cancelled.
                Log.info("control listener: \(ControlServer.errorDescription(peer))")
                return
            }
            xpc_connection_set_target_queue(peer, .main)
            xpc_connection_set_event_handler(peer) { message in
                // Errors only mean this client went away or was refused.
                guard let json = ControlMessage.json(in: message) else { return }
                MainActor.assumeIsolated {
                    guard let request = try? JSONDecoder().decode(ControlRequest.self, from: json) else {
                        return xpc_connection_cancel(peer)
                    }
                    respond(request, ControlReply(peer: peer, request: message))
                }
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
    }

    /// The description of an XPC error object.
    nonisolated static func errorDescription(_ error: xpc_object_t) -> String {
        xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "unknown error"
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

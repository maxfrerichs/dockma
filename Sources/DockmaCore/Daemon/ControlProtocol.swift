import Foundation

/// The calls the CLI makes on the daemon over its launchd Mach service. The
/// protocol's and the selectors' names are wire names.
@objc(DockmaDaemonControl) public protocol DaemonControl {
    /// Replies with the daemon's status.
    func status(reply: @escaping @Sendable (DaemonStatusMessage) -> Void)
    /// Replies, then shuts the VM down.
    func stop(reply: @escaping @Sendable () -> Void)
    /// Replies with the status once Docker is ready, or with nil when the
    /// daemon stops first.
    func waitUntilReady(reply: @escaping @Sendable (DaemonStatusMessage?) -> Void)
}

/// Daemon → CLI status, printed by `dockma status --json`.
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

/// A `DaemonStatus` as it crosses XPC. The class name and the coder keys are
/// wire names.
@objc(DockmaDaemonStatus)
public final class DaemonStatusMessage: NSObject, NSSecureCoding {
    public static let supportsSecureCoding = true
    /// The carried status.
    public let status: DaemonStatus

    /// A message carrying `status`.
    public init(_ status: DaemonStatus) {
        self.status = status
    }

    /// Encodes each field under its own key.
    public func encode(with coder: NSCoder) {
        coder.encode(status.state.rawValue as NSString, forKey: "state")
        coder.encode(status.pid, forKey: "pid")
        coder.encode(status.startedAt as NSDate, forKey: "startedAt")
        coder.encode(status.cpus, forKey: "cpus")
        coder.encode(Int64(bitPattern: status.memoryMiB), forKey: "memoryMiB")
        coder.encode(status.agentConnected, forKey: "agentConnected")
        coder.encode(status.agentVersion as NSString?, forKey: "agentVersion")
        coder.encode(status.guestKernel as NSString?, forKey: "guestKernel")
        coder.encode(status.forwardedPorts.map(NSNumber.init(value:)) as NSArray, forKey: "forwardedPorts")
        coder.encode(status.forwardedUDPPorts?.map(NSNumber.init(value:)) as NSArray?, forKey: "forwardedUDPPorts")
        coder.encode(status.warnings as NSArray, forKey: "warnings")
        coder.encode(status.version as NSString?, forKey: "version")
    }

    /// Decodes a status; nil when a required field is missing. A state this
    /// version doesn't know becomes `unknown`.
    public init?(coder: NSCoder) {
        guard let state = coder.decodeObject(of: NSString.self, forKey: "state") as String?,
              let startedAt = coder.decodeObject(of: NSDate.self, forKey: "startedAt") as Date?,
              let tcpPorts = coder.decodeArrayOfObjects(ofClass: NSNumber.self, forKey: "forwardedPorts"),
              let warnings = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "warnings"),
              ["pid", "cpus", "memoryMiB", "agentConnected"].allSatisfy(coder.containsValue(forKey:))
        else { return nil }
        status = DaemonStatus(
            state: DaemonStatus.State(rawValue: state) ?? .unknown,
            pid: coder.decodeInt32(forKey: "pid"),
            startedAt: startedAt,
            cpus: coder.decodeInteger(forKey: "cpus"),
            memoryMiB: UInt64(bitPattern: coder.decodeInt64(forKey: "memoryMiB")),
            agentConnected: coder.decodeBool(forKey: "agentConnected"),
            agentVersion: coder.decodeObject(of: NSString.self, forKey: "agentVersion") as String?,
            guestKernel: coder.decodeObject(of: NSString.self, forKey: "guestKernel") as String?,
            forwardedPorts: tcpPorts.map(\.uint16Value),
            forwardedUDPPorts: coder.decodeArrayOfObjects(ofClass: NSNumber.self, forKey: "forwardedUDPPorts")?.map(\.uint16Value),
            warnings: warnings.map { $0 as String },
            version: coder.decodeObject(of: NSString.self, forKey: "version") as String?)
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
        let exchange = exchange(over: makeConnection(paths: paths), timeout: .seconds(5)) { control, reply in
            control.status { reply($0.status) }
        }
        switch exchange {
        case .reply(let status): return status
        case .closed, .exited: throw DockmaError("the dockma daemon closed the control connection")
        case .timedOut: throw DockmaError("the dockma daemon did not answer")
        }
    }

    /// How a `wait` request ended.
    public enum WaitOutcome: Sendable {
        /// Docker is ready.
        case ready(DaemonStatus)
        /// The daemon is stopping.
        case stopping
        /// The daemon's process exited, or launchd reports the job gone.
        case exited
        /// The connection ended without a reply: the daemon exited, it is
        /// too old to serve this protocol, a signature check failed, or the
        /// reply didn't decode.
        case closed
        /// Nothing arrived within the timeout.
        case timedOut
    }

    /// Asks the daemon to reply once Docker is ready, and blocks until it
    /// does, the connection ends, its process exits, or `timeout` passes.
    /// launchd queues the request until the daemon checks in, and starts a
    /// loaded job that isn't running.
    public static func waitUntilReady(paths: Paths, timeout: Duration) -> WaitOutcome {
        let outcome = ExchangeOutcome<DaemonStatus?>()
        // A daemon that fails before it takes the request leaves it queued,
        // and no error reaches this side; the exit is the only sign.
        let watch = DaemonExitWatch(agent: LaunchAgent(paths: paths)) { outcome.set(.exited) }
        defer { watch.stop() }
        return waitUntilReady(over: makeConnection(paths: paths), timeout: timeout, outcome: outcome)
    }

    /// `waitUntilReady(paths:timeout:)` on the given unresumed `connection`.
    static func waitUntilReady(over connection: NSXPCConnection, timeout: Duration,
                               outcome: ExchangeOutcome<DaemonStatus?> = ExchangeOutcome()) -> WaitOutcome {
        let exchange = exchange(over: connection, timeout: timeout, outcome: outcome) { control, reply in
            control.waitUntilReady { reply($0?.status) }
        }
        switch exchange {
        case .reply(let status?): return .ready(status)
        case .reply(nil): return .stopping
        case .closed: return .closed
        case .exited: return .exited
        case .timedOut: return .timedOut
        }
    }

    /// A connection to the daemon of `paths` that accepts only a peer signed
    /// as the daemon.
    static func makeConnection(paths: Paths) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: LaunchAgent.label(for: paths))
        connection.setCodeSigningRequirement(CodeSigning.requirement(forPeer: CodeSigning.daemonIdentifier))
        return connection
    }

    /// How one call ended.
    enum Exchange<Reply: Sendable>: Sendable {
        case reply(Reply)
        case closed
        /// Set from outside the exchange, by a `DaemonExitWatch`.
        case exited
        case timedOut
    }

    /// Makes one `call` on the unresumed `connection`, waits for the reply
    /// it passes on or another result set on `outcome`, and invalidates the
    /// connection.
    static func exchange<Reply: Sendable>(over connection: NSXPCConnection, timeout: Duration,
                                outcome: ExchangeOutcome<Reply> = ExchangeOutcome(),
                                call: (any DaemonControl, @escaping @Sendable (Reply) -> Void) -> Void) -> Exchange<Reply> {
        connection.remoteObjectInterface = NSXPCInterface(with: DaemonControl.self)
        connection.resume()
        defer { connection.invalidate() }
        // Called instead of the reply when the connection ends or the reply
        // doesn't decode.
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in outcome.set(.closed) }
        guard let control = proxy as? any DaemonControl else { return .closed }
        call(control) { outcome.set(.reply($0)) }
        return outcome.wait(timeout: timeout) ?? .timedOut
    }
}

/// The result of one exchange, handed from the reply handler or an exit
/// watch to the caller. The first result wins.
final class ExchangeOutcome<Reply: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: ControlClient.Exchange<Reply>?

    /// Stores the result, unless one is already stored, and wakes the caller.
    func set(_ value: ControlClient.Exchange<Reply>) {
        let isFirst = lock.withLock {
            guard self.value == nil else { return false }
            self.value = value
            return true
        }
        if isFirst { done.signal() }
    }

    /// The result, or nil if none arrives within `timeout`.
    func wait(timeout: Duration) -> ControlClient.Exchange<Reply>? {
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

/// What the daemon does for each control call, on the main actor.
@MainActor
public protocol ControlHandler: AnyObject {
    /// The current status.
    func status() -> DaemonStatus
    /// Starts a stop; runs after the reply is sent.
    func stop()
    /// Calls `reply` once Docker is ready, or with nil when the daemon stops
    /// first. Must call it eventually.
    func waitUntilReady(reply: @escaping @Sendable (DaemonStatus?) -> Void)
}

/// Serves `DaemonControl` to every client of a listener, handing each call
/// to a `ControlHandler` on the main actor.
@MainActor
public final class ControlServer: NSObject, NSXPCListenerDelegate, DaemonControl {
    private let listener: NSXPCListener
    private weak var handler: (any ControlHandler)?

    /// Checks in the launchd Mach service `name`, admitting only clients
    /// signed as the dockma CLI. Serves until the process exits.
    public static func listen(machService name: String, handler: any ControlHandler) -> ControlServer {
        let listener = NSXPCListener(machServiceName: name)
        listener.setConnectionCodeSigningRequirement(CodeSigning.requirement(forPeer: CodeSigning.cliIdentifier))
        return ControlServer(listener: listener, handler: handler)
    }

    /// Serves `handler` on the unresumed `listener`.
    init(listener: NSXPCListener, handler: any ControlHandler) {
        self.listener = listener
        self.handler = handler
        super.init()
        // The listener holds its delegate weakly; the caller keeps this.
        listener.delegate = self
        listener.resume()
    }

    /// The endpoint of an anonymous listener, for tests.
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    /// Stops accepting clients.
    func invalidate() {
        listener.invalidate()
    }

    nonisolated public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DaemonControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    nonisolated public func status(reply: @escaping @Sendable (DaemonStatusMessage) -> Void) {
        onHandler { reply(DaemonStatusMessage($0.status())) }
    }

    nonisolated public func stop(reply: @escaping @Sendable () -> Void) {
        let connection = NSXPCConnection.current()
        onHandler { handler in
            reply()
            // A stop can exit at once (VM not running yet), so it waits until
            // the reply has left.
            let stop = { DispatchQueue.main.async { MainActor.assumeIsolated { handler.stop() } } }
            guard let connection else { return stop() }
            connection.scheduleSendBarrierBlock(stop)
        }
    }

    nonisolated public func waitUntilReady(reply: @escaping @Sendable (DaemonStatusMessage?) -> Void) {
        onHandler { $0.waitUntilReady { reply($0.map(DaemonStatusMessage.init)) } }
    }

    /// Runs `body` with the handler on the main actor, or drops the calling
    /// connection when the handler is gone.
    private nonisolated func onHandler(_ body: @escaping @MainActor (any ControlHandler) -> Void) {
        let connection = NSXPCConnection.current()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let handler = self.handler else { return connection?.invalidate() ?? () }
                body(handler)
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

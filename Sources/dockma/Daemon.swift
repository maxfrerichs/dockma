import Foundation

/// The long-lived process behind the launchd job: boots the VM and serves the
/// docker socket, port forwards and control socket until asked to stop.
@MainActor
public final class Daemon {
    /// How long the guest gets to power off before the VM is stopped hard.
    static let shutdownGrace: Duration = .seconds(20)
    static let timeSyncInterval: Duration = .seconds(30)

    private let paths: Paths
    private var config = Config()
    private var host: VMHost?
    private var agent: AgentClient?
    private var ports: PortForwarder?
    private var listeners: [SocketListener] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var state: DaemonStatus.State = .starting
    private var stopRequested = false
    private var warnings: [String] = []
    private var lockFD: Int32 = -1
    private let startedAt = Date()

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Starts everything; the caller must then run the main run loop.
    /// Exits the process when the VM stops.
    public func start() {
        // The order matters: a second instance must exit on the lock before
        // it rotates the running daemon's log or touches its sockets.
        do {
            try paths.createDirectories()
            lockFD = try Self.acquireLock(at: paths.daemonLock)
        } catch {
            Log.info("startup failed: \(error)")
            exit(0)
        }

        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.info("received signal \(sig), shutting down")
                    self?.requestStop()
                }
            }
            source.resume()
            signalSources.append(source)
        }

        do {
            try boot()
        } catch {
            // Exit 0 so launchd's KeepAlive doesn't restart a daemon that can't
            // boot; `dockma start` notices the job died and shows this log.
            Log.info("startup failed: \(error)")
            exit(0)
        }
    }

    private func boot() throws {
        try Paths.validateSocketPath(paths.dockerSocket)
        try Paths.validateSocketPath(paths.controlSocket)
        try Paths.validateSocketPath(paths.shellSocket)

        config = try Config.load(from: paths.config)
        try config.validate()
        if config.macAddress == nil {
            config.macAddress = Self.randomMACAddress()
            try config.save(to: paths.config)
        }
        try VMConfigurationBuilder.prepareDataDisk(at: paths.dataDisk, sizeGiB: config.diskGiB)

        let consoleLog = try Self.rotateAndOpen(paths.consoleLog)
        let dockerLog = try Self.rotateAndOpen(paths.dockerLog)
        let built = try VMConfigurationBuilder.build(config: config, paths: paths, consoleLog: consoleLog, dockerLog: dockerLog)
        if let warning = built.rosettaWarning {
            Log.info(warning)
            warnings.append(warning)
        }

        let host = VMHost(configuration: built.configuration)
        host.onStop = { [weak self] error in self?.vmStopped(error: error) }
        self.host = host

        listeners.append(try ControlServer.listen(path: paths.controlSocket.path) { [weak self] request in
            self?.handle(request)
        })

        Log.info("starting VM: \(config.cpus) CPUs, \(config.memoryMiB) MiB, home \(paths.home.path)")
        Task {
            do {
                try await host.start()
            } catch {
                // Like other startup failures: exit 0 so launchd doesn't retry.
                Log.info("VM failed to start: \(error)")
                exit(0)
            }
            self.vmStarted(host)
        }
    }

    private func vmStarted(_ host: VMHost) {
        Log.info("VM running")
        do {
            listeners.append(try VsockSocketProxy.listen(
                path: paths.dockerSocket.path, port: VMConfigurationBuilder.Port.docker, host: host))
            listeners.append(try VsockSocketProxy.listen(
                path: paths.shellSocket.path, port: VMConfigurationBuilder.Port.shell, host: host))
        } catch {
            Log.info("cannot serve sockets: \(error)")
            requestStop()
            return
        }

        let ports = PortForwarder(host: host, bindAddress: config.portBindAddress)
        self.ports = ports
        let agent = AgentClient(host: host)
        agent.onPorts = { [weak self] set in
            guard let self, !self.stopRequested else { return }
            ports.update(set)
        }
        agent.onConnect = { [weak self] in
            guard let self else { return }
            if self.state == .starting { self.state = .running }
            self.agent?.send(.setTime(Date()))
        }
        self.agent = agent
        agent.start()

        // Clocks drift apart while the Mac sleeps; the agent steps the guest
        // clock only when it is off by more than half a second.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.timeSyncInterval)
                guard let self, !self.stopRequested else { return }
                self.agent?.send(.setTime(Date()))
            }
        }
    }

    private func handle(_ request: ControlRequest) -> Data? {
        switch request.command {
        case .status:
            let status = DaemonStatus(
                state: state,
                pid: getpid(),
                startedAt: startedAt,
                cpus: config.cpus,
                memoryMiB: config.memoryMiB,
                agentConnected: agent?.isConnected ?? false,
                agentVersion: agent?.version,
                guestKernel: agent?.kernel,
                forwardedPorts: ports?.ports ?? [],
                warnings: warnings)
            return try? JSONEncoder().encode(status)
        case .stop:
            requestStop()
            return Data("{}".utf8)
        }
    }

    /// Graceful shutdown: ask the agent to power off (fall back to the virtual
    /// power button), then hard-stop after the grace period.
    public func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        state = .stopping
        // New connections are refused from here on; the agent connection
        // stays open to deliver the shutdown request.
        ports?.removeAll()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()

        guard let host, host.isRunning else {
            exit(0)
        }
        // Without the agent nothing in the guest can act on a shutdown request
        // (the virtual power button needs an input-event handler the minimal
        // guest doesn't run), so only a short grace period is useful.
        var grace = Self.shutdownGrace
        if agent?.send(.shutdown) != true {
            Log.info("agent not connected, stopping VM")
            grace = .seconds(2)
        }
        Task {
            try? await Task.sleep(for: grace)
            Log.info("guest did not power off in time, stopping VM")
            try? await host.forceStop()
            self.cleanup()
            exit(0)
        }
    }

    private func vmStopped(error: Error?) {
        cleanup()
        if let error {
            Log.info("VM stopped with error: \(error)")
            exit(1)
        }
        if stopRequested {
            Log.info("VM stopped")
            exit(0)
        }
        // The guest powered off on its own; exit non-zero so launchd restarts.
        Log.info("guest powered off unexpectedly")
        exit(1)
    }

    private func closeForwarding() {
        ports?.removeAll()
        agent?.stop()
    }

    private func cleanup() {
        closeForwarding()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    /// Keeps one previous log as `<name>.1` and opens a fresh file (mode 0600)
    /// for writing.
    nonisolated static func rotateAndOpen(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        let previous = url.appendingPathExtension("1")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: url, to: previous)
        }
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DockmaError("cannot create \(url.path)")
        }
        return try FileHandle(forWritingTo: url)
    }

    /// Takes an exclusive lock that is held for the life of the process, so a
    /// second daemon (say `dockma daemon` by hand next to the launchd job)
    /// can't boot another VM on the same data disk. Returns the descriptor.
    nonisolated static func acquireLock(at url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno == EWOULDBLOCK
                ? DockmaError("another dockma daemon is running (\(url.path) is locked)")
                : posixError("lock \(url.path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// A random locally administered unicast MAC address.
    nonisolated static func randomMACAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

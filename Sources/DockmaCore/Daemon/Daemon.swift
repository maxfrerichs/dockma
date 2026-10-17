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
    /// `wait` requests to answer once Docker is ready.
    private var readyWaiters: [ControlReply] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var state: DaemonStatus.State = .starting
    private var stopRequested = false
    /// The hard stop that ends the shutdown grace period.
    private var forceStopTask: Task<Void, Never>?
    /// When `requestStop()` ran; the full grace period counts from here.
    private var stopRequestedAt: ContinuousClock.Instant?
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
        Self.redirectOutput(to: paths.daemonLog)
        Log.info("file descriptor limit: \(Self.raiseFileLimit())")

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

        // Listen first: a `dockma start` waiting on this socket then sees
        // every later startup failure as the connection closing.
        listeners.append(try ControlServer.listen(path: paths.controlSocket.path) { [weak self] request, reply in
            guard let self else { return reply.close() }
            self.handle(request, reply: reply)
        })

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

        let ports = PortForwarder(host: host, bindAddress: config.portBindAddress)
        self.ports = ports
        let agent = AgentClient()
        agent.onPorts = { [weak self] set in
            guard let self, !self.stopRequested else { return }
            ports.update(set)
        }
        agent.onConnect = { [weak self] in
            guard let self else { return }
            if self.stopRequested {
                // A stop during boot can come before the agent runs; it can
                // still power the guest off cleanly.
                if self.agent?.send(.shutdown) == true, let stopRequestedAt = self.stopRequestedAt {
                    Log.info("agent connected during stop, asked the guest to power off")
                    // Counted from the stop request, so an agent that keeps
                    // reconnecting can't postpone the hard stop.
                    self.scheduleForceStop(at: stopRequestedAt + Self.shutdownGrace)
                }
                return
            }
            if self.state == .starting { self.state = .running }
            self.agent?.send(.setTime(Date()))
        }
        agent.onDockerReadyChange = { [weak self] ready in
            if ready { self?.answerReadyWaiters() }
        }
        self.agent = agent
        // The agent dials the host as soon as it runs.
        try host.listen(onPort: VMConfigurationBuilder.Port.control) { fd in agent.accept(fd) }

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

    /// Answers a control request, at once or (for `wait`) once Docker is ready.
    private func handle(_ request: ControlRequest, reply: ControlReply) {
        switch request.command {
        case .status:
            sendStatus(to: reply)
        case .stop:
            // requestStop() can exit at once (VM not running yet), so defer it:
            // the reply is written in this same main-actor job, before the
            // queued block can run.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.requestStop() }
            }
            reply.send(Data("{}".utf8))
        case .wait:
            if stopRequested {
                reply.close()
            } else if agent?.isDockerReady == true {
                sendStatus(to: reply)
            } else {
                readyWaiters.append(reply)
            }
        }
    }

    /// Replies with the current `DaemonStatus`.
    private func sendStatus(to reply: ControlReply) {
        let status = DaemonStatus(
            state: state,
            pid: getpid(),
            startedAt: startedAt,
            cpus: config.cpus,
            memoryMiB: config.memoryMiB,
            agentConnected: agent?.isConnected ?? false,
            agentVersion: agent?.version,
            guestKernel: agent?.kernel,
            forwardedPorts: ports?.ports.filter { $0.transport == .tcp }.map(\.port) ?? [],
            forwardedUDPPorts: ports?.ports.filter { $0.transport == .udp }.map(\.port) ?? [],
            warnings: warnings)
        guard let data = try? JSONEncoder().encode(status) else { return reply.close() }
        reply.send(data)
    }

    /// Replies to every pending `wait` request with the current status.
    private func answerReadyWaiters() {
        guard !stopRequested else { return }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach(sendStatus(to:))
    }

    /// Closes pending `wait` requests without a reply.
    private func closeReadyWaiters() {
        readyWaiters.forEach { $0.close() }
        readyWaiters.removeAll()
    }

    /// Graceful shutdown: ask the agent to power off (fall back to the virtual
    /// power button), then hard-stop after the grace period.
    public func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        let now = ContinuousClock.now
        stopRequestedAt = now
        state = .stopping
        // New connections are refused from here on; the agent connection
        // stays open to deliver the shutdown request.
        ports?.removeAll()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        closeReadyWaiters()

        guard let host, host.isRunning else {
            exit(0)
        }
        // Without the agent nothing in the guest can act on a shutdown request
        // (the virtual power button needs an input-event handler the minimal
        // guest doesn't run). A booting guest's agent dials in within about a
        // second and gets the request then (see onConnect); otherwise only a
        // short grace period is useful.
        if agent?.send(.shutdown) == true {
            scheduleForceStop(at: now + Self.shutdownGrace)
        } else {
            Log.info("agent not connected; stopping VM in 2 s unless it connects")
            scheduleForceStop(at: now + .seconds(2))
        }
    }

    /// Hard-stops the VM at `deadline` unless the guest powers off first,
    /// replacing an earlier schedule.
    private func scheduleForceStop(at deadline: ContinuousClock.Instant) {
        guard let host else { return }
        forceStopTask?.cancel()
        forceStopTask = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return  // Rescheduled.
            }
            Log.info("guest did not power off in time, stopping VM")
            try? await host.forceStop()
            self.cleanUp()
            exit(0)
        }
    }

    private func vmStopped(error: Error?) {
        cleanUp()
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

    /// Closes forwarding and every listener.
    private func cleanUp() {
        closeForwarding()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        closeReadyWaiters()
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
        guard fd >= 0 else { throw DockmaError.posix("open \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno == EWOULDBLOCK
                ? DockmaError("another dockma daemon is running (\(url.path) is locked)")
                : DockmaError.posix("lock \(url.path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// launchd appends the daemon's stdout and stderr to daemon.log forever.
    /// Rotate it like the VM logs and point both descriptors at the fresh
    /// file. A daemon run from a terminal keeps writing to the terminal.
    nonisolated static func redirectOutput(to url: URL) {
        guard isatty(STDERR_FILENO) == 0, let handle = try? rotateAndOpen(url) else { return }
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        try? handle.close()
    }

    /// launchd starts jobs with a soft limit of 256 descriptors, and every
    /// proxied connection takes two. Raises the soft limit as far as the
    /// system allows and returns the limit in effect.
    @discardableResult
    nonisolated static func raiseFileLimit() -> UInt64 {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let systemMax = sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0
            ? rlim_t(perProcess) : rlim_t(OPEN_MAX)
        // Darwin may refuse values above OPEN_MAX; fall back to that.
        for target in [min(limit.rlim_max, systemMax), min(limit.rlim_max, rlim_t(OPEN_MAX))] where target > limit.rlim_cur {
            var wanted = limit
            wanted.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &wanted) == 0 { break }
        }
        _ = getrlimit(RLIMIT_NOFILE, &limit)
        return UInt64(limit.rlim_cur)
    }

    /// A random locally administered unicast MAC address.
    nonisolated static func randomMACAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

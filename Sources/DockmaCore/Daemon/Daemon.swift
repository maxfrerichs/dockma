import Foundation
import XPC

/// The long-lived process behind the launchd job: boots the VM and serves the
/// docker socket, port forwards and control service until asked to stop.
@MainActor
public final class Daemon {
    /// How long the guest gets to power off before the VM is stopped hard.
    /// The deadlines must stay ordered: dockerd's own shutdown (15 s with
    /// default container stop timeouts) < the guest shutdown script's wait
    /// (20 s) < this < the plist's `ExitTimeOut` (30 s) < `bootout` (40 s).
    nonisolated static let shutdownGrace: Duration = .seconds(25)
    /// How long a stop waits for an agent that isn't connected to dial in.
    nonisolated static let agentConnectGrace: Duration = .seconds(2)
    static let timeSyncInterval: Duration = .seconds(30)
    /// How often ports that failed to bind are tried again.
    static let portRetryInterval: Duration = .seconds(10)
    /// How often the logs are checked against `maxLogBytes`.
    static let logCheckInterval: Duration = .seconds(60)
    /// The size past which a log is rotated while the daemon runs.
    nonisolated static let maxLogBytes: UInt64 = 10 << 20

    private let paths: Paths
    private var config = Config()
    private var host: VMHost?
    private var agent: AgentClient?
    private var ports: PortForwarder?
    private var files: FileWatcher?
    /// Syncs the guest clock when the Mac wakes.
    private var systemPower: SystemPower?
    private var listeners: [SocketListener] = []
    /// Open until the process exits, so `status` answers `stopping` during a
    /// stop instead of leaving the client waiting.
    private var controlListener: xpc_connection_t?
    /// `wait` requests to answer once Docker is ready.
    private var readyWaiters: [ControlReply] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var state: DaemonStatus.State = .starting
    private var isStopRequested = false
    /// The hard stop that ends the shutdown grace period.
    private var forceStopTask: Task<Void, Never>?
    /// When `requestStop()` ran; the full grace period counts from here.
    private var stopRequestedAt: ContinuousClock.Instant?
    private var warnings: [String] = []
    /// The CPU count and memory the VM got, after VZ's limits.
    private var effectiveCPUs = 0
    private var effectiveMemoryMiB: UInt64 = 0
    private var lockFD: Int32 = -1
    /// Each log the daemon writes and a descriptor that writes to it.
    private var logDescriptors: [(url: URL, fd: Int32)] = []
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
        if Self.redirectOutput(to: paths.daemonLog) {
            logDescriptors.append((paths.daemonLog, STDERR_FILENO))
        }
        Log.info("file descriptor limit: \(Self.raiseFileLimit())")

        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
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
        try Paths.validateSocketPath(paths.shellSocket)

        // Listen first: a `dockma start` waiting on the service then sees
        // every later startup failure as the connection closing.
        controlListener = ControlServer.listen(machService: LaunchAgent.label(for: paths)) { [weak self] request, reply in
            guard let self else { return reply.close() }
            self.handle(request, reply: reply)
        }

        config = try Config.load(from: paths.config)
        try config.validate()
        if config.macAddress == nil {
            config.macAddress = Self.randomMACAddress()
            try config.save(to: paths.config)
        }
        try VMConfigurationBuilder.prepareDataDisk(at: paths.dataDisk, sizeGiB: config.diskGiB)

        let consoleLog = try Self.rotateAndOpen(paths.consoleLog)
        let dockerLog = try Self.rotateAndOpen(paths.dockerLog)
        logDescriptors += [(paths.consoleLog, consoleLog.fileDescriptor), (paths.dockerLog, dockerLog.fileDescriptor)]
        let built = try VMConfigurationBuilder.build(config: config, paths: paths, consoleLog: consoleLog, dockerLog: dockerLog)
        effectiveCPUs = built.configuration.cpuCount
        effectiveMemoryMiB = built.configuration.memorySize >> 20
        if effectiveCPUs != config.cpus || effectiveMemoryMiB != config.memoryMiB {
            let warning = "the VM got \(effectiveCPUs) CPUs and \(effectiveMemoryMiB) MiB (configured: \(config.cpus) CPUs, \(config.memoryMiB) MiB), the limits of Virtualization.framework"
            Log.info(warning)
            warnings.append(warning)
        }
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
            guard let self, !self.isStopRequested else { return }
            ports.update(set)
        }
        let files = FileWatcher(home: paths.home.path)
        self.files = files
        files.onChanges = { [weak self] events in
            guard let self, !self.isStopRequested else { return }
            self.agent?.send(.files(events))
        }
        agent.onWatch = { [weak self] requested in
            guard let self, !self.isStopRequested else { return }
            files.watch(requested)
        }
        agent.onConnect = { [weak self] in
            guard let self else { return }
            if self.isStopRequested {
                // A stop during boot can come before the agent runs; it can
                // still power the guest off cleanly.
                if self.agent?.send(.shutdown) == true, let stopRequestedAt = self.stopRequestedAt {
                    Log.info("agent connected during stop, asked the guest to power off")
                    self.scheduleForceStop(at: Self.forceStopDeadline(requestedAt: stopRequestedAt, isShutdownSent: true))
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

        Log.info("starting VM: \(effectiveCPUs) CPUs, \(effectiveMemoryMiB) MiB, home \(paths.home.path)")
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
        // A stop that came while the VM started has already closed the listeners.
        guard !isStopRequested else { return }
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

        // The guest clock stands still while the Mac sleeps, so it is synced
        // on every wake; the timer catches changes to the host clock. The
        // agent steps the guest clock only when it is off by more than half a second.
        systemPower = SystemPower { [weak self] in
            guard let self, !self.isStopRequested else { return }
            Log.info("Mac woke, syncing the guest clock")
            self.agent?.send(.setTime(Date()))
        }
        if systemPower == nil { Log.info("cannot register for wake notifications; the guest clock may lag up to \(Self.timeSyncInterval) after sleep") }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.timeSyncInterval)
                guard let self, !self.isStopRequested else { return }
                self.agent?.send(.setTime(Date()))
            }
        }

        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.logCheckInterval)
                guard let self, !self.isStopRequested else { return }
                for log in self.logDescriptors { Self.rotate(log.url, ifLargerThan: Self.maxLogBytes, writtenBy: log.fd) }
            }
        }

        // A port held by a Mac process when the container started is
        // forwarded once that process lets go of it.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.portRetryInterval)
                guard let self, !self.isStopRequested else { return }
                if self.ports?.hasFailures == true { self.ports?.retryFailed() }
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
            if isStopRequested {
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
            cpus: effectiveCPUs,
            memoryMiB: effectiveMemoryMiB,
            agentConnected: agent?.isConnected ?? false,
            agentVersion: agent?.version,
            guestKernel: agent?.kernel,
            forwardedPorts: ports?.ports.filter { $0.transport == .tcp }.map(\.port) ?? [],
            forwardedUDPPorts: ports?.ports.filter { $0.transport == .udp }.map(\.port) ?? [],
            warnings: warnings + (ports?.failureWarnings ?? []),
            version: DockmaVersion.current)
        guard let data = try? JSONEncoder().encode(status) else { return reply.close() }
        reply.send(data)
    }

    /// Replies to every pending `wait` request with the current status.
    private func answerReadyWaiters() {
        guard !isStopRequested else { return }
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
        guard !isStopRequested else { return }
        isStopRequested = true
        let now = ContinuousClock.now
        stopRequestedAt = now
        state = .stopping
        // New connections are refused from here on, except control requests
        // (`wait` is closed); the agent connection stays open to deliver the
        // shutdown request.
        closeListeners()

        guard let host, host.isRunning else {
            exit(0)
        }
        // Without the agent nothing in the guest can act on a shutdown request
        // (the virtual power button needs an input-event handler the minimal
        // guest doesn't run). A booting guest's agent dials in within about a
        // second and gets the request then (see onConnect); otherwise only a
        // short grace period is useful.
        let isShutdownSent = agent?.send(.shutdown) == true
        if !isShutdownSent { Log.info("agent not connected; stopping VM in \(Self.agentConnectGrace) unless it connects") }
        scheduleForceStop(at: Self.forceStopDeadline(requestedAt: now, isShutdownSent: isShutdownSent))
    }

    /// When the VM is hard-stopped after a stop requested at `requestedAt`.
    /// Always counted from the request, so an agent that keeps reconnecting
    /// can't postpone the hard stop.
    nonisolated static func forceStopDeadline(
        requestedAt: ContinuousClock.Instant, isShutdownSent: Bool
    ) -> ContinuousClock.Instant {
        requestedAt + (isShutdownSent ? shutdownGrace : agentConnectGrace)
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
        } else if isStopRequested {
            Log.info("VM stopped")
        } else {
            Log.info("guest powered off unexpectedly")
        }
        exit(Self.exitCode(stopRequested: isStopRequested))
    }

    /// The exit code after the VM stopped, which decides whether launchd
    /// restarts the daemon (`KeepAlive.SuccessfulExit=false`): 0 after a
    /// requested stop, even one that ended in a VM error, so `dockma stop`
    /// never brings the VM back; 1 when the guest powered off or the VM
    /// failed on its own. (A guest reboot, including one after a kernel
    /// panic, doesn't stop the VM: VZ restarts it in place.)
    nonisolated static func exitCode(stopRequested: Bool) -> Int32 {
        stopRequested ? 0 : 1
    }

    /// Closes forwarded ports, file watching, every socket listener and
    /// pending `wait` requests.
    private func closeListeners() {
        ports?.removeAll()
        files?.stop()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        closeReadyWaiters()
    }

    /// Closes everything, the agent connection included.
    private func cleanUp() {
        closeListeners()
        agent?.stop()
    }

    /// How many previous logs `rotateAndOpen` keeps, as `<name>.1` (the
    /// newest) to `<name>.3`. More than one, so a crash loop under launchd
    /// doesn't rotate away the log of the first crash at once.
    nonisolated static let keptLogGenerations = 3

    /// Shifts the previous logs to `<name>.1` … `<name>.3`, dropping the
    /// oldest, and opens a fresh file (mode 0600) for writing.
    nonisolated static func rotateAndOpen(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            shiftGenerations(of: url)
            try fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DockmaError.posix("cannot create \(url.path)") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Moves `<name>.1` … `<name>.2` up one generation, dropping the oldest,
    /// so `<name>.1` is free.
    nonisolated static func shiftGenerations(of url: URL) {
        let fm = FileManager.default
        func generation(_ n: Int) -> URL { url.appendingPathExtension(String(n)) }
        try? fm.removeItem(at: generation(keptLogGenerations))
        for n in stride(from: keptLogGenerations - 1, through: 1, by: -1) where fm.fileExists(atPath: generation(n).path) {
            try? fm.moveItem(at: generation(n), to: generation(n + 1))
        }
    }

    /// Rotates `url`, which `fd` writes, once it exceeds `limit` bytes: copies
    /// it to `<name>.1` and truncates it in place. VZ's serial ports write
    /// through copies of the descriptor in its XPC process, so the file can't
    /// be swapped; `rotateAndOpen`'s O_APPEND makes those writes follow the
    /// truncation.
    /// shortcut: lines written between the copy and the truncation are lost;
    /// relay the guest's ports through a pipe if that ever matters.
    nonisolated static func rotate(_ url: URL, ifLargerThan limit: UInt64, writtenBy fd: Int32) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64, size > limit else { return }
        do {
            shiftGenerations(of: url)
            // A clone on APFS, so the window above stays short.
            try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("1"))
            guard ftruncate(fd, 0) == 0 else { throw DockmaError.posix("truncate") }
        } catch {
            Log.info("cannot rotate \(url.lastPathComponent): \(error)")
        }
    }

    /// Takes an exclusive lock that is held for the life of the process, so a
    /// second daemon (say the job of an older dockma next to this one)
    /// can't boot another VM on the same data disk. Returns the descriptor.
    nonisolated static func acquireLock(at url: URL) throws -> Int32 {
        try FileLock.acquire(at: url, busyMessage: "another dockma daemon is running")
    }

    /// launchd appends the daemon's stdout and stderr to daemon.log forever.
    /// Rotate it like the VM logs and point both descriptors at the fresh
    /// file. A daemon run from a terminal keeps writing to the terminal.
    /// Returns whether it redirected.
    @discardableResult
    nonisolated static func redirectOutput(to url: URL) -> Bool {
        guard isatty(STDERR_FILENO) == 0, let handle = try? rotateAndOpen(url) else { return false }
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        try? handle.close()
        return true
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

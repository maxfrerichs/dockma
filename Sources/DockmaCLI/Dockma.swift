import ArgumentParser
import Foundation
import DockmaCore

@main
struct Dockma: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dockma",
        abstract: "Lightweight Docker on macOS",
        version: DockmaVersion.current,
        subcommands: [Start.self, Install.self, Stop.self, Restart.self, Status.self, ShellCommand.self, Logs.self, ConfigCommand.self, Delete.self, DaemonCommand.self])
}

/// Moves this `DOCKMA_HOME` off a job an older dockma started under the
/// default label, saying so when it stopped one.
func migrateLegacyJob(of agent: LaunchAgent) throws {
    if try agent.migrateLegacyJob() {
        print("Stopped this DOCKMA_HOME's job that an older dockma started as \(LaunchAgent.defaultLabel).")
    }
}

/// Shows `title` while slow work runs: on a terminal that can move the
/// cursor as a live panel over the lines appended to `logs`, otherwise as a
/// plain line. Returns the panel, which the caller must finish before
/// printing anything else.
func showProgress(_ title: String, logs: [LogTail], style: TerminalStyle) -> LogPanelRenderer? {
    guard Terminal.rendersEscapes(STDOUT_FILENO) else {
        print(title)
        return nil
    }
    return .standardOutput(title: title, logs: logs, style: style)
}

/// Tails of the guest console and daemon logs, the two that narrate a boot
/// or a shutdown.
func lifecycleLogs(paths: Paths, fromStart: Bool, ignoringPrevious: Bool = false) -> [LogTail] {
    [paths.consoleLog, paths.daemonLog].map { url in
        LogTail(url: url, fromStart: fromStart, ignoringInode: ignoringPrevious ? LogTail.inode(of: url) : nil)
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the VM in the background (via launchd).")

    @Option(help: "Seconds to wait for Docker to answer.")
    var timeout: Int = 90

    /// Starts the daemon and waits until Docker answers, showing the boot log on a terminal.
    func run() throws {
        let paths = Paths.default()
        let agent = LaunchAgent(paths: paths)
        guard FileManager.default.isExecutableFile(atPath: agent.executable) else {
            throw DockmaError("\(agent.executable) is missing; install it next to dockma (`make install`).")
        }
        guard Entitlements.hasVirtualization(executable: agent.executable) else {
            throw DockmaError("""
                \(agent.executable) lacks the \(Entitlements.virtualization) entitlement \
                (a plain `swift build` strips it). Build with `make build` or install with `make install`.
                """)
        }
        try paths.createDirectories()
        let config = try Config.load(from: paths.config)
        try config.validate()
        let style = TerminalStyle.standardOutput()
        // A running VM keeps the guest it booted; `start` leaves it alone.
        if ProcessInfo.processInfo.environment["DOCKMA_NO_AUTO_INSTALL"] != "1",
           GuestImage.needsReleaseInstall(paths: paths, version: DockmaVersion.current),
           agent.state().pid == nil {
            try installReleaseGuest(paths: paths, style: style)
        }
        try GuestImage.validate(paths: paths)

        guard let logs = try loadJob(agent: agent, paths: paths, config: config, style: style) else { return }

        let startedAt = ContinuousClock.now
        let deadline = startedAt + .seconds(timeout)
        let progress = showProgress("Starting dockma…", logs: logs, style: style)
        // Erases the panel before an error propagates and is printed.
        defer { progress?.finish() }
        let errorStyle = TerminalStyle.standardError()
        do {
            switch ControlClient.waitUntilReady(paths: paths, timeout: deadline - .now) {
            case .ready:
                // The daemon serves the docker socket before Docker can be
                // ready; this checks the whole path once.
                guard DockerPing.isResponding(socketPath: paths.dockerSocket.path) else {
                    throw DockmaError("the daemon reported Docker ready, but \(paths.dockerSocket.path) doesn't answer")
                }
            case .closed:
                // A refused signature also closes the connection.
                if agent.state().pid != nil {
                    throw DockmaError("""
                        the running dockma daemon doesn't answer this CLI: it predates it, \
                        or one of their signatures doesn't match; run `dockma restart`
                        """)
                }
                throw StartFailure.daemonExited
            case .stopping:
                throw DockmaError("dockma was stopped while it was starting")
            case .exited:
                throw StartFailure.daemonExited
            case .timedOut:
                throw StartFailure.timedOut
            }
        } catch StartFailure.daemonExited {
            // A daemon that failed leaves its job loaded. A `dockma stop`
            // unloads it, and before the VM runs the daemon exits too soon for
            // its nil `wait` reply to arrive.
            guard agent.state().isLoaded else { throw DockmaError("dockma was stopped while it was starting") }
            // launchd would start the job again for the request still queued
            // on its service; unloading drops both.
            try? agent.bootout()
            progress?.finish()
            Terminal.printError(errorStyle.failure("The dockma daemon exited during startup. Its log:"))
            if let log = LogTail.lastLines(of: paths.daemonLog, count: 15) { Terminal.printError(log) }
            throw ExitCode.failure
        } catch StartFailure.timedOut {
            progress?.finish()
            Terminal.printError(errorStyle.failure("Docker did not answer within \(timeout)s. Last console output:"))
            if let log = LogTail.lastLines(of: paths.consoleLog, count: 20) { Terminal.printError(log) }
            throw ExitCode.failure
        }
        progress?.finish()
        print(style.success("Docker engine is ready") + " " + style.dim("(\(TerminalText.seconds(.now - startedAt)))"))
        print("  Socket: \(paths.dockerSocket.path)")
        // The `dockma` context belongs to the default state directory.
        if paths.isDefaultRoot, let note = DockerContext.ensure(paths: paths) { print("  " + note) }
        if let hint = DockerContext.hint(paths: paths) { print("  " + hint) }
    }

    /// Replaces a stopping or dead job with a freshly loaded one. Returns the
    /// logs that narrate the boot, or nil when dockma is already running.
    private func loadJob(agent: LaunchAgent, paths: Paths, config: Config, style: TerminalStyle) throws -> [LogTail]? {
        try migrateLegacyJob(of: agent)
        var job = agent.state()
        if job.isLoaded, job.pid != nil {
            if DockerPing.isResponding(socketPath: paths.dockerSocket.path) {
                print(style.success("dockma is already running"))
                return nil
            }
            if (try? ControlClient.status(paths: paths))?.state == .stopping {
                print("Waiting for the previous VM to stop…")
                try agent.bootout()
                job = agent.state()
            }
        }
        if job.isLoaded && job.pid == nil {
            // Left over from a failed start or a crash; reload the plist.
            try agent.bootout()
            job = agent.state()
        }
        if job.isLoaded {
            // A daemon that is already booting has rotated its logs.
            return lifecycleLogs(paths: paths, fromStart: true)
        }
        // Until the new daemon rotates them, the logs are the previous run's;
        // snapshot them before it can.
        let logs = lifecycleLogs(paths: paths, fromStart: true, ignoringPrevious: true)
        try agent.install(autostart: config.autostart)
        return logs
    }

    /// Why `start` gave up waiting.
    private enum StartFailure: Error {
        case daemonExited
        case timedOut
    }
}

/// Downloads, verifies and installs the release guest of this dockma
/// version, printing what it does.
func installReleaseGuest(paths: Paths, style: TerminalStyle) throws {
    let version = DockmaVersion.current
    let baseURL = GuestRelease.baseURL(version: version, environment: ProcessInfo.processInfo.environment)
    print("Downloading dockma-linux \(version)…")
    // Before curl's progress bar or an error reaches stderr.
    fflush(stdout)
    do {
        try GuestRelease.install(version: version, from: baseURL, paths: paths,
                                 showsProgress: isatty(STDERR_FILENO) == 1)
    } catch let error as DockmaError {
        throw DockmaError("""
            \(error.description)
            If this dockma was built from source, install its guest with `make guest install-guest` instead.
            """)
    }
    print(style.success("Installed dockma-linux \(version)") + " in \(paths.guest.path)")
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the Linux guest (dockma-linux) of this version into ~/.dockma/guest.",
        discussion: """
            Fetches dockma-linux-<version>-arm64.tar.gz from the GitHub release that matches \
            `dockma --version`, checks it against the release's SHA256SUMS and replaces the \
            installed guest. DOCKMA_RELEASE_URL points it at another directory of release assets.
            """)

    /// Downloads, verifies and installs the guest of this dockma version.
    func run() throws {
        let paths = Paths.default()
        let style = TerminalStyle.standardOutput()
        try installReleaseGuest(paths: paths, style: style)
        if LaunchAgent(paths: paths).state().pid != nil {
            print("  The running VM keeps its current guest until `dockma restart`.")
        } else {
            print("  Start it with `dockma start`.")
        }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut the VM down gracefully.")

    /// Stops the launchd job, showing the shutdown log on a terminal.
    func run() throws {
        let paths = Paths.default()
        let style = TerminalStyle.standardOutput()
        let agent = LaunchAgent(paths: paths)
        if try agent.migrateLegacyJob() {
            print(style.success("dockma stopped") + " (a job an older dockma started as \(LaunchAgent.defaultLabel))")
            return
        }
        if agent.state().isLoaded {
            let startedAt = ContinuousClock.now
            // Stopping doesn't rotate the logs; only new lines matter.
            let progress = showProgress("Stopping dockma…", logs: lifecycleLogs(paths: paths, fromStart: false), style: style)
            defer { progress?.finish() }
            try agent.bootout()
            progress?.finish()
            print(style.success("dockma stopped") + " " + style.dim("(\(TerminalText.seconds(.now - startedAt)))"))
        } else {
            print("dockma is not running")
        }
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop and start the VM.")

    @Option(help: "Seconds to wait for Docker to answer.")
    var timeout: Int = 90

    func run() throws {
        try Stop().run()
        // Parse rather than init: option wrappers of a default-constructed
        // command are not initialized.
        try Start.parse(["--timeout", String(timeout)]).run()
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the VM is running.")

    @Flag(help: "Print JSON.")
    var json = false

    /// Prints the daemon's status, in JSON with `--json`.
    func run() throws {
        let paths = Paths.default()
        let style = TerminalStyle.standardOutput()
        let answer: DaemonStatus?
        do {
            answer = try ControlClient.status(paths: paths)
        } catch {
            if json {
                print(#"{"state":"unknown"}"#)
            } else {
                print("dockma is running, but its daemon doesn't answer this CLI: it is another version, or their signatures don't match")
                print(style.dim("Run `dockma restart` to switch to this CLI's version."))
            }
            return
        }
        guard let status = answer else {
            if json {
                print(#"{"state":"stopped"}"#)
            } else {
                print("dockma is stopped")
                print(style.dim("Start it with `dockma start`."))
            }
            return
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(status), as: UTF8.self))
            return
        }
        let dockerUp = DockerPing.isResponding(socketPath: paths.dockerSocket.path)
        let uptime = Duration.seconds(Int(Date().timeIntervalSince(status.startedAt)))
        // Color wraps values only: scripts match `state: *running`.
        let state = status.state == .running ? style.green(status.state.rawValue) : style.yellow(status.state.rawValue)
        print("state:    \(state)")
        print("docker:   \(dockerUp ? style.green("ready") : style.red("not answering")) \(style.dim("(\(paths.dockerSocket.path))"))")
        print("uptime:   \(uptime.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
        print("vm:       \(status.cpus) CPUs, \(status.memoryMiB) MiB, kernel \(status.guestKernel ?? "?")")
        let agentState = status.agentConnected ? style.green("connected") : style.red("disconnected")
        print("agent:    \(agentState) \(style.dim(status.agentVersion ?? ""))")
        let ports = status.forwardedPortKeys
        print("ports:    \(ports.isEmpty ? style.dim("none") : ports.map(\.description).joined(separator: ", "))")
        print("daemon:   pid \(status.pid) \(style.dim(status.version ?? ""))")
        if status.version != DockmaVersion.current {
            print("warning:  \(style.yellow("the daemon runs \(status.version.map { "dockma \($0)" } ?? "an older dockma"), this CLI is \(DockmaVersion.current); run `dockma restart` to switch"))")
        }
        if case .release(let version) = GuestImage.origin(paths: paths), version != DockmaVersion.current {
            print("warning:  \(style.yellow("the guest is from dockma \(version), this CLI is \(DockmaVersion.current); run `dockma install`, then `dockma restart`"))")
        }
        for warning in status.warnings { print("warning:  \(style.yellow(warning))") }
        if let hint = DockerContext.hint(paths: paths) { print(hint) }
    }
}

struct ShellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Open a root shell in the VM, or run a command there.",
        discussion: """
            Without a command, opens an interactive login shell. With `-- <command>`, runs \
            the command, passes stdin/stdout/stderr through and exits with its exit code. \
            Works even when dockerd is down.
            """)

    @Flag(name: [.customShort("t"), .customLong("tty")], help: "Force a pseudo-terminal.")
    var forceTTY = false

    @Flag(name: [.customShort("T"), .customLong("no-tty")], help: "Disable the pseudo-terminal.")
    var disableTTY = false

    @Argument(parsing: .postTerminator, help: "Command to run instead of a shell (after --).")
    var command: [String] = []

    func validate() throws {
        if forceTTY && disableTTY { throw ValidationError("choose one of --tty and --no-tty") }
    }

    func run() throws {
        // Like ssh: a terminal for interactive shells, plain pipes for commands.
        let tty = forceTTY || (!disableTTY && command.isEmpty && isatty(STDIN_FILENO) == 1)
        let code = try ShellSession.run(paths: Paths.default(), argv: command, tty: tty)
        if code != 0 { throw ExitCode(code) }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show VM logs (kernel and init by default).")

    @Flag(help: "Show dockerd's log.")
    var docker = false

    @Flag(help: "Show the host daemon's log.")
    var daemon = false

    @Flag(name: .shortAndLong, help: "Keep printing new lines.")
    var follow = false

    @Option(name: [.customShort("n"), .long], help: "Number of lines to show.")
    var lines = 100

    func validate() throws {
        if docker && daemon { throw ValidationError("choose one of --docker and --daemon") }
    }

    /// Prints the chosen log's tail, then follows it with `--follow`.
    func run() throws {
        let paths = Paths.default()
        let url: URL
        if docker {
            url = paths.dockerLog
        } else if daemon {
            url = paths.daemonLog
        } else {
            url = paths.consoleLog
        }
        guard let text = LogTail.lastLines(of: url, count: lines) else {
            throw DockmaError("no log at \(url.path) yet")
        }
        if !text.isEmpty { print(text) }
        if follow { LogFollower(url: url).follow() }
    }
}

/// Polls a log file for appended data. `LogTail` handles the rotation and
/// truncation that happen when the VM restarts.
struct LogFollower {
    let url: URL

    /// Prints what is appended to the log from now on; never returns.
    func follow() -> Never {
        var tail = LogTail(url: url, fromStart: false)
        while true {
            Thread.sleep(forTimeInterval: 0.3)
            while true {
                let data = tail.readAppended()
                if data.isEmpty { break }
                // The reader went away, as with `| head`.
                guard (try? FileHandle.standardOutput.write(contentsOf: data)) != nil else { Foundation.exit(0) }
            }
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change VM settings (applied on the next start).")

    @Option(help: "Number of virtual CPUs.")
    var cpus: Int?

    @Option(help: "Memory in MiB.")
    var memory: UInt64?

    @Option(help: "Data disk size in GiB (can only grow).")
    var disk: UInt64?

    @Option(help: "Host address published ports are bound to: 127.0.0.1 (this Mac only), 0.0.0.0 (all interfaces) or one interface's address.")
    var portBindAddress: String?

    @Option(help: "Run amd64 images with Rosetta (true/false).")
    var rosetta: Bool?

    @Option(help: "Start dockma at login (true/false).")
    var autostart: Bool?

    /// Applies the given settings, saves them and prints the result.
    func run() throws {
        let paths = Paths.default()
        let style = TerminalStyle.standardOutput()
        try paths.createDirectories()
        var config = try Config.load(from: paths.config)
        let before = config
        if let cpus { config.cpus = cpus }
        if let memory { config.memoryMiB = memory }
        if let disk { config.diskGiB = disk }
        if let portBindAddress { config.portBindAddress = portBindAddress }
        if let rosetta { config.rosetta = rosetta }
        if let autostart { config.autostart = autostart }
        try config.validate()
        if config.diskGiB != before.diskGiB, let current = VMConfigurationBuilder.dataDiskSize(at: paths.dataDisk) {
            try VMConfigurationBuilder.checkDataDiskResize(currentBytes: current, toGiB: config.diskGiB)
        }
        let errorStyle = TerminalStyle.standardError()
        if config.cpus != before.cpus || config.memoryMiB != before.memoryMiB {
            for warning in config.resourceWarnings(hostCPUs: ProcessInfo.processInfo.activeProcessorCount,
                                                   hostMemoryBytes: ProcessInfo.processInfo.physicalMemory) {
                Terminal.printError(errorStyle.yellow("warning: ") + warning)
            }
        }
        if config.diskGiB != before.diskGiB,
           let free = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            var info = stat()
            let allocated = stat(paths.dataDisk.path, &info) == 0 ? UInt64(info.st_blocks) * 512 : 0
            if let warning = config.diskWarning(allocatedBytes: allocated, hostFreeBytes: UInt64(max(0, free))) {
                Terminal.printError(errorStyle.yellow("warning: ") + warning)
            }
        }

        if config != before {
            try config.save(to: paths.config)
            if config.autostart != before.autostart {
                // Move the plist between ~/.dockma and ~/Library/LaunchAgents
                // without touching a running job.
                let agent = LaunchAgent(paths: paths)
                if FileManager.default.fileExists(atPath: agent.plistURL(autostart: before.autostart).path) {
                    try agent.writePlist(autostart: config.autostart)
                }
            }
            let isRunning = LaunchAgent(paths: paths).state().pid != nil
            print(style.success("Saved.") + (isRunning ? " Run `dockma restart` to apply." : " Applies on the next `dockma start`."))
        }
        /// `value`, in bold when the setting just changed.
        func show<Value: Equatable>(_ value: Value, _ previous: Value, unit: String = "") -> String {
            let text = "\(value)\(unit)"
            return value == previous ? text : style.bold(text)
        }
        print("cpus:              \(show(config.cpus, before.cpus))")
        print("memory:            \(show(config.memoryMiB, before.memoryMiB, unit: " MiB"))")
        print("disk:              \(show(config.diskGiB, before.diskGiB, unit: " GiB"))")
        print("port bind address: \(show(config.portBindAddress, before.portBindAddress))")
        print("rosetta:           \(show(config.rosetta, before.rosetta))")
        print("autostart:         \(show(config.autostart, before.autostart))")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete the VM's data disk (all images, containers and volumes), config and logs.")

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var force = false

    /// Deletes the data disk, config and logs after confirmation.
    func run() throws {
        let paths = Paths.default()
        let agent = LaunchAgent(paths: paths)
        try migrateLegacyJob(of: agent)
        if agent.state().isLoaded {
            throw DockmaError("dockma is running; run `dockma stop` first")
        }
        if !force {
            print("This deletes all Docker images, containers and volumes in dockma. Continue? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("Aborted.")
                return
            }
        }
        let fm = FileManager.default
        for url in [paths.dataDisk, paths.config, paths.logs] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        agent.removePlists()
        if paths.isDefaultRoot { DockerContext.remove() }
        print(TerminalStyle.standardOutput().success("Deleted dockma's data disk, config and logs."))
        print("  The guest image in \(paths.guest.path) was kept.")
    }
}

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Replaced by dockmad; run `dockma restart`.",
        shouldDisplay: false)

    /// Explains why a job from before `dockmad` stopped. Exits 0, so
    /// launchd doesn't restart the old job in a loop.
    func run() throws {
        print("This launchd job predates dockmad; run `dockma restart` to replace it.")
    }
}

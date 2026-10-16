import ArgumentParser
import Foundation
import dockma

@main
struct Dockma: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dockma",
        abstract: "Docker on macOS through a minimal Linux VM.",
        subcommands: [Start.self, Stop.self, Restart.self, Status.self, ShellCommand.self, Logs.self, ConfigCommand.self, Delete.self, DaemonCommand.self])
}

/// Absolute path of this binary, which launchd runs as the daemon.
func currentExecutable() -> String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Last `count` lines of a file, or nil if it doesn't exist.
func tail(_ url: URL, lines count: Int) -> String? {
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    // The guest consoles are TTYs and write "\r\n", a single Character in
    // Swift, so split on any newline rather than "\n".
    let lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    let trimmed = lines.last == "" ? lines.dropLast() : lines[...]
    return trimmed.suffix(count).joined(separator: "\n")
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the VM in the background (via launchd).")

    @Option(help: "Seconds to wait for Docker to answer.")
    var timeout: Int = 90

    func run() throws {
        guard Entitlements.hasVirtualization() else {
            throw DockmaError("""
                \(currentExecutable()) lacks the \(Entitlements.virtualization) entitlement \
                (a plain `swift build` strips it). Build with `make build` or install with `make install`.
                """)
        }
        let paths = Paths.default()
        try paths.createDirectories()
        let config = try Config.load(from: paths.config)
        try config.validate()
        for url in [paths.kernel, paths.initrd] where !FileManager.default.fileExists(atPath: url.path) {
            throw DockmaError("guest image missing: \(url.path)\nBuild it with `make guest install-guest`.")
        }

        let agent = LaunchAgent(paths: paths, executable: currentExecutable())
        var job = agent.state()
        if job.loaded, job.pid != nil {
            if DockerPing.ping(socketPath: paths.dockerSocket.path) {
                print("dockma is already running")
                return
            }
            if (try? ControlClient.status(paths: paths))?.state == .stopping {
                print("waiting for the previous VM to stop...")
                try agent.bootout()
                job = agent.state()
            }
        }
        if job.loaded && job.pid == nil {
            // Left over from a failed start or a crash; reload the plist.
            try agent.bootout()
            job = agent.state()
        }
        if !job.loaded {
            if (try? ControlClient.status(paths: paths)) != nil {
                print("dockma is already running (started outside launchd with `dockma daemon`)")
                return
            }
            try agent.install(autostart: config.autostart)
        }

        print("starting dockma...")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let jobGraceDeadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if DockerPing.ping(socketPath: paths.dockerSocket.path) {
                print("dockma is running; Docker socket: \(paths.dockerSocket.path)")
                if let note = DockerContext.ensure(paths: paths) { print(note) }
                if let hint = DockerContext.hint(paths: paths) { print(hint) }
                return
            }
            if Date() > jobGraceDeadline, agent.state().pid == nil {
                printErr("the dockma daemon exited during startup:")
                if let log = tail(paths.daemonLog, lines: 15) { printErr(log) }
                throw ExitCode.failure
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        printErr("Docker did not answer within \(timeout)s. Last console output:")
        if let log = tail(paths.consoleLog, lines: 20) { printErr(log) }
        throw ExitCode.failure
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut the VM down gracefully.")

    func run() throws {
        let paths = Paths.default()
        let agent = LaunchAgent(paths: paths, executable: currentExecutable())
        if agent.state().loaded {
            print("stopping dockma...")
            try agent.bootout()
            print("dockma stopped")
        } else if (try? ControlClient.stop(paths: paths)) != nil {
            // A daemon started by hand (`dockma daemon`), not by launchd.
            print("stop requested")
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

    func run() throws {
        let paths = Paths.default()
        guard let status = try? ControlClient.status(paths: paths) else {
            if json {
                print(#"{"state":"stopped"}"#)
            } else {
                print("dockma is stopped")
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
        let dockerUp = DockerPing.ping(socketPath: paths.dockerSocket.path)
        let uptime = Duration.seconds(Int(Date().timeIntervalSince(status.startedAt)))
        print("state:    \(status.state.rawValue)")
        print("docker:   \(dockerUp ? "ready" : "not answering") (\(paths.dockerSocket.path))")
        print("uptime:   \(uptime.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
        print("vm:       \(status.cpus) CPUs, \(status.memoryMiB) MiB, kernel \(status.guestKernel ?? "?")")
        print("agent:    \(status.agentConnected ? "connected" : "disconnected") \(status.agentVersion ?? "")")
        print("ports:    \(status.forwardedPorts.isEmpty ? "none" : status.forwardedPorts.map(String.init).joined(separator: ", "))")
        print("daemon:   pid \(status.pid)")
        for warning in status.warnings { print("warning:  \(warning)") }
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

    func run() throws {
        let paths = Paths.default()
        let url = docker ? paths.dockerLog : daemon ? paths.daemonLog : paths.consoleLog
        guard let text = tail(url, lines: lines) else {
            throw DockmaError("no log at \(url.path) yet")
        }
        if !text.isEmpty { print(text) }
        if follow { try LogFollower(url: url).follow() }
    }
}

/// Polls a log file for appended data. Handles the truncation/rotation that
/// happens when the VM restarts.
struct LogFollower {
    let url: URL

    func follow() throws {
        var offset = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        var inode = Self.inode(url)
        while true {
            Thread.sleep(forTimeInterval: 0.3)
            let currentInode = Self.inode(url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if currentInode != inode || size < offset {
                inode = currentInode
                offset = 0
            }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            try handle.seek(toOffset: offset)
            if let data = try handle.readToEnd() {
                FileHandle.standardOutput.write(data)
                offset += UInt64(data.count)
            }
            try? handle.close()
        }
    }

    static func inode(_ url: URL) -> UInt64? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_ino : nil
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

    @Option(help: "Host address published ports are bound to (127.0.0.1 or 0.0.0.0).")
    var portBindAddress: String?

    @Option(help: "Run amd64 images with Rosetta (true/false).")
    var rosetta: Bool?

    @Option(help: "Start dockma at login (true/false).")
    var autostart: Bool?

    func run() throws {
        let paths = Paths.default()
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

        if config != before {
            try config.save(to: paths.config)
            if config.autostart != before.autostart {
                // Move the plist between ~/.dockma and ~/Library/LaunchAgents
                // without touching a running job.
                let agent = LaunchAgent(paths: paths, executable: currentExecutable())
                let from = agent.plistURL(autostart: before.autostart)
                let to = agent.plistURL(autostart: config.autostart)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try agent.plist(autostart: config.autostart).write(to: to, options: .atomic)
                    try? FileManager.default.removeItem(at: from)
                }
            }
            print("saved; restart dockma to apply (`dockma restart`)")
        }
        print("cpus:              \(config.cpus)")
        print("memory:            \(config.memoryMiB) MiB")
        print("disk:              \(config.diskGiB) GiB")
        print("port bind address: \(config.portBindAddress)")
        print("rosetta:           \(config.rosetta)")
        print("autostart:         \(config.autostart)")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete the VM's data disk (all images, containers and volumes), config and logs.")

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var force = false

    func run() throws {
        let paths = Paths.default()
        let agent = LaunchAgent(paths: paths, executable: currentExecutable())
        if agent.state().loaded || (try? ControlClient.status(paths: paths)) != nil {
            throw DockmaError("dockma is running; run `dockma stop` first")
        }
        if !force {
            print("This deletes all Docker images, containers and volumes in dockma. Continue? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("aborted")
                return
            }
        }
        let fm = FileManager.default
        for url in [paths.dataDisk, paths.config, paths.logs] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        agent.removePlists()
        DockerContext.remove()
        print("deleted dockma data (the guest image in \(paths.guest.path) was kept)")
    }
}

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the VM in the foreground (launchd runs this).",
        shouldDisplay: false)

    func run() throws {
        let daemon = MainActor.assumeIsolated {
            let daemon = Daemon(paths: Paths.default())
            daemon.start()
            return daemon
        }
        // Run the main thread's run loop rather than dispatchMain(): with
        // dispatchMain() main-queue work runs on a worker thread, which breaks
        // @MainActor isolation checks. The port keeps the run loop alive.
        RunLoop.main.add(Port(), forMode: .default)
        withExtendedLifetime(daemon) { RunLoop.main.run() }
    }
}

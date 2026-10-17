import CryptoKit
import Foundation

/// Manages the per-user launchd job that runs `dockma daemon`.
public struct LaunchAgent: Sendable {
    /// The job label of the default state directory. A frozen name: launchd
    /// and installed plists know the job by it.
    public static let defaultLabel = "io.dockma.daemon"

    public let paths: Paths
    public let executable: String
    /// The job's label, distinct per state directory.
    public let label: String

    public init(paths: Paths, executable: String) {
        self.init(paths: paths, executable: executable, label: Self.label(for: paths))
    }

    init(paths: Paths, executable: String, label: String) {
        self.paths = paths
        self.executable = executable
        self.label = label
    }

    /// The label for the job of `paths`: the default label for `~/.dockma`,
    /// and the default label plus a hash of the state directory otherwise, so
    /// a `DOCKMA_HOME` instance never touches the default one's job.
    public static func label(for paths: Paths) -> String {
        guard !paths.isDefaultRoot else { return defaultLabel }
        let digest = SHA256.hash(data: Data(paths.canonicalRootPath.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultLabel).\(hex)"
    }

    /// With autostart the plist lives in ~/Library/LaunchAgents so launchd
    /// loads it at login; otherwise it stays in the state directory.
    public func plistURL(autostart: Bool) -> URL {
        if autostart {
            return paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        }
        return paths.root.appendingPathComponent("\(label).plist")
    }

    /// The daemon exits 0 after a requested shutdown and non-zero when the
    /// VM died unexpectedly, which launchd answers with a restart.
    public func plist(autostart: Bool) throws -> Data {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let custom = ProcessInfo.processInfo.environment["DOCKMA_HOME"] {
            environment["DOCKMA_HOME"] = custom
        }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ExitTimeOut": 30,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": paths.daemonLog.path,
            "StandardErrorPath": paths.daemonLog.path,
            "EnvironmentVariables": environment,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(label)" }

    /// What launchd reports about the dockma job.
    public struct JobState: Equatable, Sendable {
        /// Whether launchd knows the job, running or not.
        public var isLoaded: Bool
        public var pid: Int32?
        /// How often launchd has started the job since it was loaded.
        public var runCount = 0

        /// Whether the job ran and has no process now: it exited, and
        /// launchd may or may not start it again.
        public var hasExited: Bool { !isLoaded || (pid == nil && runCount > 0) }
    }

    /// What launchd reports about the job now. Spawns `launchctl`.
    public func state() -> JobState {
        guard let output = launchctlPrint() else { return JobState(isLoaded: false, pid: nil) }
        return JobState(
            isLoaded: true,
            pid: Self.field("pid", launchctlPrint: output).flatMap { Int32($0) },
            runCount: Self.field("runs", launchctlPrint: output).flatMap { Int($0) } ?? 0)
    }

    /// `launchctl print` output for the job, or nil if launchd doesn't know
    /// it. Spawns `launchctl`.
    func launchctlPrint() -> String? {
        guard let result = try? Subprocess.run("/bin/launchctl", arguments: ["print", service]), result.status == 0 else {
            return nil
        }
        return result.stdout
    }

    /// The pid in `launchctl print` output, if the job has a process.
    static func parsePID(launchctlPrint output: String) -> Int32? {
        field("pid", launchctlPrint: output).flatMap { Int32($0) }
    }

    /// The value of the first top-level `name = value` line.
    static func field(_ name: String, launchctlPrint output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name) = ") {
                return String(trimmed.dropFirst("\(name) = ".count))
            }
        }
        return nil
    }

    /// Writes the plist for the current autostart setting, removes the other
    /// one, and loads the job.
    public func install(autostart: Bool) throws {
        let url = plistURL(autostart: autostart)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(autostart: autostart).write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: plistURL(autostart: !autostart))
        let result = try Subprocess.run("/bin/launchctl", arguments: ["bootstrap", domain, url.path])
        guard result.status == 0 else {
            throw DockmaError("launchctl bootstrap failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Unloads the job and waits until launchd has removed it. launchd sends
    /// SIGTERM, and `launchctl bootout` returns before the daemon has exited.
    public func bootout(timeout: Duration = .seconds(40)) throws {
        let deadline = ContinuousClock.now + timeout
        let pid = state().pid
        // Watch before booting out, so the exit can't be missed.
        let events = try KernelEvents()
        let isWatchingExit = pid.map { events.watchExit(ofProcess: $0) } ?? false
        let result = try Subprocess.run("/bin/launchctl", arguments: ["bootout", service])
        // 3 (ESRCH) / 113: the job is already gone.
        guard result.status == 0 || !state().isLoaded else {
            throw DockmaError("launchctl bootout failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if isWatchingExit, events.wait(timeout: deadline - .now) == nil {
            throw DockmaError("the dockma daemon did not exit within \(timeout)")
        }
        // launchd removes the job shortly after the process exits and sends
        // no event for it, so this checks again until it is gone. With the
        // process gone (exited, or none to begin with) that takes at most a
        // few rounds.
        while state().isLoaded {
            guard ContinuousClock.now < deadline else {
                throw DockmaError("the dockma daemon did not exit within \(timeout)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Moves this `DOCKMA_HOME` off a job that an older dockma loaded for it
    /// under the default label, before labels were per state directory. Its
    /// plists are removed, and the loaded job is booted out only if launchd
    /// loaded it from one of them: a stale plist alone never stops the
    /// default state directory's VM. Returns whether a running job was
    /// booted out. Does nothing for the default state directory.
    @discardableResult
    public func migrateLegacyJob() throws -> Bool {
        guard label != Self.defaultLabel else { return false }
        let legacy = LaunchAgent(paths: paths, executable: executable, label: Self.defaultLabel)
        let owned = [true, false].map { legacy.plistURL(autostart: $0) }.filter { legacy.isPlist($0, ownedBy: paths) }
        guard !owned.isEmpty else { return false }
        var bootedOut = false
        if let print = legacy.launchctlPrint(), Self.isJob(launchctlPrint: print, loadedFromOneOf: owned) {
            try legacy.bootout()
            bootedOut = true
        }
        for url in owned { try? FileManager.default.removeItem(at: url) }
        return bootedOut
    }

    /// Whether `launchctl print` output shows a job loaded from one of
    /// `plists`.
    static func isJob(launchctlPrint output: String, loadedFromOneOf plists: [URL]) -> Bool {
        guard let path = field("path", launchctlPrint: output) else { return false }
        let loaded = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return plists.contains { $0.resolvingSymlinksInPath().path == loaded }
    }

    /// Whether the plist at `url` runs the daemon of the state directory `paths`.
    func isPlist(_ url: URL, ownedBy paths: Paths) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        guard let custom = environment["DOCKMA_HOME"] else { return paths.isDefaultRoot }
        return Paths(root: URL(fileURLWithPath: custom), home: paths.home).canonicalRootPath == paths.canonicalRootPath
    }

    public func removePlists() {
        for autostart in [true, false] {
            try? FileManager.default.removeItem(at: plistURL(autostart: autostart))
        }
    }
}

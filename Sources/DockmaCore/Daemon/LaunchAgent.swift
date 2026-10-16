import Foundation

/// Manages the per-user launchd job that runs `dockma daemon`.
public struct LaunchAgent: Sendable {
    public static let label = "io.dockma.daemon"

    public let paths: Paths
    public let executable: String

    public init(paths: Paths, executable: String) {
        self.paths = paths
        self.executable = executable
    }

    /// With autostart the plist lives in ~/Library/LaunchAgents so launchd
    /// loads it at login; otherwise it stays in the state directory.
    public func plistURL(autostart: Bool) -> URL {
        if autostart {
            return paths.home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        }
        return paths.root.appendingPathComponent("\(Self.label).plist")
    }

    /// The daemon exits 0 after a requested shutdown and non-zero when the
    /// VM died unexpectedly, which launchd answers with a restart.
    public func plist(autostart: Bool) throws -> Data {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let custom = ProcessInfo.processInfo.environment["DOCKMA_HOME"] {
            environment["DOCKMA_HOME"] = custom
        }
        let dict: [String: Any] = [
            "Label": Self.label,
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
    private var service: String { "\(domain)/\(Self.label)" }

    /// What launchd reports about the dockma job.
    public struct JobState: Equatable, Sendable {
        /// Whether launchd knows the job, running or not.
        public var isLoaded: Bool
        public var pid: Int32?
    }

    public func state() -> JobState {
        guard let result = try? Subprocess.run("/bin/launchctl", arguments: ["print", service]), result.status == 0 else {
            return JobState(isLoaded: false, pid: nil)
        }
        return JobState(isLoaded: true, pid: Self.parsePID(launchctlPrint: result.stdout))
    }

    static func parsePID(launchctlPrint output: String) -> Int32? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") {
                return Int32(trimmed.dropFirst("pid = ".count))
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
    public func bootout(timeout: TimeInterval = 40) throws {
        let result = try Subprocess.run("/bin/launchctl", arguments: ["bootout", service])
        // 3 (ESRCH) / 113: the job is already gone.
        guard result.status == 0 || !state().isLoaded else {
            throw DockmaError("launchctl bootout failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while state().isLoaded {
            guard Date() < deadline else {
                throw DockmaError("the dockma daemon did not exit within \(Int(timeout))s")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func removePlists() {
        for autostart in [true, false] {
            try? FileManager.default.removeItem(at: plistURL(autostart: autostart))
        }
    }
}

import Foundation

/// The exit status and captured output of a finished subprocess.
public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs helper programs (launchctl, docker, curl, tar). Unrelated to `dockma shell`.
public enum Subprocess {
    /// Runs `executable` with `arguments` and captures its output. With
    /// `inheritingStandardError`, the child writes to this process's stderr
    /// (for a progress bar) and the result's `stderr` is empty.
    @discardableResult
    public static func run(_ executable: String, arguments: [String], inheritingStandardError: Bool = false) throws -> SubprocessResult {
        let process = Process()
        // waitUntilExit() spins the run loop in slices and added about 70 ms
        // to every call; the termination handler fires on the exit itself.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = inheritingStandardError ? FileHandle.standardError : err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes at once, or a child filling stderr blocks while
        // stdout is read. Its own serial queue, not global(): see the
        // cooperative-pool gotcha in CLAUDE.md.
        nonisolated(unsafe) var stderrData = Data()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue(label: "dockma.subprocess.stderr").async {
            if !inheritingStandardError {
                stderrData = err.fileHandleForReading.readDataToEndOfFile()
            }
            stderrDone.leave()
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        exited.wait()
        return SubprocessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self))
    }

    /// Finds `name` on PATH.
    public static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

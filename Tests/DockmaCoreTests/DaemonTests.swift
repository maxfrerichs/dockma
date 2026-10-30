import Foundation
import Testing
@testable import DockmaCore

@Test func secondDaemonLockFails() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-test-\(UUID().uuidString).lock")
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try Daemon.acquireLock(at: url)
    // flock locks belong to the open file description, so a second open in
    // the same process conflicts just like a second daemon would.
    #expect(throws: DockmaError.self) { _ = try Daemon.acquireLock(at: url) }
    close(first)
    let again = try retryingWhileLockIsHeld { try Daemon.acquireLock(at: url) }
    close(again)
}

@Test func fileLimitIsRaisedAboveLaunchdDefault() throws {
    // Start from launchd's soft limit; the shell's may already be high.
    var limit = rlimit()
    try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
    limit.rlim_cur = 256
    try #require(setrlimit(RLIMIT_NOFILE, &limit) == 0)
    let raised = Daemon.raiseFileLimit()
    #expect(raised >= 10240)
    try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
    #expect(UInt64(limit.rlim_cur) == raised)
}

@Test func onlyARequestedStopExitsZero() {
    // launchd restarts the daemon after a non-zero exit.
    #expect(Daemon.exitCode(stopRequested: true) == 0)
    #expect(Daemon.exitCode(stopRequested: false) == 1)
}

@Test func rotationKeepsThreePreviousLogs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-logs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("daemon.log")
    for run in 1...5 {
        let handle = try Daemon.rotateAndOpen(log)
        try handle.write(contentsOf: Data("run \(run)".utf8))
        try handle.close()
    }
    func contents(_ url: URL) -> String? { FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } }
    #expect(contents(log) == "run 5")
    #expect(contents(log.appendingPathExtension("1")) == "run 4")
    #expect(contents(log.appendingPathExtension("3")) == "run 2")
    #expect(contents(log.appendingPathExtension("4")) == nil)
}

@Test func forceStopIsCountedFromTheStopRequest() {
    let requested = ContinuousClock.now
    #expect(Daemon.forceStopDeadline(requestedAt: requested, isShutdownSent: true) == requested + Daemon.shutdownGrace)
    #expect(Daemon.forceStopDeadline(requestedAt: requested, isShutdownSent: false) == requested + .seconds(2))
}

@Test func shutdownGraceEndsBeforeLaunchdKillsTheDaemon() throws {
    let paths = Paths(root: URL(fileURLWithPath: "/tmp/dockma-plist"), home: URL(fileURLWithPath: "/tmp"))
    let data = try LaunchAgent(paths: paths, executable: "/bin/dockmad").plist(autostart: false)
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let exitTimeOut = try #require(plist["ExitTimeOut"] as? Int)
    #expect(Daemon.shutdownGrace < .seconds(exitTimeOut))
}

@Test func largeLogIsCopiedAndTruncatedInPlace() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-logs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("console.log")
    let writer = try Daemon.rotateAndOpen(log)
    defer { try? writer.close() }
    try writer.write(contentsOf: Data("old".utf8))
    // Another writer of the same open file, like VZ's XPC process.
    let other = FileHandle(fileDescriptor: dup(writer.fileDescriptor), closeOnDealloc: true)
    defer { try? other.close() }
    Daemon.rotate(log, ifLargerThan: 10, writtenBy: writer.fileDescriptor)
    #expect(!FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
    Daemon.rotate(log, ifLargerThan: 2, writtenBy: writer.fileDescriptor)
    try other.write(contentsOf: Data("new".utf8))
    #expect(FileManager.default.contents(atPath: log.path) == Data("new".utf8))
    #expect(FileManager.default.contents(atPath: log.appendingPathExtension("1").path) == Data("old".utf8))
}

@Test func sleepMessagesAreAllowedAndWakeIsForwarded() {
    // iokit_common_msg() values from IOMessage.h.
    #expect(SystemPower.action(for: 0xE000_0270) == .allowSleep) // kIOMessageCanSystemSleep
    #expect(SystemPower.action(for: 0xE000_0280) == .allowSleep) // kIOMessageSystemWillSleep
    #expect(SystemPower.action(for: 0xE000_0300) == .wake) // kIOMessageSystemHasPoweredOn
    // kIOMessageSystemWillPowerOn is sent before the wake completes.
    #expect(SystemPower.action(for: 0xE000_0320) == .ignore)
}

@MainActor @Test func powerObserverRegistersAndDeregisters() throws {
    var power = SystemPower {}
    try #require(power != nil)
    weak let released = power
    // On the main actor, the isolated deinit runs as the last reference goes.
    power = nil
    #expect(released == nil)
}

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
    let again = try Daemon.acquireLock(at: url)
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

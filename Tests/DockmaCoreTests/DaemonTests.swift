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

import Foundation
import Testing
@testable import dockma

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

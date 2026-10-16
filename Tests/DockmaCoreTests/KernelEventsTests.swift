import Foundation
import Testing
@testable import DockmaCore

@Test func kernelEventsSeeProcessExit() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["0.1"]
    try process.run()
    let events = try KernelEvents()
    #expect(events.watchExit(ofProcess: process.processIdentifier))
    #expect(events.wait(timeout: .seconds(5)) == .processExited)
    process.waitUntilExit()
    // Reaped: nothing left to watch.
    #expect(events.watchExit(ofProcess: process.processIdentifier) == false)
}

@Test func kernelEventsSeeDirectoryEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let events = try KernelEvents()
    try events.watchWrites(toDirectory: dir)
    #expect(events.wait(timeout: .milliseconds(50)) == nil)
    try Data().write(to: dir.appendingPathComponent("control.sock"))
    #expect(events.wait(timeout: .seconds(5)) == .directoryChanged)
}

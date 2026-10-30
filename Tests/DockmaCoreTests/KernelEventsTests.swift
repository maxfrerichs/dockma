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

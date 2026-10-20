import Foundation
import Testing
@testable import DockmaCore

/// A fresh directory under the per-user temporary directory.
private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Appends `text` to the file at `url`.
private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// `data` decoded as UTF-8.
private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func tailReadsOnlyAppendedBytes() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("console.log")
    try Data("old\n".utf8).write(to: url)

    var fromEnd = LogTail(url: url, fromStart: false)
    var fromStart = LogTail(url: url, fromStart: true)
    #expect(fromEnd.readAppended().isEmpty)
    #expect(string(fromStart.readAppended()) == "old\n")
    try append("new\n", to: url)
    #expect(string(fromEnd.readAppended()) == "new\n")
    #expect(string(fromStart.readAppended()) == "new\n")
    #expect(fromEnd.readAppended().isEmpty)
}

@Test func tailRestartsAfterTruncationAndRotation() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("console.log")
    try Data("first boot\n".utf8).write(to: url)
    var tail = LogTail(url: url, fromStart: false)

    try Data("a\n".utf8).write(to: url)  // Shorter: truncated and rewritten.
    #expect(string(tail.readAppended()) == "a\n")

    // Rotated like Daemon.rotateAndOpen: moved aside, then a fresh file.
    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
    try Data("second boot, longer than before\n".utf8).write(to: url)
    #expect(string(tail.readAppended()) == "second boot, longer than before\n")
}

@Test func tailSkipsThePreviousRunsLogUntilRotated() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("daemon.log")
    try Data("VM stopped\n".utf8).write(to: url)

    var tail = LogTail(url: url, fromStart: true, ignoringInode: LogTail.inode(of: url))
    #expect(tail.readAppended().isEmpty)
    try append("written before the rotation\n", to: url)
    #expect(tail.readAppended().isEmpty)

    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
    try Data("starting VM\n".utf8).write(to: url)
    #expect(string(tail.readAppended()) == "starting VM\n")
}

@Test func tailOfMissingFileWaitsForIt() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("console.log")
    #expect(LogTail.inode(of: url) == nil)
    var tail = LogTail(url: url, fromStart: false)
    #expect(tail.readAppended().isEmpty)
    try Data("booted\n".utf8).write(to: url)
    #expect(string(tail.readAppended()) == "booted\n")
}

@Test func rendererFinishesPromptlyAndErasesThePanel() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("console.log")
    try Data("dockma: [0.33] boot complete\r\n".utf8).write(to: url)

    let output = OutputCollector()
    // finish() must wake the render thread, not wait out this interval.
    let renderer = LogPanelRenderer(
        title: "Starting dockma…", logs: [LogTail(url: url, fromStart: true)],
        style: TerminalStyle(isEnabled: false), frameInterval: .seconds(60), write: output.append)
    // The first frame is drawn before the render thread first sleeps.
    let deadline = ContinuousClock.now + .seconds(5)
    while !output.text.contains("boot complete") {
        try #require(ContinuousClock.now < deadline, "the first frame wasn't drawn")
        Thread.sleep(forTimeInterval: 0.005)
    }
    let elapsed = ContinuousClock().measure { renderer.finish() }
    #expect(elapsed < .seconds(5))
    #expect(output.text.hasSuffix("\u{1B}[2F\u{1B}[J"))
    renderer.finish()  // A second call returns at once.
}

/// Thread-safe accumulator for a renderer's output.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    /// Everything written so far.
    var text: String { lock.withLock { chunks.joined() } }

    /// Records `chunk`.
    func append(_ chunk: String) { lock.withLock { chunks.append(chunk) } }
}

@Test func lastLinesSplitsTheConsolesCRLF() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("console.log")
    try Data("a\r\nb\r\nc\r\n".utf8).write(to: url)
    #expect(LogTail.lastLines(of: url, count: 2) == "b\nc")
    #expect(LogTail.lastLines(of: url, count: 10) == "a\nb\nc")
    #expect(LogTail.lastLines(of: dir.appendingPathComponent("missing.log"), count: 2) == nil)
}

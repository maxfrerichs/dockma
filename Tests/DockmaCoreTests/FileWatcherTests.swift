import CoreServices
import Foundation
import Testing
@testable import DockmaCore

private func status(mtime: Int, nanos: Int, size: Int64) -> stat {
    var st = stat()
    st.st_mtimespec = timespec(tv_sec: mtime, tv_nsec: nanos)
    st.st_size = size
    return st
}

private func flags(_ values: Int...) -> FSEventStreamEventFlags {
    FSEventStreamEventFlags(values.reduce(0, |))
}

@Test func fsEventsFlagsAndStateMapToFileEvents() {
    let present = status(mtime: 1_793_102_875, nanos: 233_538_782, size: 42)
    let created = FileWatcher.event(path: "/a", flags: flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsFile), status: present)
    #expect(created == FileEvent(op: .created, path: "/a", mtimeNanos: 1_793_102_875_233_538_782, size: 42))
    // Renamed in: the new name is there.
    #expect(FileWatcher.event(path: "/a", flags: flags(kFSEventStreamEventFlagItemRenamed), status: present).op == .created)
    #expect(FileWatcher.event(path: "/a", flags: flags(kFSEventStreamEventFlagItemModified), status: present).op == .modified)
    #expect(FileWatcher.event(path: "/a", flags: flags(kFSEventStreamEventFlagItemInodeMetaMod), status: present).op == .modified)
    // Renamed away, removed, or created and removed before the callback: gone now.
    for gone in [flags(kFSEventStreamEventFlagItemRenamed), flags(kFSEventStreamEventFlagItemRemoved),
                 flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved)] {
        #expect(FileWatcher.event(path: "/a", flags: gone, status: nil) == FileEvent(op: .deleted, path: "/a"))
    }
    // Removed and created again before the callback: present, so new.
    #expect(FileWatcher.event(path: "/a", flags: flags(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemCreated), status: present).op == .created)
}

@Test func batchesStayUnderTheLineLimit() throws {
    let events = (0..<2000).map { FileEvent(op: .modified, path: "/Users/me/src/node_modules/pkg-\($0)/index.js", mtimeNanos: 1_793_102_875_233_538_782, size: 4096) }
    let batches = FileWatcher.batches(events)
    #expect(batches.count > 1)
    #expect(batches.flatMap { $0 } == events)
    for batch in batches {
        #expect(try jsonLine(AgentMessage.files(batch)).count <= FileWatcher.maxLineBytes)
    }
    #expect(FileWatcher.batches([]).isEmpty)
}

@MainActor
@Test func watcherReportsChangesMadeBelowAWatchedPath() async throws {
    // FSEvents reports real paths, /private/var and not /var; resolvingSymlinksInPath() strips /private.
    let real = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(real) }
    let base = URL(fileURLWithPath: String(cString: real))
    let dir = base.appendingPathComponent("dockma-filewatcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }

    let watcher = FileWatcher(home: base.path)
    var events: [FileEvent] = []
    watcher.onChanges = { events += $0 }
    watcher.watch([dir.path])
    defer { watcher.stop() }
    // FSEvents watches from "now"; give the stream a moment to start.
    try await Task.sleep(for: .milliseconds(200))

    let file = dir.appendingPathComponent("a.txt")
    try Data("hello".utf8).write(to: file)
    let deadline = ContinuousClock.now + .seconds(5)
    while !events.contains(where: { $0.path == file.path && $0.op == .created }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    let event = try #require(events.first { $0.path == file.path && $0.op == .created })
    #expect(event.size == 5)
}

/// The guest names the paths; only real paths in home may be watched.
@Test func watchedPathsMustLieInHome() throws {
    let real = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(real) }
    let outside = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("dockma-allowed-\(UUID().uuidString)")
    let home = outside.appendingPathComponent("home")
    let fm = FileManager.default
    try fm.createDirectory(at: home.appendingPathComponent("src"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside.appendingPathComponent("secret"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside.appendingPathComponent("home-other"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: home.appendingPathComponent("escape").path, withDestinationPath: outside.appendingPathComponent("secret").path)
    try fm.createSymbolicLink(atPath: home.appendingPathComponent("inside").path, withDestinationPath: home.appendingPathComponent("src").path)
    defer { try? fm.removeItem(at: outside) }

    let src = home.appendingPathComponent("src").path
    let allowed = FileWatcher.allowedPaths([
        "/",
        src,
        home.path,
        home.path + "/../secret",          // .. out of home
        home.path + "/escape",             // a symlink out of home
        home.path + "/inside",             // a symlink within home: kept, resolved
        outside.path + "/home-other",      // shares home's name as a prefix
        home.path + "/missing",
    ], home: home.path)
    #expect(allowed == [home.path, src])

    #expect(FileWatcher.allowedPaths([src, src, home.path + "/inside"], home: home.path) == [src])
    let many = try (0...FileWatcher.maxPaths).map { i in
        let dir = home.appendingPathComponent("many/\(i)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
    #expect(FileWatcher.allowedPaths(many, home: home.path).count == FileWatcher.maxPaths)
}

import Foundation
import Testing
@testable import DockmaCore

private let version = "9.9.9"

/// A temporary state directory and a release directory served over `file://`.
private struct Fixture {
    let root: URL
    let paths: Paths
    let release: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-release-test-\(UUID().uuidString)")
        paths = Paths(root: root.appendingPathComponent("state"), home: root)
        release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    }

    /// Packs `contents` (name → file bytes, or nil for a symlink) into the
    /// release tarball and lists it in SHA256SUMS, with `checksum` if given.
    func publish(_ contents: [String: String?], checksum: String? = nil, listed: Bool = true) throws {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, body) in contents {
            let url = source.appendingPathComponent(name)
            if let body {
                try Data(body.utf8).write(to: url)
            } else {
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/etc/hosts")
            }
        }
        let asset = GuestRelease.assetName(version: version)
        let archive = release.appendingPathComponent(asset)
        let tar = try Subprocess.run("/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path] + contents.keys.sorted())
        #expect(tar.status == 0, "\(tar.stderr)")
        let hash = try checksum ?? GuestRelease.sha256(of: archive)
        let sums = listed ? "\(hash)  \(asset)\n" : "\(hash)  dockma-0.0.0-macos-arm64.tar.gz\n"
        try Data(sums.utf8).write(to: release.appendingPathComponent("SHA256SUMS"))
    }

    /// Installs from the fixture's release directory. By default it waits out
    /// the lock of an install that just finished, which another test's
    /// subprocess can hold for a moment (`retryingWhileLockIsHeld(_:)`).
    func install(waitingForLock: Bool = true) throws {
        let install = { try GuestRelease.install(version: version, from: release, paths: paths) }
        try waitingForLock ? retryingWhileLockIsHeld(install) : install()
    }

    /// The installed guest's files and their contents.
    func installedGuest() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: paths.guest.path) {
            result[name] = String(decoding: try Data(contentsOf: paths.guest.appendingPathComponent(name)), as: UTF8.self)
        }
        return result
    }

    /// Whether a staging directory was left in the state directory.
    func hasStaging() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path).contains { $0.hasPrefix(".guest-install-") }
    }
}

private let validGuest: [String: String?] = [
    "Image": "kernel", "initramfs.cpio.lz4": "initramfs", "guest-protocol": "\(GuestImage.protocolVersion)\n",
]

@Test func checksumParsesTextAndBinaryMode() {
    let sums = """
        aaaa  dockma-linux-1.0.0-arm64.tar.gz.sig
        BBBB *dockma-1.0.0-macos-arm64.tar.gz
        cccc  dockma-linux-1.0.0-arm64.tar.gz
        """
    #expect(GuestRelease.checksum(of: "dockma-linux-1.0.0-arm64.tar.gz", in: sums) == "cccc")
    #expect(GuestRelease.checksum(of: "dockma-1.0.0-macos-arm64.tar.gz", in: sums) == "bbbb")
    #expect(GuestRelease.checksum(of: "linux-1.0.0-arm64.tar.gz", in: sums) == nil)
}

@Test func releaseURLDefaultsToGitHubAndCanBeOverridden() {
    #expect(GuestRelease.assetName(version: "0.5.0") == "dockma-linux-0.5.0-arm64.tar.gz")
    #expect(GuestRelease.baseURL(version: "0.5.0", environment: [:]).absoluteString
        == "https://github.com/maxfrerichs/dockma/releases/download/0.5.0/")
    #expect(GuestRelease.baseURL(version: "0.5.0", environment: ["DOCKMA_RELEASE_URL": "file:///tmp/rel"]).absoluteString
        == "file:///tmp/rel")
    #expect(GuestRelease.baseURL(version: "0.5.0", environment: ["DOCKMA_RELEASE_URL": "/tmp/rel"]).absoluteString
        == "file:///tmp/rel/")
}

@Test func installRemovesLeftoversOfKilledInstalls() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.paths.createDirectories()
    let leftover = fixture.paths.root.appendingPathComponent("\(GuestRelease.stagingPrefix)LEFTOVER")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
    try Data("partial".utf8).write(to: leftover.appendingPathComponent(GuestRelease.assetName(version: version)))
    try fixture.publish(validGuest)
    try fixture.install()
    #expect(try !fixture.hasStaging())
    #expect(FileManager.default.fileExists(atPath: fixture.paths.guestInstallLock.path))
}

@Test func concurrentInstallIsRefused() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.paths.createDirectories()
    try fixture.publish(validGuest)
    // flock locks belong to the open file, so a second open conflicts even
    // within one process. O_CLOEXEC, like the real lock, keeps a subprocess
    // from holding it for its whole life, though not for the moment it is
    // spawned; the install after close() waits that out.
    let fd = open(fixture.paths.guestInstallLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let error = #expect(throws: DockmaError.self) { try fixture.install(waitingForLock: false) }
    #expect(error?.description.contains("another `dockma install` is running") == true)
    close(fd)
    try fixture.install()
    #expect(try fixture.installedGuest() == validGuest.compactMapValues { $0 })
}

@Test func installsIntoAnEmptyStateDirectory() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.publish(validGuest)
    try fixture.install()
    #expect(try fixture.installedGuest() == validGuest.compactMapValues { $0 })
    #expect(try !fixture.hasStaging())
    try GuestImage.validate(paths: fixture.paths)
}

@Test func replacesAnInstalledGuest() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.publish(["Image": "old", "initramfs.cpio.lz4": "old", "guest-protocol": "\(GuestImage.protocolVersion)\n"])
    try fixture.install()
    try fixture.publish(validGuest)
    try fixture.install()
    #expect(try fixture.installedGuest() == validGuest.compactMapValues { $0 })
    #expect(try !fixture.hasStaging())
}

@Test func rejectedReleasesLeaveTheInstalledGuestAlone() throws {
    let older = "\(GuestImage.protocolVersion - 1)\n"
    let cases: [(String, String, (Fixture) throws -> Void)] = [
        ("hash mismatch", "doesn't match its SHA256SUMS", { try $0.publish(validGuest, checksum: String(repeating: "0", count: 64)) }),
        ("not in SHA256SUMS", "has no entry", { try $0.publish(validGuest, listed: false) }),
        ("extra entry", "holds", { try $0.publish(validGuest.merging(["extra": "x"]) { a, _ in a }) }),
        ("missing entry", "holds", { try $0.publish(validGuest.filter { $0.key != "guest-protocol" }) }),
        ("symlink", "not a regular file", { try $0.publish(validGuest.merging(["Image": nil]) { _, b in b }) }),
        ("wrong protocol", "speaks guest protocol", { try $0.publish(validGuest.merging(["guest-protocol": older]) { _, b in b }) }),
        ("missing asset", "couldn't download", { fixture in
            try fixture.publish(validGuest)
            try FileManager.default.removeItem(at: fixture.release.appendingPathComponent(GuestRelease.assetName(version: version)))
        }),
    ]
    for (name, message, publish) in cases {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installed = ["Image": "kept", "initramfs.cpio.lz4": "kept", "guest-protocol": "\(GuestImage.protocolVersion)\n"]
        try fixture.publish(installed)
        try fixture.install()
        try publish(fixture)
        let error = #expect(throws: DockmaError.self, "\(name)") { try fixture.install() }
        #expect(error?.description.contains(message) == true, "\(name): \(error?.description ?? "")")
        #expect(try fixture.installedGuest() == installed, "\(name)")
        #expect(try !fixture.hasStaging(), "\(name)")
    }
}

/// More callers than CPUs block in `Subprocess.run` at once, as the install
/// tests do on a small CI runner. Every cooperative thread is then blocked,
/// and the run must still finish: its stderr drain can't need another
/// thread from the same budget.
@Test func subprocessFinishesWhenEveryPoolThreadIsBlocked() async {
    let callers = ProcessInfo.processInfo.activeProcessorCount * 2
    let statuses = await withTaskGroup(of: Int32?.self) { group in
        for _ in 0..<callers {
            group.addTask { try? Subprocess.run("/usr/bin/true", arguments: []).status }
        }
        return await group.reduce(into: [Int32?]()) { $0.append($1) }
    }
    #expect(statuses == Array(repeating: 0, count: callers))
}

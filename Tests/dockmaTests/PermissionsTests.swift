import Foundation
import Testing
@testable import dockma

private func mode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
}

/// A fresh directory under the per-user temporary directory.
private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dockma-test-\(UUID().uuidString)", isDirectory: true)
}

@Test func stateDirectoriesArePrivate() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // An older install created the directories with the default mode.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let paths = Paths(root: root, home: root.deletingLastPathComponent())
    FileManager.default.createFile(atPath: paths.config.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
    try paths.createDirectories()
    #expect(try mode(paths.root) == 0o700)
    #expect(try mode(paths.logs) == 0o700)
    #expect(try mode(paths.config) == 0o600)
}

@Test func createDirectoriesLeavesHomeModeAlone() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try Paths(root: root, home: root).createDirectories()
    #expect(try mode(root) == 0o755)
}

@Test func dataDiskLogsAndConfigAreOwnerOnly() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root, home: root.deletingLastPathComponent())
    try paths.createDirectories()

    // An existing world-readable disk is tightened too.
    FileManager.default.createFile(atPath: paths.dataDisk.path, contents: nil, attributes: [.posixPermissions: 0o644])
    try VMConfigurationBuilder.prepareDataDisk(at: paths.dataDisk, sizeGiB: 4)
    #expect(try mode(paths.dataDisk) == 0o600)

    let handle = try Daemon.rotateAndOpen(paths.consoleLog)
    try handle.close()
    #expect(try mode(paths.consoleLog) == 0o600)

    try Config().save(to: paths.config)
    #expect(try mode(paths.config) == 0o600)
}

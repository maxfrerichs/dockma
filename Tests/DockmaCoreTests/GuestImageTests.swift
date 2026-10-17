import Foundation
import Testing
@testable import DockmaCore

private func makeGuest(protocol contents: String?) throws -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-test-\(UUID().uuidString)")
    let paths = Paths(root: root, home: root)
    try FileManager.default.createDirectory(at: paths.guest, withIntermediateDirectories: true)
    for url in [paths.kernel, paths.initrd] {
        try Data().write(to: url)
    }
    if let contents {
        try Data(contents.utf8).write(to: paths.guestProtocol)
    }
    return paths
}

@Test func guestImageNeedsMatchingProtocol() throws {
    let older = "\(GuestImage.protocolVersion - 1)\n", newer = "\(GuestImage.protocolVersion + 1)\n"
    for (contents, isValid) in [(nil, false), ("1\n", false), (older, false), (newer, false), ("junk", false), ("\(GuestImage.protocolVersion)\n", true)] {
        let paths = try makeGuest(protocol: contents)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        if isValid {
            try GuestImage.validate(paths: paths)
        } else {
            #expect(throws: DockmaError.self) { try GuestImage.validate(paths: paths) }
        }
    }
}

@Test func missingProtocolFileMeansVersionOne() throws {
    let paths = try makeGuest(protocol: nil)
    defer { try? FileManager.default.removeItem(at: paths.root) }
    #expect(GuestImage.installedProtocol(at: paths.guestProtocol) == 1)
}

/// vm/agent/protocol is what `make guest` ships as guest-protocol.
@Test func agentProtocolFileMatchesHost() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repo.appendingPathComponent("vm/agent/protocol")
    #expect(GuestImage.installedProtocol(at: file) == GuestImage.protocolVersion)
}

import Foundation
import Testing
@testable import DockmaCore

/// The first `## <version> – <date>` heading in CHANGELOG.md is the newest release.
@Test func versionMatchesNewestChangelogRelease() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let changelog = try String(contentsOf: repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    let newest = changelog.split(whereSeparator: \.isNewline).lazy
        .compactMap { line in line.wholeMatch(of: /## (\d+\.\d+\.\d+) \u{2013} \d{4}-\d{2}-\d{2}\s*/)?.1 }
        .first
    #expect(newest.map(String.init) == DockmaVersion.current)
}

import Foundation
import Testing
@testable import DockmaCore

@Test func splitterHandlesTTYLineEndingsAcrossReads() {
    var splitter = LogLineSplitter()
    #expect(splitter.lines(appending: Data("dockma: [0.12] filesystems mounted\r".utf8)) == ["dockma: [0.12] filesystems mounted"])
    // The "\n" of "\r\n" arrives with the next read and yields no empty line.
    #expect(splitter.lines(appending: Data("\nudhcpc: started".utf8)) == [])
    #expect(splitter.lines(appending: Data("\r\n\rThe system is going down NOW!\r\n".utf8)) == ["udhcpc: started", "The system is going down NOW!"])
}

@Test func splitterKeepsMultibyteCharacterSplitAcrossReads() {
    var splitter = LogLineSplitter()
    let bytes = Array("µs\n".utf8)
    #expect(splitter.lines(appending: Data(bytes[..<1])) == [])
    #expect(splitter.lines(appending: Data(bytes[1...])) == ["µs"])
}

@Test func splitterBoundsAnUnterminatedLine() {
    var splitter = LogLineSplitter()
    let lines = splitter.lines(appending: Data(repeating: UInt8(ascii: "x"), count: LogLineSplitter.maxLineBytes + 1))
    #expect(lines.count == 1)
    #expect(lines.first?.utf8.count == LogLineSplitter.maxLineBytes)
}

@Test func sanitizeStripsEscapesAndControls() {
    #expect(TerminalText.sanitize("\u{1B}[1;31mred\u{1B}[0m text") == "red text")
    #expect(TerminalText.sanitize("\u{1B}]0;title\u{07}a\tb\u{08}") == "a b")
    #expect(TerminalText.sanitize("\u{1B}]8;;url\u{1B}\\link") == "link")
    #expect(TerminalText.sanitize("plain µs") == "plain µs")
}

@Test func truncateLeavesTheLastColumnFree() {
    #expect(TerminalText.truncate("12345", toWidth: 6) == "12345")
    #expect(TerminalText.truncate("123456", toWidth: 6) == "1234…")
    #expect(TerminalText.truncate("123456", toWidth: 1) == "")
}

@Test func timestampIsStrippedFromDaemonLines() {
    #expect(TerminalText.withoutTimestamp("2026-10-16T22:03:44Z agent connected") == "agent connected")
    #expect(TerminalText.withoutTimestamp("dockma: [0.31] network up") == "dockma: [0.31] network up")
}

@Test func secondsHaveOneDecimal() {
    #expect(TerminalText.seconds(.milliseconds(1234)) == "1.2s")
    #expect(TerminalText.seconds(.zero) == "0.0s")
}

@Test func panelRedrawsInPlaceWithinItsRows() {
    var panel = LogPanel(title: "Starting dockma…", rows: 2, style: TerminalStyle(isEnabled: false))
    #expect(panel.clear() == "")
    #expect(panel.frame(width: 80, height: 24, elapsed: .zero, tick: 0) == "⠋ Starting dockma…  0.0s\n")
    for line in ["one", "two", "three"] { panel.append(line) }
    #expect(panel.lines == ["two", "three"])
    // Moves up over the one line drawn before, erases, redraws.
    #expect(panel.frame(width: 80, height: 24, elapsed: .seconds(1), tick: 1)
        == "\u{1B}[1F\u{1B}[J⠙ Starting dockma…  1.0s\n  │ two\n  │ three\n")
    #expect(panel.clear() == "\u{1B}[3F\u{1B}[J")
    #expect(panel.clear() == "")
}

@Test func panelFitsNarrowAndShortTerminals() {
    var panel = LogPanel(title: "Starting dockma…", rows: 6, style: TerminalStyle(isEnabled: false))
    panel.append("udhcpc: lease of 192.168.64.8 obtained from 192.168.64.1")
    panel.append("dockma: [0.33] data disk ready")
    let frame = panel.frame(width: 20, height: 3, elapsed: .zero, tick: 0)
    let lines = frame.split(separator: "\n")
    // Only one log row fits above the bottom of a 3-row screen.
    #expect(lines.count == 2)
    #expect(lines.allSatisfy { $0.count < 20 })
    #expect(lines.last == "  │ dockma: [0.33]…")
}

@Test func dumbTerminalGetsNoEscapes() throws {
    var primary: Int32 = -1
    var secondary: Int32 = -1
    try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
    defer { close(primary); close(secondary) }
    #expect(Terminal.rendersEscapes(secondary, environment: ["TERM": "xterm-256color"]))
    #expect(!Terminal.rendersEscapes(secondary, environment: ["TERM": "dumb"]))
    #expect(!Terminal.rendersEscapes(-1, environment: [:]))
    #expect(TerminalStyle(fd: secondary, environment: ["TERM": "dumb"]).isEnabled == false)
    #expect(TerminalStyle(fd: secondary, environment: ["TERM": "xterm", "NO_COLOR": "1"]).isEnabled == false)
}

@Test func styleKeepsSymbolsWithoutColor() {
    #expect(TerminalStyle(isEnabled: false).success("done") == "✓ done")
    #expect(TerminalStyle(isEnabled: true).success("done") == "\u{1B}[32m✓\u{1B}[0m done")
    #expect(TerminalStyle(fd: -1, environment: [:]).isEnabled == false)
}

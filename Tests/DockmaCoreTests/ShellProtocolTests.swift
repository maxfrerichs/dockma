import Foundation
import Testing
@testable import DockmaCore

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// The same bytes are asserted in vm/agent/internal/shell/shell_test.go.
@Test func resizeFrameMatchesAgentGolden() throws {
    #expect(hex(try ShellFrame.resize(rows: 24, cols: 80).encode()) == "040000000400180050")
}

/// The same bytes are asserted in vm/agent/internal/shell/shell_test.go.
@Test func windowFrameMatchesAgentGolden() throws {
    #expect(hex(try ShellFrame.window(256 * 1024).encode()) == "150000000400040000")
}

@Test(arguments: [
    ShellFrame.start(ShellStart(argv: ["uname", "-a"], tty: false, rows: 24, cols: 80, term: "xterm")),
    .stdin(Data("input".utf8)),
    .stdinEOF,
    .resize(rows: 50, cols: 200),
    .signal(SIGINT),
    .stdout(Data([0, 1, 2, 255])),
    .stderr(Data("oops".utf8)),
    .exit(143),
    .exit(-1),
    .error("cannot run"),
    .started,
    .window(256 * 1024),
])
func framesRoundTrip(frame: ShellFrame) throws {
    var decoder = ShellFrameDecoder()
    decoder.append(try frame.encode())
    #expect(try decoder.next() == frame)
    #expect(try decoder.next() == nil)
}

@Test func decoderWaitsForCompleteFrames() throws {
    let bytes = try ShellFrame.stdout(Data("hello".utf8)).encode() + ShellFrame.exit(3).encode()
    var decoder = ShellFrameDecoder()
    var frames: [ShellFrame] = []
    // Feed one byte at a time, as a slow socket might.
    for byte in bytes {
        decoder.append(Data([byte]))
        while let frame = try decoder.next() { frames.append(frame) }
    }
    #expect(frames == [.stdout(Data("hello".utf8)), .exit(3)])
}

@Test func decoderRejectsOversizedAndUnknownFrames() {
    var oversized = ShellFrameDecoder()
    oversized.append(Data([16, 0x7f, 0xff, 0xff, 0xff]))
    #expect(throws: DockmaError.self) { try oversized.next() }

    var unknown = ShellFrameDecoder()
    unknown.append(Data([99, 0, 0, 0, 0]))
    #expect(throws: DockmaError.self) { try unknown.next() }
}

@Test func startFrameUsesAgentFieldNames() throws {
    let payload = try ShellFrame.start(ShellStart(argv: [], tty: true, rows: 1, cols: 2, term: "t")).encode().dropFirst(5)
    let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(Set(json.keys) == ["argv", "tty", "rows", "cols", "term", "flow"])
    #expect(json["flow"] as? Bool == true)
}

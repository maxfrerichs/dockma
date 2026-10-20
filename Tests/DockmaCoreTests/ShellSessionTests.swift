import Foundation
import Testing
@testable import DockmaCore

/// Plays the agent on `fd`: grants `window` bytes of stdin credit up front
/// (none: an agent without flow control), returns the credit of each stdin
/// frame, and exits with 7 on stdin EOF. Returns the stdin frame sizes.
private func fakeAgent(fd: Int32, window: UInt32?) -> [Int] {
    func send(_ frame: ShellFrame) { writeAll(try! frame.encode(), to: fd) }
    if let window { send(.window(window)) }
    send(.started)
    var decoder = ShellFrameDecoder()
    var sizes: [Int] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        while let frame = try? decoder.next() {
            switch frame {
            case .stdin(let data):
                sizes.append(data.count)
                if window != nil { send(.window(UInt32(data.count))) }
            case .stdinEOF:
                send(.exit(7))
                return sizes
            default:
                break
            }
        }
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { return sizes }
        decoder.append(Data(buffer[0..<n]))
    }
}

/// Relays `input` through a session to a `fakeAgent` granting `window`;
/// returns the exit code and the stdin frame sizes the agent saw.
private func relay(_ input: String, window: UInt32?) async throws -> (code: Int32, sizes: [Int]) {
    var sockets: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    var pipe: [Int32] = [0, 0]
    try #require(Darwin.pipe(&pipe) == 0)
    defer { (sockets + [pipe[0]]).forEach { close($0) } }
    writeAll(Data(input.utf8), to: pipe[1])
    close(pipe[1])

    let session = ShellSession(fd: sockets[0], tty: false, input: pipe[0])
    let agentFD = sockets[1]
    async let sizes = runOnThread { fakeAgent(fd: agentFD, window: window) }
    let code = await runOnThread { session.relay() }
    return (code, await sizes)
}

@Test func stdinStaysWithinTheAgentsCredit() async throws {
    let result = try await relay("0123456789", window: 4)
    #expect(result.code == 7)
    #expect(result.sizes == [4, 4, 2])
}

@Test func stdinIsUnlimitedForAnAgentWithoutFlowControl() async throws {
    let result = try await relay("0123456789", window: nil)
    #expect(result.code == 7)
    #expect(result.sizes == [10])
}

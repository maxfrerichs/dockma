import Foundation

/// Client side of `dockma shell`: connects to the daemon's shell socket (which
/// proxies to dockma-agent) and bridges the local terminal or pipes to a
/// command in the VM.
public final class ShellSession: @unchecked Sendable {
    private let fd: Int32
    private let usesTTY: Bool
    private let writeLock = NSLock()
    private var signalSources: [DispatchSourceSignal] = []
    private var savedTerminal: termios?

    /// Stdin flow control. `unknown` until the agent's first frame says
    /// whether it grants credit (`window` before `started`) or predates flow
    /// control (`started` alone). Guarded by `flowCondition`.
    private enum StdinFlow { case unknown, credit, unlimited }
    private let flowCondition = NSCondition()
    private var flow = StdinFlow.unknown
    private var credit = 0

    private init(fd: Int32, tty: Bool) {
        self.fd = fd
        self.usesTTY = tty
    }

    /// Runs `argv` (a login shell when empty) and returns its exit code.
    public static func run(paths: Paths, argv: [String], tty: Bool) throws -> Int32 {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: paths.shellSocket.path, timeoutSeconds: nil)
        } catch {
            if ControlClient.isDaemonAnswering(paths: paths) {
                throw DockmaError("the running dockma daemon predates `dockma shell`; run `dockma restart`")
            }
            throw DockmaError("dockma is not running (start it with `dockma start`)")
        }
        let session = ShellSession(fd: fd, tty: tty)
        defer {
            session.restoreTerminal()
            close(fd)
        }
        return try session.run(argv: argv)
    }

    /// Runs the session for `argv` until the remote command exits; returns its exit code.
    private func run(argv: [String]) throws -> Int32 {
        let (rows, cols) = Terminal.size()
        let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        send(.start(ShellStart(argv: argv, tty: usesTTY, rows: rows, cols: cols, term: term)))

        if usesTTY {
            enterRawMode()
            handleSignal(SIGWINCH) { session in
                let (rows, cols) = Terminal.size()
                session.send(.resize(rows: rows, cols: cols))
            }
            // Raw mode turns ^C into a byte for the remote side; these only
            // arrive from outside (kill, closing the terminal window).
            for sig in [SIGTERM, SIGHUP] {
                handleSignal(sig) { session in
                    session.restoreTerminal()
                    exit(128 + sig)
                }
            }
        } else {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                handleSignal(sig) { session in session.send(.signal(sig)) }
            }
        }

        Thread.detachNewThread { [self] in pumpStdin() }
        return receive()
    }

    /// Copies local stdin into `stdin` frames, within the agent's credit,
    /// then signals EOF.
    private func pumpStdin() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var offset = 0
            while offset < n {
                let count = takeCredit(upTo: n - offset)
                if !send(.stdin(Data(buffer[offset..<(offset + count)]))) { return }
                offset += count
            }
        }
        send(.stdinEOF)
    }

    /// Blocks until stdin may be sent and returns how many of `wanted` bytes.
    private func takeCredit(upTo wanted: Int) -> Int {
        flowCondition.lock()
        defer { flowCondition.unlock() }
        while flow == .unknown || (flow == .credit && credit == 0) {
            flowCondition.wait()
        }
        guard flow == .credit else { return wanted }
        let granted = min(credit, wanted)
        credit -= granted
        return granted
    }

    private func updateFlow(_ change: () -> Void) {
        flowCondition.lock()
        change()
        flowCondition.broadcast()
        flowCondition.unlock()
    }

    /// Writes remote output locally until the exit frame arrives.
    private func receive() -> Int32 {
        var decoder = ShellFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var started = false
        while true {
            do {
                while let frame = try decoder.next() {
                    switch frame {
                    case .started:
                        started = true
                        updateFlow { if flow == .unknown { flow = .unlimited } }
                    case .window(let bytes):
                        updateFlow {
                            if flow == .unknown { flow = .credit }
                            if flow == .credit { credit += Int(bytes) }
                        }
                    case .stdout(let data):
                        writeAll(data, to: STDOUT_FILENO)
                    case .stderr(let data):
                        writeAll(data, to: STDERR_FILENO)
                    case .exit(let code):
                        return code
                    case .error(let message):
                        restoreTerminal()
                        Terminal.printError("dockma shell: \(message)")
                        return 255
                    default:
                        break
                    }
                }
            } catch {
                restoreTerminal()
                Terminal.printError("dockma shell: \(error)")
                return 255
            }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                restoreTerminal()
                if started {
                    Terminal.printError("dockma shell: connection to the VM closed (VM stopped or restarted?)")
                } else {
                    // No `started` frame: the agent doesn't serve the shell port,
                    // i.e. the guest image predates `dockma shell`.
                    Terminal.printError("dockma shell: the VM closed the session at once (guest image older than the CLI? run `make guest install-guest` and `dockma restart`)")
                }
                return 255
            }
            decoder.append(Data(buffer[0..<n]))
        }
    }

    @discardableResult
    private func send(_ frame: ShellFrame) -> Bool {
        guard let data = try? frame.encode() else { return false }
        return writeLock.withLock { writeAll(data, to: fd) }
    }

    /// Ignores `sig`'s default action and runs `handler` when it arrives.
    private func handleSignal(_ sig: Int32, with handler: @escaping @Sendable (ShellSession) -> Void) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { [self] in handler(self) }
        source.resume()
        signalSources.append(source)
    }

    private func enterRawMode() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
        savedTerminal = original
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    private func restoreTerminal() {
        guard var original = savedTerminal else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        savedTerminal = nil
    }
}

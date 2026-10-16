import Foundation

/// ANSI styling for CLI output; plain text when disabled. Status symbols are
/// kept either way, only the escape codes go.
public struct TerminalStyle: Sendable {
    /// Whether escape codes are written.
    public let isEnabled: Bool

    /// Creates a style that writes escape codes when `isEnabled`.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Creates the style for output to `fd`: enabled on a terminal unless
    /// `NO_COLOR` is set (https://no-color.org) or `TERM` is `dumb`.
    public init(fd: Int32, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let noColor = environment["NO_COLOR"].map { !$0.isEmpty } ?? false
        self.init(isEnabled: Terminal.rendersEscapes(fd, environment: environment) && !noColor)
    }

    /// Styling for standard output.
    public static func standardOutput() -> TerminalStyle { TerminalStyle(fd: STDOUT_FILENO) }

    /// Styling for standard error.
    public static func standardError() -> TerminalStyle { TerminalStyle(fd: STDERR_FILENO) }

    /// `message` behind a green check mark.
    public func success(_ message: String) -> String { "\(green("✓")) \(message)" }

    /// `message` behind a red cross.
    public func failure(_ message: String) -> String { "\(red("✗")) \(message)" }

    /// `message` behind a yellow exclamation mark.
    public func warning(_ message: String) -> String { "\(yellow("!")) \(message)" }

    /// `text` in bold.
    public func bold(_ text: String) -> String { apply("1", to: text) }

    /// `text` dimmed.
    public func dim(_ text: String) -> String { apply("2", to: text) }

    /// `text` in red.
    public func red(_ text: String) -> String { apply("31", to: text) }

    /// `text` in green.
    public func green(_ text: String) -> String { apply("32", to: text) }

    /// `text` in yellow.
    public func yellow(_ text: String) -> String { apply("33", to: text) }

    /// `text` in cyan.
    public func cyan(_ text: String) -> String { apply("36", to: text) }

    /// `text` wrapped in the SGR sequence `code`, or unchanged when disabled.
    private func apply(_ code: String, to text: String) -> String {
        isEnabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}

/// Facts about the controlling terminal.
public enum Terminal {
    /// Whether `fd` is a terminal.
    public static func isTerminal(_ fd: Int32) -> Bool { isatty(fd) == 1 }

    /// Whether `fd` is a terminal that renders escape sequences: any but
    /// one whose `TERM` is `dumb`, such as Emacs' `M-x shell`.
    public static func rendersEscapes(_ fd: Int32, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isTerminal(fd) && environment["TERM"] != "dumb"
    }

    /// The local terminal size, or 24x80 when neither stdout nor stdin is a
    /// terminal.
    public static func size() -> (rows: UInt16, cols: UInt16) {
        var size = winsize()
        for fd in [STDOUT_FILENO, STDIN_FILENO] where ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 {
            return (size.ws_row, size.ws_col)
        }
        return (24, 80)
    }
}

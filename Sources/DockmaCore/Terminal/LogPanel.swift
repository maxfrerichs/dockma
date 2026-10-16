import Foundation

/// A title line over the last few log lines, redrawn in place: each frame
/// moves the cursor back over the previous one and erases it. The panel
/// grows to `rows` lines and then scrolls within them.
public struct LogPanel: Sendable {
    /// Braille spinner frames for the title line.
    static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// The text of the title line.
    public let title: String
    /// The most log lines shown at once.
    public let rows: Int
    /// Colors for the spinner, the elapsed time and the log lines.
    private let style: TerminalStyle
    /// The last `rows` lines appended, oldest first.
    private(set) var lines: [String] = []
    /// How many terminal lines the last frame drew.
    private var drawnLineCount = 0

    /// Creates an empty panel titled `title` that shows up to `rows` lines.
    public init(title: String, rows: Int = 6, style: TerminalStyle) {
        self.title = title
        self.rows = rows
        self.style = style
    }

    /// Adds a log line, dropping the oldest beyond `rows`.
    public mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > rows { lines.removeFirst(lines.count - rows) }
    }

    /// The escape sequences that replace the previous frame with the current
    /// title and lines, for a terminal of `width` columns and `height` rows.
    /// `tick` picks the spinner frame. Ends at the start of the line below
    /// the panel.
    public mutating func frame(width: Int, height: Int, elapsed: Duration, tick: Int) -> String {
        var output = clear()
        let elapsedText = TerminalText.seconds(elapsed)
        // Spinner, space, title, two spaces, elapsed time; one column free.
        let titleWidth = width - 1 - 4 - elapsedText.count
        let spin = String(Self.spinner[tick % Self.spinner.count])
        output += "\(style.cyan(spin)) \(TerminalText.truncate(title, toWidth: titleWidth + 1))  \(style.dim(elapsedText))\n"
        // The cursor can't move above the top of the screen, so the whole
        // panel must fit on it.
        let shown = lines.suffix(max(0, min(rows, height - 2)))
        for line in shown {
            output += style.dim("  │ " + TerminalText.truncate(line, toWidth: width - 4)) + "\n"
        }
        drawnLineCount = 1 + shown.count
        return output
    }

    /// The escape sequences that erase the last frame, leaving the cursor
    /// where the panel started; empty when nothing is drawn.
    public mutating func clear() -> String {
        guard drawnLineCount > 0 else { return "" }
        defer { drawnLineCount = 0 }
        // CPL (to the start of a line n lines up), then ED (erase below).
        return "\u{1B}[\(drawnLineCount)F\u{1B}[J"
    }
}

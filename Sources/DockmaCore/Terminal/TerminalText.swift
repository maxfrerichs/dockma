import Foundation

/// Helpers that make log lines safe and short enough to redraw in place.
public enum TerminalText {
    /// `line` without ANSI escape sequences and control characters; a tab
    /// becomes a space. Guest output must not move the cursor of a panel
    /// that is redrawn by counting lines.
    public static func sanitized(_ line: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar.value {
            case 0x1B:
                switch scalars.next() {
                case "[":
                    // CSI: parameters, then a final byte in 0x40...0x7E.
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                case "]":
                    // OSC: ends with BEL or ESC \.
                    var afterEscape = false
                    while let next = scalars.next() {
                        if next.value == 0x07 || (afterEscape && next == "\\") { break }
                        afterEscape = next.value == 0x1B
                    }
                default:
                    break  // A two-character escape, or ESC at the end.
                }
            case 0x09:
                result.append(" ")
            case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// `line` cut to fit `width` columns with an ellipsis. One column stays
    /// free: a line that fills or wraps the row would break the cursor-up
    /// arithmetic of a redraw. Counts Characters as one column each, which
    /// is wrong for East Asian wide characters; guest logs are ASCII.
    public static func truncated(_ line: String, toWidth width: Int) -> String {
        let limit = width - 1
        guard limit > 0 else { return "" }
        guard line.count > limit else { return line }
        return line.prefix(limit - 1) + "…"
    }

    /// `line` without the leading ISO 8601 timestamp that `Log.info` writes.
    public static func withoutTimestamp(_ line: String) -> String {
        guard let match = line.prefixMatch(of: #/\d{4}-\d\d-\d\dT[\d:.]+Z /#) else { return line }
        return String(line[match.range.upperBound...])
    }

    /// `duration` in seconds with one decimal, e.g. `1.2s`.
    public static func seconds(_ duration: Duration) -> String {
        String(format: "%.1fs", duration / .seconds(1))
    }
}

/// Splits a byte stream into lines and buffers a partial last line.
public struct LogLineSplitter: Sendable {
    /// A longer partial line is emitted as it is, so a stream without line
    /// breaks can't grow the buffer without bound.
    static let maxLineBytes = 16 * 1024

    /// The bytes of the line not yet ended.
    private var pending: [UInt8] = []

    /// Creates a splitter with nothing buffered.
    public init() {}

    /// The complete lines that `data` finishes, after the bytes buffered
    /// by earlier calls. Splits on both `\n` and `\r` at the byte level, so
    /// a UTF-8 character or a TTY's `\r\n` may straddle two calls; empty
    /// lines are dropped.
    public mutating func lines(appending data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                flush(into: &lines)
            } else {
                pending.append(byte)
                if pending.count >= Self.maxLineBytes { flush(into: &lines) }
            }
        }
        return lines
    }

    /// Moves the buffered bytes, if any, to `lines` as one line.
    private mutating func flush(into lines: inout [String]) {
        guard !pending.isEmpty else { return }
        lines.append(String(decoding: pending, as: UTF8.self))
        pending.removeAll(keepingCapacity: true)
    }
}

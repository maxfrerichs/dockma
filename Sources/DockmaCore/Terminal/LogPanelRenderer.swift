import Foundation

/// Draws a `LogPanel` fed from log files on a background thread, so the
/// caller can block on the work the panel narrates.
public final class LogPanelRenderer: @unchecked Sendable {
    /// Receives the escape sequences and text of each frame.
    private let write: @Sendable (String) -> Void
    /// Time between frames.
    private let frameInterval: Duration
    /// When the panel appeared; the title shows the time since.
    private let started = ContinuousClock.now
    /// Guards `isFinished` and wakes the render thread from its sleep.
    private let condition = NSCondition()
    /// Whether `finish()` was called; guarded by `condition`.
    private var isFinished = false
    /// Signaled by the render thread once it has erased the panel.
    private let renderDone = DispatchSemaphore(value: 0)
    /// Whether `finish()` already waited for `renderDone`; caller's thread only.
    private var isJoined = false

    /// The panel drawn; render thread only.
    private var panel: LogPanel
    /// The logs whose new lines feed the panel; render thread only.
    private var tails: [LogTail]
    /// One splitter per tail, holding its partial last line; render thread only.
    private var splitters: [LogLineSplitter]

    /// Starts drawing a panel titled `title` with the lines appended to
    /// `logs`, one frame every `frameInterval`, passing output to `write`.
    public init(
        title: String, logs: [LogTail], style: TerminalStyle,
        frameInterval: Duration = .milliseconds(80), write: @escaping @Sendable (String) -> Void
    ) {
        self.panel = LogPanel(title: title, style: style)
        self.tails = logs
        self.splitters = logs.map { _ in LogLineSplitter() }
        self.frameInterval = frameInterval
        self.write = write
        Thread.detachNewThread { [self] in render() }
    }

    /// Starts a panel on standard output, which must be a terminal.
    public static func standardOutput(title: String, logs: [LogTail], style: TerminalStyle) -> LogPanelRenderer {
        // Swift's print buffers; the panel writes unbuffered after it.
        fflush(nil)
        return LogPanelRenderer(title: title, logs: logs, style: style) { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    /// Stops drawing and erases the panel; returns once it is erased.
    /// Wakes the render thread at once, so finishing adds no frame delay.
    /// Calls after the first do nothing.
    public func finish() {
        condition.withLock {
            isFinished = true
            condition.signal()
        }
        guard !isJoined else { return }
        isJoined = true
        renderDone.wait()
    }

    /// The render loop: reads the logs, draws a frame, sleeps until the next
    /// frame or `finish()`.
    private func render() {
        var tick = 0
        condition.lock()
        while !isFinished {
            condition.unlock()
            drawFrame(tick: tick)
            tick += 1
            condition.lock()
            if !isFinished {
                _ = condition.wait(until: Date(timeIntervalSinceNow: frameInterval / .seconds(1)))
            }
        }
        condition.unlock()
        write(panel.clear())
        renderDone.signal()
    }

    /// Appends new log lines to the panel and redraws it.
    private func drawFrame(tick: Int) {
        for index in tails.indices {
            for line in splitters[index].lines(appending: tails[index].readAppended()) {
                let text = TerminalText.sanitize(TerminalText.withoutTimestamp(line))
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { panel.append(text) }
            }
        }
        let (rows, cols) = Terminal.size()
        write(panel.frame(width: Int(cols), height: Int(rows), elapsed: .now - started, tick: tick))
    }
}

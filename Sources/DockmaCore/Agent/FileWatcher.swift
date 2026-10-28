import CoreServices
import Foundation

/// Watches the paths the agent asks for with FSEvents and reports changes
/// made below them, in batches that each fit one control line.
@MainActor
public final class FileWatcher {
    /// The largest JSON line a batch encodes to. The agent's line scanner
    /// stops the control connection at 64 KiB.
    nonisolated static let maxLineBytes = 32 * 1024
    /// The most paths watched at once; more bind mounts than this miss events.
    nonisolated static let maxPaths = 256

    /// Called with each batch of changes, in order.
    public var onChanges: (([FileEvent]) -> Void)?
    /// The home directory; only paths below it are watched.
    private let home: String
    private var paths: [String] = []
    private var stream: FSEventStreamRef?
    private var sink: Unmanaged<Sink>?
    // A serial queue of its own: blocking on global() can starve the cooperative pool.
    private let queue = DispatchQueue(label: "io.dockma.file-watcher")

    /// Creates a watcher for paths below `home` that watches nothing yet.
    public init(home: String) {
        self.home = home
    }

    /// Watches the allowed paths among `requested` instead of the current set;
    /// none stops watching. The paths come from the guest, which must not
    /// learn about changes outside the home share.
    public func watch(_ requested: [String]) {
        let paths = Self.allowedPaths(requested, home: home)
        if paths.count < requested.count {
            Log.info("file events: ignoring \(requested.count - paths.count) of \(requested.count) paths to watch, outside home, missing or over \(Self.maxPaths)")
        }
        guard paths != self.paths else { return }
        stop()
        self.paths = paths
        guard !paths.isEmpty else { return }
        let sink = Unmanaged.passRetained(Sink { [weak self] batch in
            // The main queue keeps the batches in order; Task hops don't promise that.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChanges?(batch) } }
        })
        var context = FSEventStreamContext(version: 0, info: sink.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
            sink.release()
            Log.info("file events: can't watch \(paths.count) paths")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        self.sink = sink
        Log.info("file events: watching \(paths.count) paths")
    }

    /// Stops watching. Batches already on the main queue are still delivered.
    public func stop() {
        paths = []
        guard let stream, let sink else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // After any callback already queued, which still uses the sink.
        queue.async { sink.release() }
        self.stream = nil
        self.sink = nil
    }

    /// The real paths among `requested` that are `home` or lie below it, sorted,
    /// without duplicates and at most `maxPaths`. Resolving first defeats `..`
    /// and symlinks that lead out of home; missing paths are dropped.
    nonisolated static func allowedPaths(_ requested: [String], home: String) -> [String] {
        guard let root = realPath(home) else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let allowed = Set(requested.compactMap(realPath).filter { $0 == root || $0.hasPrefix(prefix) })
        return Array(allowed.sorted().prefix(maxPaths))
    }

    /// `path` with symlinks, `.` and `..` resolved, or nil if it doesn't exist.
    nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The event for a change FSEvents reported at `path`, given the file's
    /// state now (nil when it is gone). FSEvents coalesces flags, so the
    /// current state decides between deleted and present.
    nonisolated static func event(path: String, flags: FSEventStreamEventFlags, status: stat?) -> FileEvent {
        guard let status else { return FileEvent(op: .deleted, path: path) }
        let isNew = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        let mtime = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        return FileEvent(op: isNew ? .created : .modified, path: path, mtimeNanos: mtime, size: Int64(status.st_size))
    }

    /// Splits `events` into batches whose `files` message encodes to at most `maxBytes`.
    nonisolated static func batches(_ events: [FileEvent], maxBytes: Int = maxLineBytes) -> [[FileEvent]] {
        let encoder = JSONEncoder()
        // The message without events, newline included.
        let overhead = (try? jsonLine(AgentMessage.files([])).count) ?? 64
        var batches: [[FileEvent]] = []
        var batch: [FileEvent] = []
        var bytes = overhead
        for event in events {
            // Plus one for the comma.
            let size = ((try? encoder.encode(event).count) ?? maxBytes) + 1
            if !batch.isEmpty && bytes + size > maxBytes {
                batches.append(batch)
                batch = []
                bytes = overhead
            }
            batch.append(event)
            bytes += size
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    /// Turns one FSEvents callback into batches for the sink.
    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
        let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        var events: [FileEvent] = []
        for i in 0..<count {
            let path = String(cString: cPaths[i])
            if eventFlags[i] & dropped != 0 {
                Log.info("file events: FSEvents dropped events below \(path); containers miss those changes")
                continue
            }
            var st = stat()
            events.append(event(path: path, flags: eventFlags[i], status: lstat(path, &st) == 0 ? st : nil))
        }
        for batch in batches(events) { sink.deliver(batch) }
    }
}

/// What the C callback reaches through the stream's context pointer.
private final class Sink: Sendable {
    let deliver: @Sendable ([FileEvent]) -> Void

    init(_ deliver: @escaping @Sendable ([FileEvent]) -> Void) {
        self.deliver = deliver
    }
}

import Foundation

/// Reads what was appended to a log file since the last read. Follows the
/// rotation and truncation that happen when the daemon restarts.
public struct LogTail: Sendable {
    /// The most bytes one read returns.
    static let maxReadBytes = 1 << 20

    /// The log file read.
    public let url: URL
    /// The inode of a file to skip: the previous run's log, which the daemon
    /// is about to rotate away.
    private let ignoredInode: UInt64?
    /// The inode of the file last read, or nil before it existed.
    private var inode: UInt64?
    /// How many bytes of that file were read.
    private var offset: UInt64

    /// Creates a tail of `url` that starts at its beginning, or at its
    /// current end unless `fromStart`. Reads return nothing while the file
    /// has inode `ignoringInode`.
    public init(url: URL, fromStart: Bool, ignoringInode: UInt64? = nil) {
        self.url = url
        self.ignoredInode = ignoringInode
        var info = stat()
        if stat(url.path, &info) == 0 {
            inode = UInt64(info.st_ino)
            offset = fromStart ? 0 : UInt64(info.st_size)
        } else {
            inode = nil
            offset = 0
        }
    }

    /// The inode of the file at `url`, or nil if it doesn't exist.
    public static func inode(of url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// The bytes appended since the last read, at most `maxReadBytes`; empty
    /// when there are none. A replaced or truncated file is read from its
    /// beginning.
    public mutating func readAppended() -> Data {
        // Stat the open descriptor, not the path, so the inode and size
        // belong to the file actually read even if it is rotated meanwhile.
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return Data() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return Data() }
        let currentInode = UInt64(info.st_ino)
        let size = UInt64(info.st_size)
        if currentInode == ignoredInode { return Data() }
        if currentInode != inode || size < offset {
            inode = currentInode
            offset = 0
        }
        guard size > offset else { return Data() }
        var data = Data(count: Int(min(size - offset, UInt64(Self.maxReadBytes))))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard count > 0 else { return Data() }
        offset += UInt64(count)
        return data.prefix(count)
    }
}

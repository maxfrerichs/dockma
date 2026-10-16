import Foundation

/// Blocking newline-delimited reads and writes on a socket descriptor.
public final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    public init(fd: Int32) { self.fd = fd }

    /// Returns the next line without its newline, or nil on EOF or error.
    public func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Writes all of `data` to `fd`; returns false on error.
@discardableResult
public func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}

/// Encodes `value` as one JSON line.
public func jsonLine<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(UInt8(ascii: "\n"))
    return data
}

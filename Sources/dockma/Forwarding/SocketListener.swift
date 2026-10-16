import Foundation

/// A listening socket whose accepted connections are handed to a callback as
/// blocking file descriptors. Accepting runs on a dispatch source, so
/// `cancel()` reliably stops it and closes the socket.
public final class SocketListener: @unchecked Sendable {
    public let description: String
    private let fd: Int32
    private let source: DispatchSourceRead
    private let unixPath: String?

    private init(fd: Int32, description: String, unixPath: String?, handler: @escaping @Sendable (Int32) -> Void) {
        self.fd = fd
        self.description = description
        self.unixPath = unixPath
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let spare = SpareDescriptor()
        source.setEventHandler { [fd, spare, description] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    switch errno {
                    case EINTR, ECONNABORTED:
                        continue
                    case EAGAIN:
                        break  // drained
                    case EMFILE, ENFILE:
                        spare.shed(listener: fd, description: description)
                    default:
                        Log.info("accept on \(description): \(String(cString: strerror(errno)))")
                    }
                    return
                }
                spare.accepted()
                // macOS accepted sockets inherit O_NONBLOCK; the copiers block.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                handler(client)
            }
        }
        source.setCancelHandler { [fd, spare] in
            close(fd)
            spare.close()
        }
        source.resume()
    }

    deinit { cancel() }

    public func cancel() {
        guard !source.isCancelled else { return }
        source.cancel()
        if let unixPath { unlink(unixPath) }
    }

    /// Listens on a unix socket, replacing a stale socket file. Mode 0600.
    public static func unix(path: String, handler: @escaping @Sendable (Int32) -> Void) throws -> SocketListener {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DockmaError("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        unlink(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw posixError("bind \(path)") }
        chmod(path, 0o600)
        return try finish(fd: fd, description: path, unixPath: path, handler: handler)
    }

    /// Listens on TCP `address:port`.
    public static func tcp(address: IPAddress, port: UInt16, handler: @escaping @Sendable (Int32) -> Void) throws -> SocketListener {
        let fd: Int32
        let rc: Int32
        let description: String
        var on: Int32 = 1
        switch address {
        case .v4(let a):
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket") }
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = a
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var copy = a
            inet_ntop(AF_INET, &copy, &text, socklen_t(text.count))
            description = "\(cString(text)):\(port)"
        case .v6(let a):
            fd = socket(AF_INET6, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket") }
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = a
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var copy = a
            inet_ntop(AF_INET6, &copy, &text, socklen_t(text.count))
            description = "[\(cString(text))]:\(port)"
        }
        guard rc == 0 else {
            let error = posixError("bind \(description)")
            close(fd)
            throw error
        }
        return try finish(fd: fd, description: description, unixPath: nil, handler: handler)
    }

    private static func finish(fd: Int32, description: String, unixPath: String?, handler: @escaping @Sendable (Int32) -> Void) throws -> SocketListener {
        guard listen(fd, 128) == 0 else {
            let error = posixError("listen \(description)")
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return SocketListener(fd: fd, description: description, unixPath: unixPath, handler: handler)
    }
}

/// A reserved descriptor for an accept loop that runs out of descriptors.
/// Without it a pending connection stays queued on EMFILE, the read source
/// fires again at once, and the daemon spins. Closing the spare frees a slot
/// to accept the connection and drop it. Only one source's handlers use it,
/// and dispatch never runs those concurrently.
private final class SpareDescriptor: @unchecked Sendable {
    private var fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
    private var shedding = false

    func shed(listener: Int32, description: String) {
        if !shedding {
            shedding = true
            Log.info("out of file descriptors; dropping new connections on \(description)")
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
        let client = accept(listener, nil, nil)
        if client >= 0 {
            Darwin.close(client)
        }
        fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
    }

    func accepted() {
        shedding = false
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

private func cString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func posixError(_ what: String) -> DockmaError {
    DockmaError("\(what): \(String(cString: strerror(errno)))")
}

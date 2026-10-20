import Foundation

/// A listening socket whose accepted connections are handed to a callback as
/// blocking file descriptors. Accepting runs on a dispatch source, so
/// `cancel()` reliably stops it and closes the socket.
public final class SocketListener: @unchecked Sendable {
    public let description: String
    private let fd: Int32
    private let source: DispatchSourceRead
    private let unixPath: String?

    /// Starts accepting on `fd`. With `acceptsOnlyLoopback`, connections from
    /// a non-loopback peer are closed without reaching `handler`.
    private init(fd: Int32, description: String, unixPath: String?, acceptsOnlyLoopback: Bool,
                 handler: @escaping @Sendable (Int32) -> Void) {
        self.fd = fd
        self.description = description
        self.unixPath = unixPath
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let spare = SpareDescriptor()
        let filter = acceptsOnlyLoopback ? LoopbackFilter(rejection: "closed a connection") : nil
        source.setEventHandler { [fd, spare, filter, description] in
            while true {
                var peer = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let client = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
                }
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
                spare.didAccept()
                if let filter, !filter.admits(peer, on: description) {
                    close(client)
                    continue
                }
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
        var addr = try UnixSocket.makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockmaError.posix("socket") }
        unlink(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let error = DockmaError.posix("bind \(path)")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        return try makeListening(fd: fd, description: path, unixPath: path, acceptsOnlyLoopback: false, handler: handler)
    }

    /// Listens on TCP `address:port`. With `acceptsOnlyLoopback`, connections
    /// whose peer isn't a loopback address are closed on accept, which lets a
    /// wildcard bind stand in for a loopback one.
    public static func tcp(address: IPAddress, port: UInt16, acceptsOnlyLoopback: Bool = false,
                           handler: @escaping @Sendable (Int32) -> Void) throws -> SocketListener {
        let (fd, description) = try InetSocket.makeBound(type: SOCK_STREAM, address: address, port: port)
        return try makeListening(fd: fd, description: acceptsOnlyLoopback ? "\(description) (loopback only)" : description,
                                 unixPath: nil, acceptsOnlyLoopback: acceptsOnlyLoopback, handler: handler)
    }

    /// Starts listening on the bound `fd` and wraps it in a listener.
    private static func makeListening(fd: Int32, description: String, unixPath: String?, acceptsOnlyLoopback: Bool,
                                      handler: @escaping @Sendable (Int32) -> Void) throws -> SocketListener {
        guard listen(fd, 128) == 0 else {
            let error = DockmaError.posix("listen \(description)")
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return SocketListener(fd: fd, description: description, unixPath: unixPath,
                              acceptsOnlyLoopback: acceptsOnlyLoopback, handler: handler)
    }
}

/// An IPv4 or IPv6 socket bound to an address, shared by TCP listeners and
/// UDP relays.
enum InetSocket {
    /// Creates a socket of `type` (`SOCK_STREAM` or `SOCK_DGRAM`) bound to
    /// `address:port`, and returns it with a description such as
    /// `127.0.0.1:80` or `[::1]:80`. IPv6 sockets are IPv6-only.
    static func makeBound(type: Int32, address: IPAddress, port: UInt16) throws -> (fd: Int32, description: String) {
        let fd: Int32
        let rc: Int32
        let description: String
        var on: Int32 = 1
        switch address {
        case .v4(let a):
            fd = socket(AF_INET, type, 0)
            guard fd >= 0 else { throw DockmaError.posix("socket") }
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = a
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            description = "\(address):\(port)"
        case .v6(let a):
            fd = socket(AF_INET6, type, 0)
            guard fd >= 0 else { throw DockmaError.posix("socket") }
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
            description = "[\(address)]:\(port)"
        }
        guard rc == 0 else {
            let error = DockmaError.posix("bind \(description)")
            close(fd)
            throw error
        }
        return (fd, description)
    }
}

/// Admits only loopback peers, logging the first rejection on a listener so
/// a port scan can't flood the log. Only one source's handlers use it, and
/// dispatch never runs those concurrently.
final class LoopbackFilter: @unchecked Sendable {
    private let rejection: String
    private var hasLoggedRejection = false

    /// Creates a filter whose log line starts with `rejection`, such as
    /// "closed a connection".
    init(rejection: String) {
        self.rejection = rejection
    }

    /// Whether `peer` is a loopback address; logs the first one that isn't.
    func admits(_ peer: sockaddr_storage, on description: String) -> Bool {
        let address = IPAddress(socketAddress: peer)
        if address?.isLoopback == true { return true }
        if !hasLoggedRejection {
            hasLoggedRejection = true
            Log.info("\(rejection) from \(address.map(String.init(describing:)) ?? "an unknown peer") on \(description): "
                + "only loopback peers are admitted (further rejections are not logged)")
        }
        return false
    }
}

/// A reserved descriptor for an accept loop that runs out of descriptors.
/// Without it a pending connection stays queued on EMFILE, the read source
/// fires again at once, and the daemon spins. Closing the spare frees a slot
/// to accept the connection and drop it. Only one source's handlers use it,
/// and dispatch never runs those concurrently.
private final class SpareDescriptor: @unchecked Sendable {
    private var fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
    private var isShedding = false

    func shed(listener: Int32, description: String) {
        if !isShedding {
            isShedding = true
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

    /// Records a successful accept, so the next shortage is logged again.
    func didAccept() {
        isShedding = false
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

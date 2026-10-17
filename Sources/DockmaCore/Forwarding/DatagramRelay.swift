import Foundation

/// Datagram framing on a UDP tunnel connection (vsock port 1026 after a
/// `udp <host:port>` header): `[len u16 BE][payload]` in both directions.
/// Mirrors `writeDatagram` and `readDatagram` in vm/agent/udp.go.
public enum DatagramFrame {
    /// The largest payload a frame carries.
    public static let maxPayload = 0xffff

    /// Encodes `payload`, at most `maxPayload` bytes, as one frame.
    public static func encode(_ payload: Data) -> Data {
        precondition(payload.count <= maxPayload, "datagram too large")
        var frame = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        frame.append(payload)
        return frame
    }

    /// Reads one frame from the blocking `fd` into `buffer`, which holds
    /// `maxPayload` bytes, and returns the payload length; nil on EOF or error.
    static func readPayload(from fd: Int32, into buffer: inout [UInt8]) -> Int? {
        var header = [UInt8](repeating: 0, count: 2)
        guard readFully(fd, into: &header, count: 2) else { return nil }
        let length = Int(header[0]) << 8 | Int(header[1])
        guard readFully(fd, into: &buffer, count: length) else { return nil }
        return length
    }

    /// Reads exactly `count` bytes into the start of `buffer`; false on EOF
    /// or error.
    private static func readFully(_ fd: Int32, into buffer: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// A host UDP socket whose clients are each tunnelled to a guest target over
/// their own vsock connection, so every client keeps a separate source port
/// at the target, as with docker-proxy. A client's flow ends after
/// `Limits.idleTimeout` without traffic either way.
///
/// Receiving runs on a dispatch source. Each flow writes frames on its own
/// serial queue and reads replies on its own thread, so a stalled flow never
/// blocks the others; datagrams beyond a flow's queue limit are dropped, as
/// UDP allows.
public final class DatagramRelay: @unchecked Sendable {
    /// Bounds on a relay's flows.
    public struct Limits: Sendable {
        /// How long a flow lasts without traffic; docker-proxy's UDP
        /// conntrack timeout. Flows are checked every quarter of it, at most
        /// every 5 s, so one can outlive it by that much.
        public var idleTimeout: Duration = .seconds(90)
        /// The most concurrent flows, so spoofed sources can't exhaust
        /// descriptors or threads. A new client beyond it ends the least
        /// recently active flow: resolvers use a fresh source port per query,
        /// so refusing new clients instead would starve them.
        public var maxFlows = 256
        /// The most datagrams a flow holds while its tunnel connects or its
        /// writes are blocked.
        public var maxQueuedDatagrams = 64
        /// The most bytes of frames all flows together hold while queued;
        /// datagrams beyond it are dropped, so a flood of large datagrams
        /// can't grow memory without bound.
        public var maxQueuedBytes = 16 << 20

        /// The defaults.
        public static let standard = Limits()
    }

    /// The bound address for the log, such as `127.0.0.1:53/udp`.
    public let description: String
    private let fd: Int32
    private let target: String
    private let connect: @Sendable () async throws -> Int32
    private let limits: Limits
    private let filter: LoopbackFilter?
    private let source: DispatchSourceRead
    private let sweeper: DispatchSourceTimer
    /// Guards `flows`, `queuedBytes`, `isClosed`, `hasLoggedFlowLimit` and
    /// every flow's state.
    private let lock = NSLock()
    private var flows: [PeerKey: Flow] = [:]
    /// Bytes of frames held in flows' pending lists and write queues.
    private var queuedBytes = 0
    private var isClosed = false
    private var hasLoggedFlowLimit = false
    /// Used only by the read source's handler, which dispatch never runs
    /// concurrently.
    private var receiveBuffer = [UInt8](repeating: 0, count: DatagramFrame.maxPayload)
    /// Whether an unexpected receive error was logged since the last
    /// datagram; used only by the read source's handler.
    private var hasLoggedReceiveError = false

    /// Binds UDP `address:port` and relays each client to `target` over a
    /// connection that `connect` opens to the agent's tunnel port. With
    /// `acceptsOnlyLoopback`, datagrams from non-loopback peers are dropped.
    public init(address: IPAddress, port: UInt16, target: String, acceptsOnlyLoopback: Bool = false,
                limits: Limits = .standard, connect: @escaping @Sendable () async throws -> Int32) throws {
        let (fd, bound) = try InetSocket.makeBound(type: SOCK_DGRAM, address: address, port: port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        self.target = target
        self.connect = connect
        self.limits = limits
        description = acceptsOnlyLoopback ? "\(bound)/udp (loopback only)" : "\(bound)/udp"
        filter = acceptsOnlyLoopback ? LoopbackFilter(rejection: "dropped a datagram") : nil
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        sweeper = DispatchSource.makeTimerSource(queue: .global())

        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [lock, fd] in
            // Under the lock, so a reply thread never sends on a closed or
            // reused descriptor.
            lock.withLock { _ = Darwin.close(fd) }
        }
        let interval = DispatchTimeInterval.nanoseconds(Self.nanoseconds(min(limits.idleTimeout / 4, .seconds(5))))
        sweeper.schedule(deadline: .now() + interval, repeating: interval)
        sweeper.setEventHandler { [weak self] in self?.expireIdleFlows() }
        source.resume()
        sweeper.resume()
    }

    deinit { cancel() }

    /// Stops receiving, ends every flow and closes the socket.
    public func cancel() {
        guard !source.isCancelled else { return }
        lock.withLock {
            isClosed = true
            Array(flows.values).forEach(closeFlow)
        }
        sweeper.cancel()
        source.cancel()
    }

    /// The number of live flows.
    var flowCount: Int { lock.withLock { flows.count } }

    /// Bytes of frames currently queued across all flows.
    var queuedByteCount: Int { lock.withLock { queuedBytes } }

    /// Receives every queued datagram and routes it to its client's flow.
    private func drain() {
        while true {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = receiveBuffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if n < 0 {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    break  // drained
                default:
                    // Logged once until a datagram arrives, in case the error
                    // repeats on every wake.
                    if !hasLoggedReceiveError {
                        hasLoggedReceiveError = true
                        Log.info("receive on \(description): \(String(cString: strerror(errno)))")
                    }
                }
                return
            }
            hasLoggedReceiveError = false
            if let filter, !filter.admits(peer, on: description) { continue }
            route(DatagramFrame.encode(Data(receiveBuffer[0..<n])), from: peer, length: length)
        }
    }

    /// Sends `frame` on the flow of the client at `peer`, starting a flow for
    /// a new client.
    private func route(_ frame: Data, from peer: sockaddr_storage, length: socklen_t) {
        let key = PeerKey(peer, length: length)
        lock.withLock {
            guard !isClosed else { return }
            if let flow = flows[key] {
                flow.lastActive = .now
                send(frame, on: flow)
                return
            }
            guard queuedBytes + frame.count <= limits.maxQueuedBytes else { return }
            if flows.count >= limits.maxFlows, let oldest = flows.values.min(by: { $0.lastActive < $1.lastActive }) {
                if !hasLoggedFlowLimit {
                    hasLoggedFlowLimit = true
                    Log.info("\(description) has \(limits.maxFlows) clients; new ones end the least recently active "
                        + "(logged once per relay)")
                }
                closeFlow(oldest)
            }
            let flow = Flow(key: key, peer: peer, peerLength: length)
            flow.pending.append(frame)
            queuedBytes += frame.count
            flows[key] = flow
            Task { [self, connect] in
                do {
                    didConnect(flow, guest: try await connect())
                } catch {
                    lock.withLock { closeFlow(flow) }
                }
            }
        }
    }

    /// Queues `frame` for the flow's tunnel, or drops it when the flow's
    /// queue or the relay's byte budget is full. Requires the lock.
    private func send(_ frame: Data, on flow: Flow) {
        guard queuedBytes + frame.count <= limits.maxQueuedBytes else { return }
        guard flow.guest >= 0 else {
            if flow.pending.count < limits.maxQueuedDatagrams {
                flow.pending.append(frame)
                queuedBytes += frame.count
            }
            return
        }
        guard flow.queuedWrites < limits.maxQueuedDatagrams else { return }
        write(frame, on: flow)
    }

    /// Writes `data` to the flow's tunnel on its queue, counting it against
    /// the byte budget until it is written. Requires the lock, which keeps it
    /// ordered before the close that `finish(_:)` queues.
    private func write(_ data: Data, on flow: Flow) {
        flow.queuedWrites += 1
        queuedBytes += data.count
        let guest = flow.guest
        flow.writes.async { [self] in
            // A failed write ends the reply thread, which finishes the flow.
            if !writeAll(data, to: guest) { shutdown(guest, SHUT_RDWR) }
            lock.withLock {
                flow.queuedWrites -= 1
                queuedBytes -= data.count
            }
        }
    }

    /// Drops the frames a flow holds while connecting. Requires the lock.
    private func discardPending(of flow: Flow) {
        queuedBytes -= flow.pending.reduce(0) { $0 + $1.count }
        flow.pending = []
    }

    /// Sends the tunnel header and the datagrams queued while connecting,
    /// then starts relaying replies. Closes `guest` if the flow already ended.
    private func didConnect(_ flow: Flow, guest: Int32) {
        // A write blocked this long fails and ends the flow, so stalled flows
        // can't pile up blocked threads in dispatch's limited pool.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(guest, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let isLive = lock.withLock {
            guard !flow.isClosed else { return false }
            flow.guest = guest
            var batch = Data("udp \(target)\n".utf8)
            flow.pending.forEach { batch.append($0) }
            discardPending(of: flow)  // `write` counts them again in the batch
            write(batch, on: flow)
            return true
        }
        guard isLive else {
            close(guest)
            return
        }
        Thread.detachNewThread { [self] in relayReplies(on: flow, from: guest) }
    }

    /// Sends each datagram the agent returns on `guest` to the flow's client,
    /// until the tunnel closes.
    private func relayReplies(on flow: Flow, from guest: Int32) {
        var buffer = [UInt8](repeating: 0, count: DatagramFrame.maxPayload)
        while let n = DatagramFrame.readPayload(from: guest, into: &buffer) {
            let isLive = lock.withLock {
                guard !isClosed, !flow.isClosed else { return false }
                flow.lastActive = .now
                var peer = flow.peer
                // Non-blocking: a full send buffer drops the datagram.
                _ = buffer.withUnsafeBytes { raw in
                    withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, n, 0, $0, flow.peerLength)
                        }
                    }
                }
                return true
            }
            if !isLive { break }
        }
        finish(flow)
    }

    /// Ends a flow whose reply thread has stopped, and closes its tunnel once
    /// its queued writes have run.
    private func finish(_ flow: Flow) {
        lock.withLock {
            closeFlow(flow)
            let guest = flow.guest
            flow.guest = -1
            flow.writes.async { _ = Darwin.close(guest) }
        }
    }

    /// Ends the flows that have been idle for `Limits.idleTimeout`.
    private func expireIdleFlows() {
        lock.withLock {
            let now = ContinuousClock.now
            flows.values.filter { now - $0.lastActive >= limits.idleTimeout }.forEach(closeFlow)
        }
    }

    /// Marks a flow ended and removes it. Shutting its tunnel down wakes the
    /// reply thread, which closes it; a flow still connecting closes it in
    /// `didConnect(_:guest:)`. Requires the lock.
    private func closeFlow(_ flow: Flow) {
        guard !flow.isClosed else { return }
        flow.isClosed = true
        discardPending(of: flow)
        if flows[flow.key] === flow { flows.removeValue(forKey: flow.key) }
        if flow.guest >= 0 { shutdown(flow.guest, SHUT_RDWR) }
    }

    /// The whole nanoseconds in `duration`.
    private static func nanoseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    }
}

/// A client's socket address, as a dictionary key.
private struct PeerKey: Hashable {
    let bytes: Data

    /// The first `length` bytes of `peer`.
    init(_ peer: sockaddr_storage, length: socklen_t) {
        var peer = peer
        bytes = withUnsafeBytes(of: &peer) { Data($0.prefix(Int(length))) }
    }
}

/// One client's tunnel. Every mutable property is guarded by the relay's lock.
private final class Flow: @unchecked Sendable {
    let key: PeerKey
    let peer: sockaddr_storage
    let peerLength: socklen_t
    /// Runs this flow's blocking tunnel writes in order.
    let writes = DispatchQueue(label: "io.dockma.udp-flow")
    /// The tunnel's descriptor; -1 while connecting and after it is closed.
    var guest: Int32 = -1
    /// Frames that arrived while the tunnel was connecting.
    var pending: [Data] = []
    var queuedWrites = 0
    var lastActive = ContinuousClock.now
    var isClosed = false

    /// Creates a flow for the client at `peer`.
    init(key: PeerKey, peer: sockaddr_storage, peerLength: socklen_t) {
        self.key = key
        self.peer = peer
        self.peerLength = peerLength
    }
}

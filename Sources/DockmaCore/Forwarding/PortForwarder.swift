import Foundation

/// Mirrors the guest's published TCP and UDP ports on the host. Each accepted
/// TCP connection, and each UDP client, is tunnelled over vsock to
/// dockma-agent, which dials the port inside the VM.
@MainActor
public final class PortForwarder {
    private struct Forward {
        let target: String
        let listeners: [SocketListener]
        let relays: [DatagramRelay]

        /// The listening addresses, for the log.
        var descriptions: [String] { listeners.map(\.description) + relays.map(\.description) }

        /// Closes every listener and relay.
        func cancel() {
            listeners.forEach { $0.cancel() }
            relays.forEach { $0.cancel() }
        }
    }

    private let host: VMHost
    private let bindAddress: String
    private var forwards: [ForwardedPort.Key: Forward] = [:]

    public init(host: VMHost, bindAddress: String) {
        self.host = host
        self.bindAddress = bindAddress
    }

    /// The forwarded ports, sorted by port and then transport.
    public var ports: [ForwardedPort.Key] { forwards.keys.sorted() }

    /// The wildcard and loopback addresses also get their IPv6 counterpart, so
    /// `localhost` works whichever family a client tries first.
    nonisolated static func bindAddresses(for address: String) -> [IPAddress] {
        let extra: String? = switch address {
        case "127.0.0.1": "::1"
        case "0.0.0.0": "::"
        default: nil
        }
        return [address, extra].compactMap { $0 }.compactMap(IPAddress.init)
    }

    /// A host address to listen on, and whether its listener admits only
    /// loopback peers.
    public struct ListenAddress: Equatable, Sendable {
        /// The address to bind.
        public var address: IPAddress
        /// Whether connections from non-loopback peers are closed on accept.
        public var acceptsOnlyLoopback: Bool
    }

    /// The addresses to listen on for `port`. macOS refuses a non-root bind
    /// below 1024 to a loopback address but allows the wildcard, so such a
    /// port binds the wildcard of the same family and admits only loopback
    /// peers.
    nonisolated static func listenAddresses(for bindAddress: String, port: UInt16) -> [ListenAddress] {
        bindAddresses(for: bindAddress).map { address in
            if port < 1024 && address.isLoopback {
                ListenAddress(address: address.unspecified, acceptsOnlyLoopback: true)
            } else {
                ListenAddress(address: address, acceptsOnlyLoopback: false)
            }
        }
    }

    /// The listener changes that `plan(current:desired:)` computes.
    public struct Plan: Equatable {
        /// Ports to start listening on, sorted by port.
        public var toOpen: [ForwardedPort]
        /// Ports whose listeners to close, sorted.
        public var toClose: [ForwardedPort.Key]
    }

    /// Computes the listener changes needed to go from `current` (port and
    /// transport → target) to `desired`. A port whose target changed is closed
    /// and reopened.
    public nonisolated static func plan(current: [ForwardedPort.Key: String], desired: [ForwardedPort]) -> Plan {
        let wanted = Dictionary(desired.map { ($0.key, $0.target) }, uniquingKeysWith: { first, _ in first })
        let close = current.filter { wanted[$0.key] != $0.value }.map(\.key).sorted()
        let open = wanted.filter { current[$0.key] != $0.value }
            .map { ForwardedPort(port: $0.key.port, transport: $0.key.transport, target: $0.value) }
            .sorted { $0.key < $1.key }
        return Plan(toOpen: open, toClose: close)
    }

    /// Opens and closes listeners so the forwarded ports match `desired`.
    public func update(_ desired: [ForwardedPort]) {
        let plan = Self.plan(current: forwards.mapValues(\.target), desired: desired)
        for key in plan.toClose {
            forwards.removeValue(forKey: key)?.cancel()
            Log.info("unforwarded port \(key)")
        }
        for forward in plan.toOpen {
            let addresses = Self.listenAddresses(for: bindAddress, port: forward.port)
            let listeners = forward.transport == .tcp ? addresses.compactMap { tcpListener(on: $0, for: forward) } : []
            let relays = forward.transport == .udp ? addresses.compactMap { udpRelay(on: $0, for: forward) } : []
            let opened = Forward(target: forward.target, listeners: listeners, relays: relays)
            if opened.descriptions.isEmpty { continue }
            forwards[forward.key] = opened
            Log.info("forwarding \(opened.descriptions.joined(separator: ", ")) → \(forward.target)")
        }
    }

    /// A TCP listener on `listen` that tunnels each connection to the
    /// forward's target; nil, logged, if it can't bind.
    private func tcpListener(on listen: ListenAddress, for forward: ForwardedPort) -> SocketListener? {
        do {
            return try SocketListener.tcp(address: listen.address, port: forward.port,
                                          acceptsOnlyLoopback: listen.acceptsOnlyLoopback) { [host, target = forward.target] client in
                Task { @MainActor in
                    await Self.tunnel(client: client, target: target, host: host)
                }
            }
        } catch {
            Log.info("cannot forward port \(forward.key): \(error)")
            return nil
        }
    }

    /// A UDP relay on `listen` to the forward's target; nil, logged, if it
    /// can't bind.
    private func udpRelay(on listen: ListenAddress, for forward: ForwardedPort) -> DatagramRelay? {
        do {
            return try DatagramRelay(address: listen.address, port: forward.port, target: forward.target,
                                     acceptsOnlyLoopback: listen.acceptsOnlyLoopback) { [host] in
                try await host.connect(port: VMConfigurationBuilder.Port.tunnel)
            }
        } catch {
            Log.info("cannot forward port \(forward.key): \(error)")
            return nil
        }
    }

    public func removeAll() {
        update([])
    }

    private static func tunnel(client: Int32, target: String, host: VMHost) async {
        do {
            let guest = try await host.connect(port: VMConfigurationBuilder.Port.tunnel)
            guard writeAll(Data("tcp \(target)\n".utf8), to: guest) else {
                close(guest)
                close(client)
                return
            }
            SocketCopier.pipe(client, guest)
        } catch {
            close(client)
        }
    }
}

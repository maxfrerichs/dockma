import Foundation

/// Mirrors the guest's published TCP and UDP ports on the host. Each accepted
/// TCP connection, and each UDP client, is tunnelled over vsock to
/// dockma-agent, which dials the port inside the VM.
@MainActor
public final class PortForwarder {
    private struct Forward {
        let target: String
        var listeners: [SocketListener] = []
        var relays: [DatagramRelay] = []
        /// The addresses that `listeners` or `relays` are bound to.
        var boundAddresses: [ListenAddress] = []

        /// The listening addresses, for the log.
        var descriptions: [String] { listeners.map(\.description) + relays.map(\.description) }

        /// Closes every listener and relay.
        func cancel() {
            listeners.forEach { $0.cancel() }
            relays.forEach { $0.cancel() }
        }
    }

    /// A desired port that didn't bind on every address, with why.
    private struct Failure {
        let forward: ForwardedPort
        let error: String
        /// Whether it bound on some addresses, which keep serving.
        let isPartial: Bool
    }

    private let connectTunnel: @Sendable () async throws -> Int32
    private let bindAddress: String
    private var forwards: [ForwardedPort.Key: Forward] = [:]
    private var failures: [ForwardedPort.Key: Failure] = [:]

    /// A forwarder that binds published ports on `bindAddress` and tunnels
    /// them to the agent in `host`'s VM.
    public convenience init(host: VMHost, bindAddress: String) {
        self.init(bindAddress: bindAddress) { [host] in
            try await host.connect(port: VMConfigurationBuilder.Port.tunnel)
        }
    }

    /// A forwarder whose tunnels are descriptors from `connectTunnel`, each a
    /// fresh connection to the agent's tunnel port.
    init(bindAddress: String, connectTunnel: @escaping @Sendable () async throws -> Int32) {
        self.bindAddress = bindAddress
        self.connectTunnel = connectTunnel
    }

    /// The forwarded ports, sorted by port and then transport.
    public var ports: [ForwardedPort.Key] { forwards.keys.sorted() }

    /// Whether some desired port didn't bind on every address.
    public var hasFailures: Bool { !failures.isEmpty }

    /// One line per port that didn't bind on every address, sorted.
    public var failureWarnings: [String] {
        failures.sorted { $0.key < $1.key }.map { key, failure in
            "port \(key) is \(failure.isPartial ? "only partly forwarded" : "not forwarded"): \(failure.error)"
        }
    }

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
        let wanted = Set(desired.map(\.key))
        failures = failures.filter { wanted.contains($0.key) }
        let plan = Self.plan(current: forwards.mapValues(\.target), desired: desired)
        for key in plan.toClose {
            forwards.removeValue(forKey: key)?.cancel()
            Log.info("unforwarded port \(key)")
        }
        for forward in plan.toOpen {
            open(forward)
        }
    }

    /// Tries again to bind every port that didn't bind on all its addresses,
    /// say because a Mac process held it and has since exited. A partly
    /// forwarded port keeps the addresses it has and binds the missing ones.
    public func retryFailed() {
        for failure in failures.values.sorted(by: { $0.forward.key < $1.forward.key }) {
            open(failure.forward)
            if failures[failure.forward.key] == nil { Log.info("port \(failure.forward.key) is forwarded now") }
        }
    }

    /// Binds `forward` on each listen address it isn't bound to yet, and
    /// records it as failed when any bind fails.
    private func open(_ forward: ForwardedPort) {
        var opened = forwards[forward.key] ?? Forward(target: forward.target)
        var errors: [String] = []
        for address in Self.listenAddresses(for: bindAddress, port: forward.port) where !opened.boundAddresses.contains(address) {
            do {
                switch forward.transport {
                case .tcp: opened.listeners.append(try tcpListener(on: address, for: forward))
                case .udp: opened.relays.append(try udpRelay(on: address, for: forward))
                }
                opened.boundAddresses.append(address)
            } catch {
                errors.append("\(error)")
            }
        }
        if errors.isEmpty {
            failures[forward.key] = nil
        } else {
            let failure = Failure(forward: forward, error: errors.joined(separator: "; "), isPartial: !opened.descriptions.isEmpty)
            // Log a failure once, not on every retry.
            if failures[forward.key]?.error != failure.error {
                Log.info("cannot forward port \(forward.key): \(failure.error)")
            }
            failures[forward.key] = failure
        }
        guard !opened.descriptions.isEmpty, opened.boundAddresses != forwards[forward.key]?.boundAddresses else { return }
        forwards[forward.key] = opened
        Log.info("forwarding \(opened.descriptions.joined(separator: ", ")) → \(forward.target)")
    }

    /// A TCP listener on `listen` that tunnels each connection to the
    /// forward's target.
    private func tcpListener(on listen: ListenAddress, for forward: ForwardedPort) throws -> SocketListener {
        try SocketListener.tcp(address: listen.address, port: forward.port,
                               acceptsOnlyLoopback: listen.acceptsOnlyLoopback) { [connectTunnel, target = forward.target] client in
            Task {
                await Self.tunnel(client: client, target: target, connect: connectTunnel)
            }
        }
    }

    /// A UDP relay on `listen` to the forward's target.
    private func udpRelay(on listen: ListenAddress, for forward: ForwardedPort) throws -> DatagramRelay {
        try DatagramRelay(address: listen.address, port: forward.port, target: forward.target,
                          acceptsOnlyLoopback: listen.acceptsOnlyLoopback, connect: connectTunnel)
    }

    /// Closes every listener and relay and forgets failed ports.
    public func removeAll() {
        update([])
    }

    /// Connects `client` to `target` in the guest through a fresh tunnel.
    private nonisolated static func tunnel(client: Int32, target: String, connect: @Sendable () async throws -> Int32) async {
        do {
            let guest = try await connect()
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

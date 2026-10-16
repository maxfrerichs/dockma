import Foundation

/// Mirrors the guest's published TCP ports as listeners on the host. Each
/// accepted connection is tunnelled over vsock to dockma-agent, which dials
/// the port inside the VM.
@MainActor
public final class PortForwarder {
    private struct Forward {
        let target: String
        let listeners: [SocketListener]
    }

    private let host: VMHost
    private let bindAddress: String
    private var forwards: [UInt16: Forward] = [:]

    public init(host: VMHost, bindAddress: String) {
        self.host = host
        self.bindAddress = bindAddress
    }

    public var ports: [UInt16] { forwards.keys.sorted() }

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
        public var toClose: [UInt16]
    }

    /// Computes the listener changes needed to go from `current` (port →
    /// target) to `desired`. A port whose target changed is closed and reopened.
    public nonisolated static func plan(current: [UInt16: String], desired: [ForwardedPort]) -> Plan {
        let wanted = Dictionary(desired.map { ($0.port, $0.target) }, uniquingKeysWith: { first, _ in first })
        let close = current.filter { wanted[$0.key] != $0.value }.map(\.key).sorted()
        let open = wanted.filter { current[$0.key] != $0.value }
            .map { ForwardedPort(port: $0.key, target: $0.value) }
            .sorted { $0.port < $1.port }
        return Plan(toOpen: open, toClose: close)
    }

    /// Opens and closes listeners so the forwarded ports match `desired`.
    public func update(_ desired: [ForwardedPort]) {
        let plan = Self.plan(current: forwards.mapValues(\.target), desired: desired)
        for port in plan.toClose {
            forwards.removeValue(forKey: port)?.listeners.forEach { $0.cancel() }
            Log.info("unforwarded port \(port)")
        }
        for forward in plan.toOpen {
            let listeners = Self.listenAddresses(for: bindAddress, port: forward.port).compactMap { listen -> SocketListener? in
                do {
                    return try SocketListener.tcp(address: listen.address, port: forward.port,
                                                  acceptsOnlyLoopback: listen.acceptsOnlyLoopback) { [host, target = forward.target] client in
                        Task { @MainActor in
                            await Self.tunnel(client: client, target: target, host: host)
                        }
                    }
                } catch {
                    Log.info("cannot forward port \(forward.port): \(error)")
                    return nil
                }
            }
            if listeners.isEmpty { continue }
            forwards[forward.port] = Forward(target: forward.target, listeners: listeners)
            Log.info("forwarding \(listeners.map(\.description).joined(separator: ", ")) → \(forward.target)")
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

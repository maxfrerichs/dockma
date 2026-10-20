import Foundation
import Virtualization

/// Owns the `VZVirtualMachine`. VZ objects are bound to the queue they were
/// created on, so everything here runs on the main actor.
@MainActor
public final class VMHost: NSObject, VZVirtualMachineDelegate {
    private let vm: VZVirtualMachine
    private var acceptors: [SocketAcceptor] = []
    /// Called once when the guest powers off or the VM fails.
    public var onStop: ((Error?) -> Void)?

    public init(configuration: VZVirtualMachineConfiguration) {
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    public var isRunning: Bool { vm.state == .running }

    public func start() async throws {
        try await vm.start()
    }

    /// Hard stop, like pulling the power cord.
    public func forceStop() async throws {
        try await vm.stop()
    }

    /// Accepts vsock connections the guest opens to `port` on the host and
    /// hands each to `accept` as a descriptor the callee owns. Call it
    /// before `start()`, so the listener exists when the guest dials.
    public func listen(onPort port: UInt32, accept: @escaping @MainActor (Int32) -> Void) throws {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw DockmaError("VM has no vsock device")
        }
        let acceptor = SocketAcceptor(accept: accept)
        let listener = VZVirtioSocketListener()
        listener.delegate = acceptor
        device.setSocketListener(listener, forPort: port)
        acceptors.append(acceptor)
    }

    /// Opens a vsock stream to a guest port and returns a file descriptor the
    /// caller owns. The VZ connection object is closed right away; the dup'd
    /// descriptor keeps the socket open.
    public func connect(port: UInt32) async throws -> Int32 {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw DockmaError("VM has no vsock device")
        }
        let connection = try await device.connect(toPort: port)
        return try Self.takeDescriptor(of: connection)
    }

    /// Dups the connection's descriptor (with `SO_NOSIGPIPE`) and closes the
    /// VZ connection object; the dup keeps the socket open.
    static func takeDescriptor(of connection: VZVirtioSocketConnection) throws -> Int32 {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            let error = DockmaError.posix("dup")
            connection.close()
            throw error
        }
        connection.close()
        SocketOptions.disableSIGPIPE(on: fd)
        return fd
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop?(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        onStop?(error)
    }
}

/// The delegate of a vsock listener: takes each incoming connection's
/// descriptor and passes it on. VZ calls it on the VM's queue, the main queue.
@MainActor
private final class SocketAcceptor: NSObject, VZVirtioSocketListenerDelegate {
    private let accept: @MainActor (Int32) -> Void

    init(accept: @escaping @MainActor (Int32) -> Void) {
        self.accept = accept
    }

    /// Accepts every connection and passes its descriptor on.
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        do {
            accept(try VMHost.takeDescriptor(of: connection))
        } catch {
            Log.info("vsock accept: \(error)")
        }
        return true
    }
}

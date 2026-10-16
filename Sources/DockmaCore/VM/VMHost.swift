import Foundation
import Virtualization

/// Owns the `VZVirtualMachine`. VZ objects are bound to the queue they were
/// created on, so everything here runs on the main actor.
@MainActor
public final class VMHost: NSObject, VZVirtualMachineDelegate {
    private let vm: VZVirtualMachine
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

    /// Opens a vsock stream to a guest port and returns a file descriptor the
    /// caller owns. The VZ connection object is closed right away; the dup'd
    /// descriptor keeps the socket open.
    public func connect(port: UInt32) async throws -> Int32 {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw DockmaError("VM has no vsock device")
        }
        let connection = try await device.connect(toPort: port)
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { throw DockmaError.posix("dup") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop?(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        onStop?(error)
    }
}

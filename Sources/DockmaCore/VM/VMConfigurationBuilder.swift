import Foundation
import Virtualization

/// Turns `Config` + `Paths` into a validated `VZVirtualMachineConfiguration`.
@MainActor
public enum VMConfigurationBuilder {
    /// vsock ports served by dockma-agent in the guest.
    public enum Port {
        public static let docker: UInt32 = 1024
        public static let control: UInt32 = 1025
        public static let tunnel: UInt32 = 1026
        public static let shell: UInt32 = 1027
    }

    /// A built configuration plus what the caller should tell the user.
    public struct Output {
        public let configuration: VZVirtualMachineConfiguration
        /// Set when Rosetta was requested but could not be attached.
        public let rosettaWarning: String?
    }

    public static func build(
        config: Config,
        paths: Paths,
        consoleLog: FileHandle,
        dockerLog: FileHandle
    ) throws -> Output {
        for url in [paths.kernel, paths.initrd] where !FileManager.default.fileExists(atPath: url.path) {
            throw DockmaError("guest image missing: \(url.path) (run `make guest install-guest`)")
        }

        let bootLoader = VZLinuxBootLoader(kernelURL: paths.kernel)
        bootLoader.initialRamdiskURL = paths.initrd
        bootLoader.commandLine = KernelCmdline.build(home: paths.home.path)

        let vm = VZVirtualMachineConfiguration()
        vm.bootLoader = bootLoader
        vm.platform = VZGenericPlatformConfiguration()
        vm.cpuCount = min(max(config.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vm.memorySize = min(max(config.memoryMiB * 1024 * 1024, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // hvc0: kernel and init output. hvc1: dockerd output.
        vm.serialPorts = [consoleLog, dockerLog].map { handle in
            let port = VZVirtioConsoleDeviceSerialPortConfiguration()
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
            return port
        }

        let disk = try VZDiskImageStorageDeviceAttachment(
            url: paths.dataDisk, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
        vm.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let mac = config.macAddress.flatMap(VZMACAddress.init(string:)) {
            network.macAddress = mac
        }
        vm.networkDevices = [network]

        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vm.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let home = VZVirtioFileSystemDeviceConfiguration(tag: "home")
        home.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: paths.home, readOnly: false))
        var shares = [home]

        var rosettaWarning: String?
        if config.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                shares.append(rosetta)
            case .notInstalled:
                rosettaWarning = "Rosetta is not installed; amd64 images won't run. Install it with `softwareupdate --install-rosetta`."
            case .notSupported:
                rosettaWarning = "Rosetta is not supported on this Mac."
            @unknown default:
                rosettaWarning = "Rosetta availability is unknown; not attaching it."
            }
        }
        vm.directorySharingDevices = shares

        try vm.validate()
        return Output(configuration: vm, rosettaWarning: rosettaWarning)
    }

    /// Creates the sparse data disk, or grows it when `diskGiB` increased.
    /// The guest grows the ext4 filesystem with resize2fs on boot.
    /// The image is kept at mode 0600.
    nonisolated public static func prepareDataDisk(at url: URL, sizeGiB: UInt64) throws {
        let size = sizeGiB * 1024 * 1024 * 1024
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DockmaError("cannot create \(url.path)")
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let current = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if current > size {
            throw DockmaError("data disk is \(current >> 30) GiB; shrinking to \(sizeGiB) GiB is not supported")
        }
        if current < size {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: size)
        }
    }
}

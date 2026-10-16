import Foundation

/// User-tunable VM settings, persisted as JSON in `~/.dockma/config.json`.
/// Missing keys fall back to defaults so older files keep working.
public struct Config: Codable, Equatable, Sendable {
    public var cpus: Int
    public var memoryMiB: UInt64
    public var diskGiB: UInt64
    /// Host address published container ports are bound to.
    public var portBindAddress: String
    public var rosetta: Bool
    /// Start at login by installing the plist into ~/Library/LaunchAgents.
    public var autostart: Bool
    /// Stable MAC so the NAT DHCP server hands out the same address.
    public var macAddress: String?

    public static let defaultCPUs = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    public init(
        cpus: Int = Config.defaultCPUs,
        memoryMiB: UInt64 = 4096,
        diskGiB: UInt64 = 64,
        portBindAddress: String = "127.0.0.1",
        rosetta: Bool = true,
        autostart: Bool = false,
        macAddress: String? = nil
    ) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        self.portBindAddress = portBindAddress
        self.rosetta = rosetta
        self.autostart = autostart
        self.macAddress = macAddress
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus
        memoryMiB = try c.decodeIfPresent(UInt64.self, forKey: .memoryMiB) ?? d.memoryMiB
        diskGiB = try c.decodeIfPresent(UInt64.self, forKey: .diskGiB) ?? d.diskGiB
        portBindAddress = try c.decodeIfPresent(String.self, forKey: .portBindAddress) ?? d.portBindAddress
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? d.rosetta
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? d.autostart
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
    }

    public func validate() throws {
        guard cpus >= 1 else { throw DockmaError("cpus must be at least 1") }
        guard memoryMiB >= 512 else { throw DockmaError("memoryMiB must be at least 512") }
        guard diskGiB >= 4 else { throw DockmaError("diskGiB must be at least 4") }
        // Upper bounds keep the byte sizes the VM is built with from overflowing.
        guard memoryMiB <= UInt64.max >> 20 else { throw DockmaError("memoryMiB is too large: \(memoryMiB)") }
        guard diskGiB <= 65536 else { throw DockmaError("diskGiB must be at most 65536 (64 TiB)") }
        guard IPAddress(portBindAddress) != nil else {
            throw DockmaError("portBindAddress must be an IPv4 or IPv6 address: \(portBindAddress)")
        }
    }

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw DockmaError("cannot read \(url.path): \(error)")
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        // The atomic write creates a new file with the default mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A parsed numeric IP address, used for bind addresses.
public enum IPAddress: Equatable, Sendable {
    case v4(in_addr)
    case v6(in6_addr)

    public init?(_ string: String) {
        var a4 = in_addr()
        if inet_pton(AF_INET, string, &a4) == 1 {
            self = .v4(a4)
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, string, &a6) == 1 {
            self = .v6(a6)
            return
        }
        return nil
    }

    public static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case let (.v4(a), .v4(b)): a.s_addr == b.s_addr
        case var (.v6(a), .v6(b)): memcmp(&a, &b, MemoryLayout<in6_addr>.size) == 0
        default: false
        }
    }
}

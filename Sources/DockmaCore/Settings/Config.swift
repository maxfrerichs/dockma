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

    /// Throws for a value the VM can't be built with. Messages name both the
    /// config.json key and the `dockma config` flag that sets it, since the
    /// daemon also validates a hand-edited file.
    public func validate() throws {
        guard cpus >= 1 else { throw DockmaError("cpus (--cpus) must be at least 1") }
        guard memoryMiB >= 512 else { throw DockmaError("memoryMiB (--memory) must be at least 512") }
        guard diskGiB >= 4 else { throw DockmaError("diskGiB (--disk) must be at least 4") }
        // Upper bounds keep the byte sizes the VM is built with from overflowing.
        guard memoryMiB <= UInt64.max >> 20 else { throw DockmaError("memoryMiB (--memory) is too large: \(memoryMiB)") }
        guard diskGiB <= 65536 else { throw DockmaError("diskGiB (--disk) must be at most 65536 (64 TiB)") }
        guard IPAddress(portBindAddress) != nil else {
            throw DockmaError("portBindAddress (--port-bind-address) must be an IPv4 or IPv6 address: \(portBindAddress)")
        }
    }

    /// Settings that are valid but likely to hurt: more vCPUs than the Mac
    /// has cores, or memory that leaves the Mac less than a quarter of its
    /// own.
    public func resourceWarnings(hostCPUs: Int, hostMemoryBytes: UInt64) -> [String] {
        var warnings: [String] = []
        if cpus > hostCPUs {
            warnings.append("--cpus \(cpus) is more than this Mac's \(hostCPUs) cores")
        }
        let hostMiB = hostMemoryBytes >> 20
        if memoryMiB > hostMiB / 4 * 3 {
            warnings.append("--memory \(memoryMiB) MiB is more than 75% of this Mac's \(hostMiB) MiB")
        }
        return warnings
    }

    /// The settings in `url`, or the defaults if it doesn't exist. A file
    /// that doesn't parse throws an error naming the offending key.
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw DockmaError("\(url.path) is invalid: \(Self.describe(error)). Fix it, or delete it to go back to the defaults.")
        } catch {
            throw DockmaError("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// A one-line description of a decoding error: the key path and what
    /// was wrong there.
    static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): context = c
        @unknown default: return "\(error)"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        var reason = context.debugDescription
        // JSONSerialization's syntax errors are in the underlying error.
        if let underlying = context.underlyingError as NSError?,
           let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
            reason = detail
        }
        return path.isEmpty ? reason : "\(path): \(reason)"
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
public enum IPAddress: Equatable, Sendable, CustomStringConvertible {
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

    /// The address of an IPv4 or IPv6 socket address, such as an accepted peer;
    /// nil for other families.
    public init?(socketAddress storage: sockaddr_storage) {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            self = withUnsafeBytes(of: &storage) { .v4($0.load(as: sockaddr_in.self).sin_addr) }
        case AF_INET6:
            self = withUnsafeBytes(of: &storage) { .v6($0.load(as: sockaddr_in6.self).sin6_addr) }
        default:
            return nil
        }
    }

    /// Whether this is a loopback address: `127.0.0.0/8`, `::1`, or an
    /// IPv4-mapped `::ffff:127.x.x.x`.
    public var isLoopback: Bool {
        switch self {
        case .v4(let a):
            return UInt32(bigEndian: a.s_addr) >> 24 == 127
        case .v6(let a):
            let bytes = withUnsafeBytes(of: a) { Array($0) }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
        }
    }

    /// The address in its standard text form, such as `127.0.0.1` or `::1`.
    public var description: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch self {
        case .v4(var a): inet_ntop(AF_INET, &a, &text, socklen_t(text.count))
        case .v6(var a): inet_ntop(AF_INET6, &a, &text, socklen_t(text.count))
        }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The unspecified (wildcard) address of the same family: `0.0.0.0` or `::`.
    public var unspecified: IPAddress {
        switch self {
        case .v4: .v4(in_addr(s_addr: 0))
        case .v6: .v6(in6_addr())
        }
    }

    public static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case let (.v4(a), .v4(b)): a.s_addr == b.s_addr
        case var (.v6(a), .v6(b)): memcmp(&a, &b, MemoryLayout<in6_addr>.size) == 0
        default: false
        }
    }
}

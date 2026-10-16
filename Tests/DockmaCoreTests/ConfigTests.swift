import Foundation
import Testing
@testable import DockmaCore

@Test func configDecodesMissingKeysAsDefaults() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data(#"{"cpus": 3}"#.utf8))
    #expect(config.cpus == 3)
    #expect(config.memoryMiB == Config().memoryMiB)
    #expect(config.portBindAddress == "127.0.0.1")
    #expect(config.rosetta)
    #expect(!config.autostart)
    #expect(config.macAddress == nil)
}

@Test func configRoundTrips() throws {
    let config = Config(cpus: 8, memoryMiB: 8192, diskGiB: 128, portBindAddress: "0.0.0.0",
                        rosetta: false, autostart: true, macAddress: "02:00:00:00:00:01")
    let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
    #expect(decoded == config)
}

@Test func configLoadReturnsDefaultsWhenFileIsMissing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(try Config.load(from: url) == Config())
}

@Test(arguments: [
    Config(cpus: 0),
    Config(memoryMiB: 256),
    Config(diskGiB: 1),
    Config(memoryMiB: .max),
    Config(diskGiB: .max),
    Config(portBindAddress: "localhost"),
])
func configRejectsInvalidValues(config: Config) {
    #expect(throws: DockmaError.self) { try config.validate() }
}

@Test func ipAddressParsesBothFamilies() {
    #expect(IPAddress("127.0.0.1") != nil)
    #expect(IPAddress("::1") != nil)
    #expect(IPAddress("::1") != IPAddress("127.0.0.1"))
    #expect(IPAddress("::") == IPAddress("0:0:0:0:0:0:0:0"))
    #expect(IPAddress("example.com") == nil)
}

@Test func socketPathLimit() throws {
    try Paths.validateSocketPath(URL(fileURLWithPath: "/Users/someone/.dockma/docker.sock"))
    let long = "/" + String(repeating: "a", count: 110) + "/docker.sock"
    #expect(throws: DockmaError.self) { try Paths.validateSocketPath(URL(fileURLWithPath: long)) }
}

@Test func randomMACIsLocallyAdministeredUnicast() {
    for _ in 0..<50 {
        let mac = Daemon.randomMACAddress()
        let first = UInt8(mac.prefix(2), radix: 16)!
        #expect(first & 0x02 == 0x02)
        #expect(first & 0x01 == 0)
        #expect(mac.split(separator: ":").count == 6)
    }
}

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

@Test func invalidConfigFileNamesTheKey() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-config-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"cpus": "four"}"#.utf8).write(to: url)
    let error = try #require(throws: DockmaError.self) { try Config.load(from: url) }
    #expect(error.description.contains("is invalid: cpus: "))
    #expect(error.description.contains("delete it"))

    try Data(#"{"cpus": 4,"#.utf8).write(to: url)
    #expect(throws: DockmaError.self) { try Config.load(from: url) }
}

@Test func validationNamesTheFlag() {
    let error = #expect(throws: DockmaError.self) { try Config(memoryMiB: 256).validate() }
    #expect(error?.description.hasPrefix("memoryMiB (--memory) ") == true)
}

@Test func resourceWarningsCompareWithTheMac() {
    let config = Config(cpus: 12, memoryMiB: 14 * 1024)
    let warnings = config.resourceWarnings(hostCPUs: 10, hostMemoryBytes: 16 << 30)
    #expect(warnings.count == 2)
    #expect(Config(cpus: 4, memoryMiB: 4096).resourceWarnings(hostCPUs: 10, hostMemoryBytes: 16 << 30).isEmpty)
}

@Test func dataDiskCanGrowButNotShrink() throws {
    try VMConfigurationBuilder.checkDataDiskResize(currentBytes: 64 << 30, toGiB: 64)
    try VMConfigurationBuilder.checkDataDiskResize(currentBytes: 64 << 30, toGiB: 128)
    #expect(throws: DockmaError.self) { try VMConfigurationBuilder.checkDataDiskResize(currentBytes: 64 << 30, toGiB: 32) }
}

@Test func configSaveKeepsUnknownKeys() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"cpus": 3, "macAddress": "02:00:00:00:00:01", "shares": ["/private/tmp"]}"#.utf8).write(to: url)
    var config = try Config.load(from: url)
    config.cpus = 5
    config.macAddress = nil
    try config.save(to: url)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect(object["shares"] as? [String] == ["/private/tmp"])
    #expect(object["cpus"] as? Int == 5)
    #expect(object["macAddress"] == nil)
    #expect(try Config.load(from: url) == config)
}

@Test func diskWarningCountsOnlyWhatTheImageCanStillClaim() {
    let config = Config(diskGiB: 100)
    #expect(config.diskWarning(allocatedBytes: 0, hostFreeBytes: 50 << 30) != nil)
    #expect(config.diskWarning(allocatedBytes: 60 << 30, hostFreeBytes: 50 << 30) == nil)
    #expect(config.diskWarning(allocatedBytes: 200 << 30, hostFreeBytes: 0) == nil)
}

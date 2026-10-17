import Foundation
import Testing
@testable import DockmaCore

/// The agent (vm/agent/main.go) emits these exact shapes.
@Test func decodesAgentMessages() throws {
    let hello = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"type":"hello","version":"0.1.0","kernel":"6.18.57"}"#.utf8))
    #expect(hello == AgentMessage(type: "hello", version: "0.1.0", kernel: "6.18.57"))

    let ports = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"type":"ports","ports":[{"port":8080,"target":"127.0.0.1:8080"}]}"#.utf8))
    #expect(ports.ports == [ForwardedPort(port: 8080, target: "127.0.0.1:8080")])
    #expect(ports.ports?.first?.transport == .tcp)  // a missing transport means TCP

    let udp = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"type":"ports","ports":[{"port":53,"transport":"udp","target":"127.0.0.1:53"}]}"#.utf8))
    #expect(udp.ports == [ForwardedPort(port: 53, transport: .udp, target: "127.0.0.1:53")])

    let empty = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"type":"ports"}"#.utf8))
    #expect(empty.ports == nil)

    // The same JSON is asserted in vm/agent/control_test.go.
    let docker = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"type":"docker","ready":true}"#.utf8))
    #expect(docker == AgentMessage(type: "docker", ready: true))
}

/// `wait` is a wire string; an older daemon fails to decode it.
@Test func encodesWaitRequest() throws {
    let line = try jsonLine(ControlRequest(command: .wait))
    #expect(String(decoding: line, as: UTF8.self) == #"{"command":"wait"}"# + "\n")
}

@Test func encodesHostMessagesAsSingleLines() throws {
    let line = try jsonLine(AgentMessage.setTime(Date(timeIntervalSince1970: 1.5)))
    #expect(line.last == UInt8(ascii: "\n"))
    #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
    let decoded = try JSONDecoder().decode(AgentMessage.self, from: line.dropLast())
    #expect(decoded.type == "settime")
    #expect(decoded.unixNanos == 1_500_000_000)
}

@Test func lineReaderSplitsAndBuffers() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { close(fds[0]) }
    writeAll(Data("one\ntwo\npartial".utf8), to: fds[1])
    close(fds[1])
    let reader = LineReader(fd: fds[0])
    #expect(reader.readLine() == Data("one".utf8))
    #expect(reader.readLine() == Data("two".utf8))
    #expect(reader.readLine() == nil)  // unterminated tail at EOF is dropped
}

@Test func launchAgentPlistRunsDaemon() throws {
    let paths = Paths(root: URL(fileURLWithPath: "/Users/x/.dockma"), home: URL(fileURLWithPath: "/Users/x"))
    let agent = LaunchAgent(paths: paths, executable: "/opt/dockma/bin/dockma")
    let data = try agent.plist(autostart: false)
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == "io.dockma.daemon")
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/dockma/bin/dockma", "daemon"])
    #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    #expect(plist["StandardErrorPath"] as? String == "/Users/x/.dockma/logs/daemon.log")
    #expect(agent.plistURL(autostart: true).path == "/Users/x/Library/LaunchAgents/io.dockma.daemon.plist")
    #expect(agent.plistURL(autostart: false).path == "/Users/x/.dockma/io.dockma.daemon.plist")
}

@Test func launchAgentLabelIsPerStateDirectory() {
    let home = URL(fileURLWithPath: "/Users/x")
    let byDefault = Paths(root: home.appendingPathComponent(".dockma"), home: home)
    let scratch = Paths(root: URL(fileURLWithPath: "/tmp/scratch"), home: home)
    let other = Paths(root: URL(fileURLWithPath: "/tmp/other"), home: home)
    #expect(LaunchAgent.label(for: byDefault) == "io.dockma.daemon")
    // A trailing slash or `.` names the same directory.
    #expect(LaunchAgent.label(for: Paths(root: URL(fileURLWithPath: "/Users/x/./.dockma/"), home: home)) == "io.dockma.daemon")
    let label = LaunchAgent.label(for: scratch)
    #expect(label.hasPrefix("io.dockma.daemon.") && label.count == "io.dockma.daemon.".count + 8)
    #expect(label == LaunchAgent.label(for: scratch))
    #expect(label != LaunchAgent.label(for: other))
    let agent = LaunchAgent(paths: scratch, executable: "/x")
    #expect(agent.plistURL(autostart: false).path == "/tmp/scratch/\(label).plist")
}

@Test func legacyPlistOwnershipFollowsDockmaHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockma-legacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root, home: URL(fileURLWithPath: "/Users/x"))
    let agent = LaunchAgent(paths: paths, executable: "/x")
    let url = root.appendingPathComponent("legacy.plist")
    func write(_ environment: [String: String]) throws {
        let dict: [String: Any] = ["Label": "io.dockma.daemon", "EnvironmentVariables": environment]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }
    try write(["DOCKMA_HOME": root.path + "/"])
    #expect(agent.isPlist(url, ownedBy: paths))
    try write(["DOCKMA_HOME": "/elsewhere"])
    #expect(agent.isPlist(url, ownedBy: paths) == false)
    try write([:])  // the default state directory's job
    #expect(agent.isPlist(url, ownedBy: paths) == false)
}

/// A stale plist that names this DOCKMA_HOME must not get the default
/// instance's job booted out; only a job loaded from that plist may be.
@Test func legacyJobIsBootedOutOnlyWhenLoadedFromAnOwnedPlist() {
    let owned = [URL(fileURLWithPath: "/tmp/x/io.dockma.daemon.plist")]
    let fromOwned = "gui/501/io.dockma.daemon = {\n\tpath = /tmp/x/io.dockma.daemon.plist\n\tpid = 42\n}"
    let fromDefault = "gui/501/io.dockma.daemon = {\n\tpath = /Users/x/Library/LaunchAgents/io.dockma.daemon.plist\n\tpid = 42\n}"
    #expect(LaunchAgent.isJob(launchctlPrint: fromOwned, loadedFromOneOf: owned))
    #expect(LaunchAgent.isJob(launchctlPrint: fromDefault, loadedFromOneOf: owned) == false)
    #expect(LaunchAgent.isJob(launchctlPrint: "\tpid = 42\n", loadedFromOneOf: owned) == false)
}

@Test func symlinkedStateDirectoryGetsTheSameLabel() throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("dockma-link-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let link = base.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let home = URL(fileURLWithPath: "/Users/x")
    #expect(LaunchAgent.label(for: Paths(root: link, home: home)) == LaunchAgent.label(for: Paths(root: real, home: home)))
}

@Test func parsesPIDFromLaunchctlPrint() {
    let output = "gui/501/io.dockma.daemon = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tprogram = /x\n}"
    #expect(LaunchAgent.parsePID(launchctlPrint: output) == 4242)
    #expect(LaunchAgent.parsePID(launchctlPrint: "\tstate = not running\n") == nil)
    #expect(LaunchAgent.field("runs", launchctlPrint: "\tstate = not running\n\truns = 1\n\tlast exit code = 0\n") == "1")
}

@Test func jobThatRanWithoutProcessHasExited() {
    #expect(LaunchAgent.JobState(isLoaded: true, pid: nil, runCount: 1).hasExited)
    #expect(LaunchAgent.JobState(isLoaded: true, pid: nil, runCount: 0).hasExited == false)
    #expect(LaunchAgent.JobState(isLoaded: true, pid: 42, runCount: 1).hasExited == false)
    #expect(LaunchAgent.JobState(isLoaded: false, pid: nil).hasExited)
}

@Test func dockerHintDependsOnDockerHost() {
    let paths = Paths(root: URL(fileURLWithPath: "/Users/x/.dockma"), home: URL(fileURLWithPath: "/Users/x"))
    #expect(DockerContext.hint(paths: paths, environment: ["DOCKER_HOST": "unix:///Users/x/.dockma/docker.sock"]) == nil)
    #expect(DockerContext.hint(paths: paths, environment: ["DOCKER_HOST": "unix:///other.sock"])?.contains("overrides") == true)
    #expect(DockerContext.hint(paths: paths, environment: [:])?.contains("docker context use dockma") == true)
    let scratch = Paths(root: URL(fileURLWithPath: "/Users/x/.dockma-e2e"), home: URL(fileURLWithPath: "/Users/x"))
    #expect(DockerContext.hint(paths: scratch, environment: [:]) == "Use this dockma with: export DOCKER_HOST=unix:///Users/x/.dockma-e2e/docker.sock")
}

/// A daemon that predates UDP forwarding sends no `forwardedUDPPorts`.
@Test func decodesStatusWithoutUDPPorts() throws {
    let json = #"{"state":"running","pid":1,"startedAt":0,"cpus":2,"memoryMiB":1024,"agentConnected":true,"forwardedPorts":[8080],"warnings":[]}"#
    let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    #expect(status.forwardedUDPPorts == nil)
    #expect(status.version == nil)  // nor a version, before 0.4
    #expect(status.forwardedPortKeys == [ForwardedPort.Key(port: 8080, transport: .tcp)])

    var withUDP = status
    withUDP.forwardedUDPPorts = [53, 9000]
    let decoded = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(withUDP))
    #expect(decoded.forwardedPortKeys.map(\.description) == ["53/udp", "8080", "9000/udp"])
}

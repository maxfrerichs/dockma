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
    #expect(plist["Label"] as? String == LaunchAgent.label)
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/dockma/bin/dockma", "daemon"])
    #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    #expect(plist["StandardErrorPath"] as? String == "/Users/x/.dockma/logs/daemon.log")
    #expect(agent.plistURL(autostart: true).path == "/Users/x/Library/LaunchAgents/\(LaunchAgent.label).plist")
    #expect(agent.plistURL(autostart: false).path == "/Users/x/.dockma/\(LaunchAgent.label).plist")
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
}

/// A daemon that predates UDP forwarding sends no `forwardedUDPPorts`.
@Test func decodesStatusWithoutUDPPorts() throws {
    let json = #"{"state":"running","pid":1,"startedAt":0,"cpus":2,"memoryMiB":1024,"agentConnected":true,"forwardedPorts":[8080],"warnings":[]}"#
    let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    #expect(status.forwardedUDPPorts == nil)
    #expect(status.forwardedPortKeys == [ForwardedPort.Key(port: 8080, transport: .tcp)])

    var withUDP = status
    withUDP.forwardedUDPPorts = [53, 9000]
    let decoded = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(withUDP))
    #expect(decoded.forwardedPortKeys.map(\.description) == ["53/udp", "8080", "9000/udp"])
}

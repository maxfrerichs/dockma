import Foundation

/// File layout under the state directory (default `~/.dockma`).
public struct Paths: Sendable {
    public let root: URL
    /// The host home directory shared into the VM at the same path.
    public let home: URL

    public init(root: URL, home: URL) {
        self.root = root
        self.home = home
    }

    public static func `default`() -> Paths {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let root = ProcessInfo.processInfo.environment["DOCKMA_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".dockma", isDirectory: true)
        return Paths(root: root, home: home)
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var dataDisk: URL { root.appendingPathComponent("data.img") }
    public var dockerSocket: URL { root.appendingPathComponent("docker.sock") }
    public var controlSocket: URL { root.appendingPathComponent("control.sock") }
    public var shellSocket: URL { root.appendingPathComponent("shell.sock") }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var consoleLog: URL { logs.appendingPathComponent("console.log") }
    public var dockerLog: URL { logs.appendingPathComponent("docker.log") }
    public var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    public var guest: URL { root.appendingPathComponent("guest", isDirectory: true) }
    public var kernel: URL { guest.appendingPathComponent("Image") }
    public var initrd: URL { guest.appendingPathComponent("initramfs.cpio.zst") }

    public func createDirectories() throws {
        for dir in [root, logs, guest] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `sockaddr_un.sun_path` holds 104 bytes on macOS including the NUL.
    public static let maxSocketPathLength = 103

    /// Throws if a socket path is too long to bind, which happens with a
    /// deeply nested `DOCKMA_HOME`.
    public static func validateSocketPath(_ url: URL) throws {
        if url.path.utf8.count > maxSocketPathLength {
            throw DockmaError("socket path is longer than \(maxSocketPathLength) bytes: \(url.path)")
        }
    }
}

/// A user-facing error with a plain message.
public struct DockmaError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

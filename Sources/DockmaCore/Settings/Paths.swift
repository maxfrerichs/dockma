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

    /// Whether this is the default state directory (`~/.dockma`) rather than
    /// one chosen with `DOCKMA_HOME`. Resolves symlinks, so not O(1).
    public var isDefaultRoot: Bool {
        canonicalRootPath == Paths(root: home.appendingPathComponent(".dockma"), home: home).canonicalRootPath
    }

    /// The state directory's path with `.`, `..` and symlinks resolved, so
    /// `/tmp/x` and `/private/tmp/x` name one directory. Touches the file
    /// system, so not O(1).
    public var canonicalRootPath: String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var dataDisk: URL { root.appendingPathComponent("data.img") }
    public var dockerSocket: URL { root.appendingPathComponent("docker.sock") }
    public var controlSocket: URL { root.appendingPathComponent("control.sock") }
    public var shellSocket: URL { root.appendingPathComponent("shell.sock") }
    /// Held (flock) by the running daemon.
    public var daemonLock: URL { root.appendingPathComponent("daemon.lock") }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var consoleLog: URL { logs.appendingPathComponent("console.log") }
    public var dockerLog: URL { logs.appendingPathComponent("docker.log") }
    public var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    public var guest: URL { root.appendingPathComponent("guest", isDirectory: true) }
    /// The guest kernel: an uncompressed arm64 Image.
    public var kernel: URL { guest.appendingPathComponent("dockma-kernel") }
    /// The guest initramfs: a cpio archive compressed with legacy-format lz4.
    /// The kernel detects the compression itself, so the name doesn't carry it.
    public var initrd: URL { guest.appendingPathComponent("dockma-initrd.img") }
    /// The host↔guest protocol number the guest image was built for.
    public var guestProtocol: URL { guest.appendingPathComponent("guest-protocol") }
    /// Held (flock) by a running `dockma install`.
    public var guestInstallLock: URL { root.appendingPathComponent(".guest-install.lock") }

    /// Creates the state directories and keeps the root and logs private
    /// (0700) on every call, which also fixes older installs. The data disk
    /// and logs hold whatever containers store, and macOS home directories
    /// are often traversable by the `staff` group.
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, logs, guest] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Never change the mode of the home directory itself (DOCKMA_HOME=~).
        for dir in [root, logs] where dir.standardizedFileURL.path != home.standardizedFileURL.path {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        // An older install's config.json, which is only rewritten on change.
        if fm.fileExists(atPath: config.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
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

    /// An error for the failed call `what`, with the message for the current `errno`.
    static func posix(_ what: String) -> DockmaError {
        DockmaError("\(what): \(String(cString: strerror(errno)))")
    }
}

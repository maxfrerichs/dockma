import Foundation

/// Timestamped lines on stderr; launchd redirects it to logs/daemon.log.
public enum Log {
    public static func info(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        // The throwing variant: `write(_:)` raises an Objective-C exception
        // on a failed write (a full disk), which would abort the daemon and
        // hard-stop the VM over a log line.
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}

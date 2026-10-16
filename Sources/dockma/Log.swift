import Foundation

/// Timestamped lines on stderr; launchd redirects it to logs/daemon.log.
public enum Log {
    public static func info(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

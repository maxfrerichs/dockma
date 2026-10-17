import Foundation

/// Builds the guest kernel command line. The guest's rcS reads `dockma.home`
/// to mount the home share at the host path, and `dockma.state` to find the
/// user's guest overrides (daemon.json, CA certificates) in the state
/// directory, which the guest sees only when it lies under the home share.
public enum KernelCmdline {
    /// The command line for the home share at `home` and the state directory
    /// at `state`. `panic=5` reboots a panicked guest after 5 s, instead of
    /// a hung VM that still reports itself running. VZ reboots a Linux guest
    /// in place: the daemon keeps running and the agent reconnects.
    public static func build(home: String, state: String) -> String {
        [
            "console=hvc0",
            "rdinit=/init",
            "loglevel=4",
            "panic=5",
            "dockma.home=\(percentEncoded(home))",
            "dockma.state=\(percentEncoded(state))",
        ].joined(separator: " ")
    }

    /// Percent-encodes everything except `[A-Za-z0-9/._-]` so the value has no
    /// spaces or quotes; rcS decodes `%XX` with printf.
    static func percentEncoded(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

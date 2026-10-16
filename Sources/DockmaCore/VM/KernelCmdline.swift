import Foundation

/// Builds the guest kernel command line. The guest's rcS reads `dockma.home`
/// to mount the home share at the host path.
public enum KernelCmdline {
    public static func build(home: String) -> String {
        [
            "console=hvc0",
            "rdinit=/init",
            "loglevel=4",
            "dockma.home=\(percentEncoded(home))",
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

import Foundation
import Security

public enum Entitlements {
    public static let virtualization = "com.apple.security.virtualization"

    /// Whether the running binary carries the virtualization entitlement.
    /// `swift build` relinks the binary unsigned, which strips it.
    public static func hasVirtualization() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, virtualization as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }
}

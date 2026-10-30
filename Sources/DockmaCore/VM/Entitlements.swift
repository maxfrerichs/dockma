import Foundation
import Security

public enum Entitlements {
    public static let virtualization = "com.apple.security.virtualization"

    /// Whether the executable at `path` is signed with the virtualization
    /// entitlement. `swift build` relinks it unsigned, which strips it.
    public static func hasVirtualization(executable path: String) -> Bool {
        let info = CodeSigning.information(ofExecutable: path)
        let entitlements = info?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return (entitlements?[virtualization] as? Bool) == true
    }
}

/// The code signatures the CLI and the daemon check on each other.
public enum CodeSigning {
    /// The signing identifier of `dockma`, which `make build` passes to codesign.
    public static let cliIdentifier = "io.dockma.cli"
    /// The signing identifier of `dockmad`.
    public static let daemonIdentifier = "io.dockma.daemon"

    /// The requirement for a peer signed as `identifier`: that identifier,
    /// plus this process's team when it has one.
    // shortcut: an ad-hoc signature has no team, so until releases are
    // Developer ID signed any local process can claim the identifier.
    public static func requirement(forPeer identifier: String, team: String? = currentTeam()) -> String {
        let base = "identifier \"\(identifier)\""
        guard let team else { return base }
        return base + " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team identifier this process is signed with, or nil for an
    /// ad-hoc signature. Reads the signature from disk; not O(1).
    public static func currentTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        return information(of: staticCode)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The signing information of the executable at `path`, or nil if it
    /// doesn't exist or isn't signed.
    static func information(ofExecutable path: String) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return information(of: staticCode)
    }

    /// The signing information of `code`, entitlements included.
    private static func information(of code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            return nil
        }
        return info as? [String: Any]
    }
}

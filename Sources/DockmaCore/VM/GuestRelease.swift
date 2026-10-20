import CryptoKit
import Foundation

/// Downloads the published guest image (dockma-linux) of a release and
/// installs it into the guest directory.
public enum GuestRelease {
    /// The GitHub repository whose releases carry the guest.
    static let repository = "maxfrerichs/dockma"

    /// The files a guest tarball holds, as `guest.yml` packs them.
    static let files = ["dockma-kernel", "dockma-initrd.img", "guest-protocol"]

    /// The name prefix of an install's staging directory in the state directory.
    static let stagingPrefix = ".guest-install-"

    /// The release asset with the guest for `version`.
    public static func assetName(version: String) -> String {
        "dockma-linux-\(version)-arm64.tar.gz"
    }

    /// The directory holding the release's assets and `SHA256SUMS`:
    /// `DOCKMA_RELEASE_URL` (a URL, or an absolute path) if set, otherwise
    /// the GitHub release of `version`.
    public static func baseURL(version: String, environment: [String: String]) -> URL {
        if let override = environment["DOCKMA_RELEASE_URL"], !override.isEmpty {
            if override.hasPrefix("/") { return URL(fileURLWithPath: override, isDirectory: true) }
            if let url = URL(string: override) { return url }
        }
        return URL(string: "https://github.com/\(repository)/releases/download/\(version)/")!
    }

    /// The hex SHA-256 that a `sha256sum` listing gives for `name`, in text
    /// (`<hash>  <name>`) or binary (`<hash> *<name>`) mode.
    static func checksum(of name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            var file = fields[1].drop(while: { $0 == " " })
            if file.first == "*" { file = file.dropFirst() }
            if file == name { return fields[0].lowercased() }
        }
        return nil
    }

    /// Downloads the guest of `version` from `baseURL`, verifies it against
    /// the release's `SHA256SUMS` and this binary's guest protocol, and swaps
    /// it into `paths.guest`. The installed guest is left untouched on any
    /// failure. With `showsProgress`, curl draws a progress bar on stderr.
    /// Throws if another install holds the lock.
    public static func install(version: String, from baseURL: URL, paths: Paths, showsProgress: Bool = false) throws {
        try paths.createDirectories()
        // Close-on-exec, so a curl that outlives a killed install doesn't
        // keep holding the lock.
        let lockFD = try FileLock.acquire(at: paths.guestInstallLock, busyMessage: "another `dockma install` is running")
        defer { close(lockFD) }
        // A killed install skips its cleanup; with the lock held, every
        // staging directory left is such a leftover.
        try removeStagingDirectories(in: paths.root)
        let fm = FileManager.default
        // Under the state directory, so the final rename stays on one volume.
        let staging = paths.root.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let asset = assetName(version: version)
        let sumsFile = staging.appendingPathComponent("SHA256SUMS")
        let archive = staging.appendingPathComponent(asset)
        try download(baseURL.appendingPathComponent("SHA256SUMS"), to: sumsFile, showsProgress: false)
        try download(baseURL.appendingPathComponent(asset), to: archive, showsProgress: showsProgress)

        let sums = String(decoding: try Data(contentsOf: sumsFile), as: UTF8.self)
        guard let expected = checksum(of: asset, in: sums) else {
            throw DockmaError("the release's SHA256SUMS has no entry for \(asset)")
        }
        let actual = try sha256(of: archive)
        guard actual == expected else {
            throw DockmaError("\(asset) doesn't match its SHA256SUMS entry (got \(actual), expected \(expected))")
        }

        let guest = staging.appendingPathComponent("guest", isDirectory: true)
        try fm.createDirectory(at: guest, withIntermediateDirectories: false)
        try extract(archive, into: guest)

        let installed = GuestImage.installedProtocol(at: guest.appendingPathComponent("guest-protocol"))
        guard installed == GuestImage.protocolVersion else {
            throw DockmaError("dockma-linux \(version) speaks guest protocol \(installed), but this dockma needs \(GuestImage.protocolVersion)")
        }
        try exchange(guest, into: paths.guest, parkingIn: staging)
    }

    /// Deletes the staging directories directly inside `root`.
    private static func removeStagingDirectories(in root: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: root.path) where name.hasPrefix(stagingPrefix) {
            try fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Fetches `url` to `file` with curl, which follows redirects and reads `file://` too.
    private static func download(_ url: URL, to file: URL, showsProgress: Bool) throws {
        let arguments = ["-fL", "--retry", "2", "--proto-redir", "=https", showsProgress ? "--progress-bar" : "-sS",
                         "-o", file.path, url.absoluteString]
        let result = try Subprocess.run("/usr/bin/curl", arguments: arguments, inheritingStandardError: showsProgress)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockmaError("couldn't download \(url.absoluteString) (curl exit \(result.status)\(detail.isEmpty ? "" : ": \(detail)"))")
        }
    }

    /// The lowercase hex SHA-256 of `file`, read in chunks; O(file size).
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks `archive` into `directory`, which must end up holding exactly
    /// the guest files, each a regular file.
    private static func extract(_ archive: URL, into directory: URL) throws {
        let listing = try Subprocess.run("/usr/bin/tar", arguments: ["-tzf", archive.path])
        guard listing.status == 0 else {
            throw DockmaError("couldn't read \(archive.lastPathComponent): \(listing.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let entries = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard entries.sorted() == files.sorted() else {
            throw DockmaError("\(archive.lastPathComponent) holds \(entries.joined(separator: ", ")), expected \(files.joined(separator: ", "))")
        }
        let result = try Subprocess.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", directory.path] + files)
        guard result.status == 0 else {
            throw DockmaError("couldn't unpack \(archive.lastPathComponent): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for name in files {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw DockmaError("\(name) in \(archive.lastPathComponent) is not a regular file")
            }
        }
    }

    /// Moves `new` to `target`, exchanging the two atomically if `target`
    /// exists. The previous contents end up in `parking`.
    private static func exchange(_ new: URL, into target: URL, parkingIn parking: URL) throws {
        guard FileManager.default.fileExists(atPath: target.path) else {
            guard rename(new.path, target.path) == 0 else { throw DockmaError.posix("rename \(new.path)") }
            return
        }
        if renamex_np(new.path, target.path, UInt32(RENAME_SWAP)) == 0 { return }
        // Volumes without RENAME_SWAP: move the old guest aside first.
        guard errno == ENOTSUP || errno == EINVAL else { throw DockmaError.posix("swap \(target.path)") }
        let old = parking.appendingPathComponent("previous", isDirectory: true)
        guard rename(target.path, old.path) == 0 else { throw DockmaError.posix("rename \(target.path)") }
        guard rename(new.path, target.path) == 0 else {
            let failure = DockmaError.posix("rename \(new.path)")
            _ = rename(old.path, target.path)
            throw failure
        }
    }
}

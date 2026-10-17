/// The dockma release this binary belongs to.
public enum DockmaVersion {
    /// The version `dockma --version` prints: the newest released version in
    /// CHANGELOG.md, which a test checks. A release bumps it together with
    /// its CHANGELOG heading, and the release build checks it against the tag.
    public static let current = "0.1.0"
}

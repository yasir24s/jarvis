import Foundation

/// The settings' move to the new bundle ID. The app's defaults domain is its bundle ID, so under
/// `com.jarv1s.assistant` it starts empty. On the first launch under the new ID every key of the
/// old domain (`com.jarvis.assistant`) is copied into the new one, once: a marker key in the new
/// domain records that it has been done. A key the new domain already holds is left as it is.
/// The old domain is only read, never changed or removed: a rollback to the old build, and the
/// Python app, still use it.
public enum DefaultsMigration {
    /// Set in the new domain once the copy has run (whether or not the old domain had keys).
    public static let markerKey = "migratedFromLegacyBundleID"

    /// Copies `legacy`'s keys into `current` unless `current` holds the marker. Returns the
    /// number of keys copied, or nil when the marker was already there and nothing was done.
    @discardableResult
    public static func run(from legacy: String = AppIdentity.legacyBundleID,
                           to current: String = AppIdentity.bundleID,
                           defaults: UserDefaults = .standard) -> Int? {
        var target = defaults.persistentDomain(forName: current) ?? [:]
        if target[markerKey] as? Bool == true { return nil }
        let source = defaults.persistentDomain(forName: legacy) ?? [:]
        var copied = 0
        for (key, value) in source where key != markerKey && target[key] == nil {
            target[key] = value
            copied += 1
        }
        target[markerKey] = true
        defaults.setPersistentDomain(target, forName: current)
        return copied
    }

    /// The launch-time call: only inside the app bundle under the new ID, so `swift test` and
    /// any other host never read or write the real domains.
    @discardableResult
    public static func runAtLaunch(bundle: Bundle = .main) -> Int? {
        guard bundle.bundleIdentifier == AppIdentity.bundleID else { return nil }
        return run()
    }
}

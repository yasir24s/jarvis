import Foundation

/// The app's own identity. The bundle ID moved to `com.jarv1s.assistant` with the Developer ID
/// signing (Apple had given `com.jarvis.assistant` to another developer, so ShazamKit and
/// MusicKit could not be granted to it). The old ID is still the name of the keychain items,
/// the log subsystem, the LaunchAgent label and the Python app's bundle, and its defaults domain
/// is where the settings are copied from on the first launch under the new ID.
public enum AppIdentity {
    /// The bundle ID the app runs as.
    public static let bundleID = "com.jarv1s.assistant"
    /// The bundle ID the app ran as before the move (and the Python app's).
    public static let legacyBundleID = "com.jarvis.assistant"
}

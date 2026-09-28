import Foundation

public enum StatePathsError: Error, Sendable, Equatable {
    case notInAppBundle(bundleID: String?)
    case notAJarvisRepo(URL)
}

/// Every on-disk state file Python JARVIS uses, resolved against one root (the repo, `HERE`
/// in jarvis.py). Relative names are golden-tested against Python (`paths` suite).
public struct StatePaths: Sendable, Equatable {
    public let root: URL

    /// No validation — for tests and sandboxes.
    public init(root: URL) {
        self.root = root
    }

    /// The real state root. Order: env JARVIS_HOME, else <bundle>/../../.. (native/dist/JARVIS.app → repo).
    /// Throws unless root/jarvis.py is a file and root/research is a directory, and throws
    /// .notInAppBundle unless bundle.bundleIdentifier == "com.jarvis.assistant" (tripwire:
    /// under `swift test` the main bundle is the test runner, so tests can never reach real state).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                            bundle: Bundle = .main) throws -> StatePaths {
        // Checked first, before anything touches the filesystem.
        guard bundle.bundleIdentifier == appBundleID else {
            throw StatePathsError.notInAppBundle(bundleID: bundle.bundleIdentifier)
        }
        let root: URL
        if let home = environment["JARVIS_HOME"], !home.isEmpty {
            root = URL(filePath: home, directoryHint: .isDirectory)
        } else {
            root = bundle.bundleURL
                .deletingLastPathComponent()   // native/dist
                .deletingLastPathComponent()   // native
                .deletingLastPathComponent()   // repo
        }
        let paths = StatePaths(root: root.standardizedFileURL)
        guard isEntry(paths.jarvisPy, directory: false),
              isEntry(paths.researchDir, directory: true) else {
            throw StatePathsError.notAJarvisRepo(paths.root)
        }
        return paths
    }

    public var knowledge: URL { file("knowledge.json") }            // KB_FILE
    public var history: URL { file("history.json") }                // HIST_FILE
    public var corrections: URL { file("corrections.json") }        // CORR_FILE
    public var changelog: URL { file("CHANGELOG.md") }              // CHANGELOG_FILE
    public var profile: URL { file("profile.json") }                // PROFILE_FILE
    public var personality: URL { file("personality.json") }        // PERSONALITY_FILE
    public var emotions: URL { file("emotions.json") }              // EMOTIONS_FILE
    public var proactive: URL { file("proactive.json") }            // PROACTIVE_FILE
    public var alarms: URL { file("alarms.json") }                  // ALARMS_FILE
    public var voiceprint: URL { file("voiceprint.npy") }           // VOICEPRINT_FILE
    public var researchDir: URL {                                   // RESEARCH_DIR
        root.appending(path: "research", directoryHint: .isDirectory)
    }
    public var researchMetrics: URL { file("research/metrics.jsonl") } // RESEARCH_METRICS
    public var researchUsage: URL { file("research/usage.json") }   // RESEARCH_USAGE
    public var notesFallback: URL { file("jarvis_notes.txt") }      // jarvis.py:3976
    public var auddKey: URL { file("audd_key.txt") }                // jarvis.py:4118
    public var logFile: URL { file("logs/jarvis.log") }             // LOG_FILE
    public var lockFile: URL { file(".jarvis.lock") }               // new in native
    public var jarvisPy: URL { file("jarvis.py") }                  // read by the research snapshot

    private static let appBundleID = "com.jarvis.assistant"

    private func file(_ relative: String) -> URL {
        root.appending(path: relative, directoryHint: .notDirectory)
    }

    private static func isEntry(_ url: URL, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue == directory
    }
}

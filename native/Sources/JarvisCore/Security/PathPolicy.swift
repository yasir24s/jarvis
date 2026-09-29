import Foundation

public enum PathPolicy {
    public static let systemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt"]
    public static let persistenceFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile"]
    public static let persistenceDirectories = ["Library/LaunchAgents", ".ssh", "Library/Keychains", ".claude"]
    public static let sensitivePaths = ["/.ssh", "id_rsa", "id_ed25519", "/library/keychains", "keychain-db", "login.keychain", "/library/messages", ".aws/credentials", ".config/gh/hosts", "/cookies", ".jarvis_config", "audd_key", "voiceprint", "/com.apple.tcc"]

    public static func pyAbspath(_ p: String, cwd: String) -> String {
        let candidate = p.isEmpty ? "." : p
        let joined = candidate.hasPrefix("/") ? candidate : "\(cwd)/\(candidate)"
        return normalize(joined)
    }

    public static func inHome(_ p: String, home: String, cwd: String) -> Bool {
        let path = pyAbspath(p, cwd: cwd)
        let root = pyAbspath(home, cwd: cwd)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public static func isSystemPath(_ p: String, home: String, cwd: String) -> Bool {
        let path = pyAbspath(p, cwd: cwd)
        let homePath = pyAbspath(home, cwd: cwd)
        return path == "/" || path == homePath || systemRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public static func isSensitive(_ p: String?) -> Bool {
        let value = (p ?? "").lowercased()
        return sensitivePaths.contains(where: value.contains)
    }

    public static func resolvedIsSystemPath(_ p: String, home: String) -> Bool {
        let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        return isSystemPath(resolved, home: home, cwd: "/")
    }

    static func isPersistencePath(_ p: String, home: String, cwd: String) -> Bool {
        let path = URL(fileURLWithPath: pyAbspath(p, cwd: cwd)).resolvingSymlinksInPath().path.lowercased()
        let homePath = URL(fileURLWithPath: pyAbspath(home, cwd: cwd)).resolvingSymlinksInPath().path.lowercased()
        let files = persistenceFiles.map { homePath + "/" + $0.lowercased() }
        let dirs = persistenceDirectories.map { homePath + "/" + $0.lowercased() }
        return files.contains(path) || dirs.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    private static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty && stack.last != ".." { stack.removeLast() }
                else if !absolute { stack.append(component) }
            } else {
                stack.append(component)
            }
        }
        let body = stack.map(String.init).joined(separator: "/")
        if absolute { return body.isEmpty ? "/" : "/" + body }
        return body.isEmpty ? "." : body
    }
}

import Foundation

public enum FileOp: Equatable, Sendable {
    case trash(String)
    case hardDelete(String)
    case move(String, String)
    case write(String)
}

public enum FileDecision: Equatable, Sendable {
    case notFound(String)
    case refuse(String)
    case instant(FileOp)
    case gate(desc: String, op: FileOp)
}

public protocol FileProbe: Sendable {
    func exists(_ p: String) -> Bool
    func isDir(_ p: String) -> Bool
}

public enum FileMutationPolicy {
    public static func delete(path: String, permanent: Bool, probe: FileProbe, home: String, cwd: String) -> FileDecision {
        let expanded = expand(path, home: home)
        guard !expanded.isEmpty, probe.exists(expanded) else { return .notFound("I can't find \(path), sir.") }
        let absolute = PathPolicy.pyAbspath(expanded, cwd: cwd)
        if systemPath(absolute, home: home, cwd: cwd) { return .refuse("I won't delete that, sir — it's a protected system location.") }
        if !permanent && PathPolicy.inHome(absolute, home: home, cwd: cwd) && !isWindows {
            // DEV-OD3-01 (D-41): a folder goes to the Trash only after confirmation. Python trashes
            // it at once, so "wipe my documents" could empty ~/Documents with no question asked.
            if probe.isDir(expanded) {
                let name = URL(fileURLWithPath: absolute).lastPathComponent
                return .gate(desc: "That will move the folder \(name) and everything in it to the Trash",
                             op: .trash(absolute))
            }
            return .instant(.trash(absolute))
        }
        let whereText = PathPolicy.inHome(absolute, home: home, cwd: cwd)
            ? "permanently (bypassing the Trash)" : "outside your home folder"
        return .gate(desc: "That will delete \(URL(fileURLWithPath: absolute).lastPathComponent) \(whereText)", op: .hardDelete(absolute))
    }

    public static func move(src: String, dst: String, probe: FileProbe, home: String, cwd: String) -> FileDecision {
        let source = expand(src, home: home)
        let destination = expand(dst, home: home)
        guard !source.isEmpty, probe.exists(source) else { return .notFound("I can't find \(src), sir.") }
        let sourceAbsolute = PathPolicy.pyAbspath(source, cwd: cwd)
        let destinationAbsolute = PathPolicy.pyAbspath(destination, cwd: cwd)
        if systemPath(sourceAbsolute, home: home, cwd: cwd) || systemPath(destinationAbsolute, home: home, cwd: cwd) {
            return .refuse("I won't move to or from a system location, sir.")
        }
        let sourceName = URL(fileURLWithPath: sourceAbsolute).lastPathComponent
        let clobber = probe.exists(destination)
        let into = probe.isDir(destination) ? destinationAbsolute + "/" + sourceName : destinationAbsolute
        if PathPolicy.isPersistencePath(destinationAbsolute, home: home, cwd: cwd) || PathPolicy.isPersistencePath(into, home: home, cwd: cwd) {
            return .gate(desc: "That will move \(sourceName) into a startup or credential location", op: .move(sourceAbsolute, destinationAbsolute))
        }
        if clobber { return .gate(desc: "That will overwrite \(URL(fileURLWithPath: destinationAbsolute).lastPathComponent)", op: .move(sourceAbsolute, destinationAbsolute)) }
        if !PathPolicy.inHome(sourceAbsolute, home: home, cwd: cwd) || !PathPolicy.inHome(destinationAbsolute, home: home, cwd: cwd) {
            return .gate(desc: "That will move \(sourceName) outside your home folder", op: .move(sourceAbsolute, destinationAbsolute))
        }
        return .instant(.move(sourceAbsolute, destinationAbsolute))
    }

    public static func write(path: String, probe: FileProbe, writtenThisSession: Set<String>, home: String, cwd: String) -> FileDecision {
        let expanded = expand(path, home: home)
        guard !expanded.isEmpty else { return .refuse("Which file, sir?") }
        let absolute = PathPolicy.pyAbspath(expanded, cwd: cwd)
        if systemPath(absolute, home: home, cwd: cwd) { return .refuse("I won't write to a system location, sir.") }
        let exists = probe.exists(expanded)
        if PathPolicy.isPersistencePath(absolute, home: home, cwd: cwd) {
            return .gate(desc: "That will write \(URL(fileURLWithPath: absolute).lastPathComponent), a startup or credential file", op: .write(absolute))
        }
        if !exists || writtenThisSession.contains(absolute) || PathPolicy.inHome(absolute, home: home, cwd: cwd) {
            return .instant(.write(absolute))
        }
        return .gate(desc: "That will overwrite \(URL(fileURLWithPath: absolute).lastPathComponent) outside your home folder", op: .write(absolute))
    }

    private static let isWindows = false

    private static func expand(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst()) }
        return trimmed
    }

    private static func systemPath(_ path: String, home: String, cwd: String) -> Bool {
        PathPolicy.isSystemPath(path, home: home, cwd: cwd) || PathPolicy.resolvedIsSystemPath(path, home: home)
    }
}

import Foundation

public struct SudoAllowlist: Sendable {
    public let patterns: [PyRegex]
    private let rawPatterns: [String]

    private init(rawPatterns: [String]) {
        self.rawPatterns = rawPatterns
        self.patterns = rawPatterns.map { try! PyRegex($0, ignoreCase: true) }
    }

    public static let python = SudoAllowlist(rawPatterns: PyShellRisk.sudoAllowPatterns)

    public static func effective(sudoersFile: URL?) -> SudoAllowlist {
        let fallback = PyShellRisk.sudoAllowPatterns.filter { !$0.contains(#"periodic"#) }
        guard let url = sudoersFile, let source = try? String(contentsOf: url, encoding: .utf8) else {
            return SudoAllowlist(rawPatterns: fallback)
        }
        let entries = parseSudoersEntries(source)
        guard !entries.isEmpty else { return SudoAllowlist(rawPatterns: fallback) }
        let patterns = entries.map(sudoersEntryPattern)
        return SudoAllowlist(rawPatterns: patterns)
    }

    public func allows(_ segment: String) -> Bool {
        patterns.contains { $0.search(segment.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
    }

    private static func parseSudoersEntries(_ source: String) -> [String] {
        var collecting = false
        var entries: [String] = []
        for raw in source.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("Cmnd_Alias") && line.contains("=") { collecting = true }
            guard collecting else { continue }
            let part = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? line
            let cleaned = part.replacingOccurrences(of: "\\", with: "")
            for entry in cleaned.split(separator: ",") {
                let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !value.contains("ALL=") && !value.hasPrefix("yasir24s ") {
                    entries.append(value)
                }
            }
            if !line.hasSuffix("\\") { collecting = false }
        }
        return entries
    }

    private static func sudoersEntryPattern(_ entry: String) -> String {
        let tokens = entry.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = tokens.first else { return #"^sudo\s+\bnever-match\b$"# }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let args = tokens.dropFirst().joined(separator: " ")
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        if args.isEmpty {
            return "^sudo\\s+\(escapedName)(?:\\s+.*)?$"
        }
        if args == "\"\"" {
            return "^sudo\\s+\(escapedName)\\s*$"
        }
        if args == "*" {
            return "^sudo\\s+\(escapedName)(?:\\s+.*)?$"
        }
        let escapedArgs = NSRegularExpression.escapedPattern(for: args).replacingOccurrences(of: "\\*", with: ".*")
        return "^sudo\\s+\(escapedName)\\s+\(escapedArgs)\\s*$"
    }
}

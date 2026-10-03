import Foundation
import JarvisCore

/// `make_note`, Python's `_make_note` (jarvis.py 3982-3996, the macOS branch): a new note in Apple
/// Notes through AppleScript (Notes has no public framework).
struct MakeNote: ToolImpl {
    static let name = "make_note"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let runner: any StdinCommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let text = Py.strip(try PyArgs.stringOrEmpty(args, "text", method: "strip"))
        if text.isEmpty { return .text("What should the note say, sir?") }
        let out = await AppleScriptRunner(runner: runner).run(
            "tell application \"Notes\" to make new note with properties {body:\"\(AppleScriptText.escape(text))\"}")
        return .text(AppleScriptText.mentionsError(out) ? "I couldn't save the note, sir." : "Note saved, sir.")
    }
}

/// Python's Shortcuts helpers (jarvis.py `_shortcuts_all` 3479, `_match_shortcut` 3489): the
/// `shortcuts` command line, found on the agent PATH (there is no public API that lists or runs
/// a user's shortcuts).
struct ShortcutsCLI: Sendable {
    let runner: any CommandRunning
    let executable: @Sendable (String) -> String?

    /// `_shortcuts_all`: the stripped, non-empty lines of `shortcuts list` (10 s), or none when
    /// the command is missing or the run fails in any way.
    func all() async -> [String] {
        guard let cli = executable("shortcuts"), let list = await runner.run([cli, "list"], timeout: 10), list.completed,
              PyText.decodeError(list.stderr) == nil, let text = PyText.decode(list.stdout) else { return [] }
        return Py.splitlines(text).map { Py.strip($0) }.filter { !$0.isEmpty }
    }

    /// `_match_shortcut`'s choice among `names` for the lowered, stripped `n`: exact, then the
    /// shortest name either contains or is contained by `n`, then the best token overlap of at
    /// least one half (the first best wins). Compared by code points, as Python.
    static func match(_ n: String, in names: [String]) -> String? {
        if n.isEmpty || names.isEmpty { return nil }
        if let exact = names.first(where: { Py.eq(Py.lower($0), n) }) { return exact }
        let subs = names.filter { Py.contains(Py.lower($0), n) || Py.contains(n, Py.lower($0)) }
        if let shortest = subs.min(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }) { return shortest }
        let tokens = Set(Py.split(n).map { Array($0.unicodeScalars) })
        var best: String?, score = 0.0
        for name in names {
            let words = Set(Py.split(Py.lower(name)).map { Array($0.unicodeScalars) })
            let overlap = Double(tokens.intersection(words).count) / Double(max(1, tokens.union(words).count))
            if overlap > score { best = name; score = overlap }
        }
        return score >= 0.5 ? best : nil
    }
}

/// `run_shortcut`, Python's `_run_shortcut` (jarvis.py 3511-3527): `shortcuts run NAME` (60 s) for
/// the best match. An executor: the taint guard refuses it after untrusted reads.
struct RunShortcut: ToolImpl {
    static let name = "run_shortcut"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let shortcuts: ShortcutsCLI
    var log: @Sendable (String) -> Void = { _ in }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let raw = args["name"] ?? .string("")
        let n = Py.strip(Py.lower(try PyArgs.stringOrEmpty(args, "name", method: "lower")))
        let names = await shortcuts.all()
        guard let match = ShortcutsCLI.match(n, in: names), let cli = shortcuts.executable("shortcuts") else {
            return .text("I couldn't find a shortcut matching \(PyArgs.str(raw)), sir.")
        }
        guard let result = await shortcuts.runner.run([cli, "run", match], timeout: 60) else {
            return .text("Shortcut error: command could not be started")
        }
        if result.timedOut { return .text("The \(match) shortcut is taking a while, sir — it may still be running.") }
        if let code = result.launchErrno {
            return .text("Shortcut error: [Errno \(code)] \(String(cString: strerror(code))): 'shortcuts'")
        }
        // text=True decodes both streams before the exit status is looked at.
        if let error = PyText.decodeError(result.stdout) ?? PyText.decodeError(result.stderr) {
            return .text("Shortcut error: \(error)")
        }
        if result.status == 0 {
            log("RAN shortcut")
            return .text("Done, sir.")
        }
        return .text("The \(match) shortcut failed, sir.")
    }
}

/// `list_shortcuts`, Python's `_list_shortcuts` (jarvis.py 3529-3535): the first 15 names.
struct ListShortcuts: ToolImpl {
    static let name = "list_shortcuts"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let shortcuts: ShortcutsCLI

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let names = await shortcuts.all()
        if names.isEmpty { return .text("You have no shortcuts set up, sir.") }
        let more = names.count > 15 ? ", and \(names.count - 15) more" : ""
        return .text("Your shortcuts: \(names.prefix(15).joined(separator: ", "))\(more).")
    }
}

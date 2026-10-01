import CoreGraphics
import Foundation
import JarvisCore

protocol KeyboardPosting: Sendable {
    func permitted() -> Bool
    func key(_ code: CGKeyCode) -> Bool
    func unicode(_ units: [UniChar]) -> Bool
}

struct LiveKeyboard: KeyboardPosting {
    func permitted() -> Bool { CGPreflightPostEventAccess() }
    func key(_ code: CGKeyCode) -> Bool { post(code: code, units: nil) }
    func unicode(_ units: [UniChar]) -> Bool { post(code: 0, units: units) }
    private func post(code: CGKeyCode, units: [UniChar]?) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        if let units {
            units.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

struct TypeText: ToolImpl {
    static let name = "type_text"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let denied = "I need Accessibility permission to type, sir — grant it in Privacy and Security settings."
    let keyboard: any KeyboardPosting

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let raw = try PyArgs.stringOrEmpty(args, "text", method: "rstrip")
        let text = String(String.UnicodeScalarView(raw.unicodeScalars.reversed().drop(while: Py.isSpace).reversed()))
        guard !text.isEmpty else { return .text("Nothing to type, sir.") }
        guard keyboard.permitted() else { return .text(Self.denied) }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            for units in Self.chunks(line) {
                guard keyboard.unicode(units) else { return .text(Self.denied) }
            }
            if index < lines.count - 1, !keyboard.key(36) { return .text(Self.denied) }
        }
        return .text("Typed, sir.")
    }

    /// CGEvent's short Unicode payload must never split a UTF-16 surrogate pair.
    static func chunks(_ line: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = [], current: [UniChar] = []
        for scalar in line.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > 20 { chunks.append(current); current = [] }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

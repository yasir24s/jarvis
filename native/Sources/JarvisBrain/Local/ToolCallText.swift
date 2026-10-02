import Foundation
import JarvisTools

// The on-device model sometimes writes a tool call into its reply instead of making one:
// "run_command: read_file ..." on a line of its own, or a JSON object that names a tool. This
// brain has no text tool protocol, so that text does nothing, and spoken aloud it is noise.
// LocalBrain runs each streamed reply through this before the sink, the sentence splitter and
// the history see it.

/// Takes pseudo tool calls out of a reply as it streams, however the text is cut into pieces.
/// Two shapes go. A line that starts with a known tool name and a colon, through its newline.
/// A JSON object with a known tool name in it as a quoted string, wherever it starts. Anything
/// else, including text that only looks like those, comes out unchanged.
///
/// Text that might still turn into one of those is held until it cannot: at a line start, a
/// run of lowercase letters that is still the beginning of a tool name (a tool name's length at
/// most); after a `{`, the rest of the object. `finish` hands back whatever is still held, and
/// removes an object that was cut off while it already named a tool.
public struct ToolCallTextFilter: Sendable {
    /// Every tool JARVIS has: the Python catalog's and the native memory tools'.
    public static let knownToolNames: Set<String> = DataSourceMap.allTools.union(NativeToolCatalog.memoryToolNames)

    /// Lines removed so far.
    public private(set) var lines = 0
    /// JSON objects removed so far.
    public private(set) var objects = 0
    /// Unicode scalars removed so far, newlines included.
    public private(set) var characters = 0

    public var removed: Bool { lines > 0 || objects > 0 }

    private enum State {
        /// At the start of a line, deciding whether it is a tool call.
        case lineStart
        /// In a line that is text.
        case text
        /// In a tool call line, dropping it through its newline.
        case dropLine
        /// In a JSON object that might be a tool call.
        case object
    }

    private let names: Set<String>
    private var state = State.lineStart
    /// At a line start: the indentation, the name and the gap after it, as read so far, to give
    /// back if it is not a tool call. In an object: the object so far.
    private var held: [Unicode.Scalar] = []
    /// At a line start: the name part of `held`.
    private var word = ""
    /// At a line start: a space or tab has followed the name.
    private var gapped = false
    private var depth = 0
    private var inString = false
    private var escaped = false

    public init(toolNames: Set<String> = ToolCallTextFilter.knownToolNames) {
        names = toolNames
    }

    /// The part of `text`, and of what came before it, that is safe to show now.
    public mutating func push(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { step(scalar, &out) }
        return String(out)
    }

    /// What is still held when the reply ends. The filter is for one reply: start another.
    public mutating func finish() -> String {
        var out = String.UnicodeScalarView()
        switch state {
        case .lineStart: out.append(contentsOf: held)
        case .object: closeObject(into: &out)
        case .text, .dropLine: break
        }
        resetLine()
        state = .lineStart
        return String(out)
    }

    private mutating func step(_ c: Unicode.Scalar, _ out: inout String.UnicodeScalarView) {
        switch state {
        case .text:
            if c == "\n" {
                out.append(c)
                state = .lineStart
            } else if c == "{" {
                held = [c]
                depth = 1
                inString = false
                escaped = false
                state = .object
            } else {
                out.append(c)
            }
        case .lineStart:
            if c == ":", names.contains(word) {
                characters += held.count + 1
                lines += 1
                resetLine()
                state = .dropLine
            } else if c == " " || c == "\t", word.isEmpty || names.contains(word) {
                held.append(c)               // indentation, or a gap between the name and its colon
                gapped = !word.isEmpty
            } else if !gapped, Self.isNameScalar(c) {
                held.append(c)
                word.unicodeScalars.append(c)
                if !names.contains(where: { $0.hasPrefix(word) }) { release(into: &out) }
            } else {
                release(into: &out)
                step(c, &out)
            }
        case .dropLine:
            characters += 1
            if c == "\n" { state = .lineStart }
        case .object:
            held.append(c)
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { closeObject(into: &out) }
            }
        }
    }

    /// Gives back what the line start held, as text, and carries on in the line.
    private mutating func release(into out: inout String.UnicodeScalarView) {
        out.append(contentsOf: held)
        resetLine()
        state = .text
    }

    private mutating func resetLine() {
        held = []
        word = ""
        gapped = false
    }

    /// The object, whole or cut off, is dropped if it holds a quoted tool name (as the value
    /// of "name", of "tool", or as a key, whichever shape the model used) and kept as text if not.
    private mutating func closeObject(into out: inout String.UnicodeScalarView) {
        let object = String(String.UnicodeScalarView(held))
        if names.contains(where: { object.contains("\"\($0)\"") }) {
            objects += 1
            characters += held.count
        } else {
            out.append(contentsOf: held)
        }
        held = []
        depth = 0
        inString = false
        escaped = false
        state = .text
    }

    /// Tool names are lowercase letters and underscores.
    private static func isNameScalar(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || c == "_"
    }
}

import Foundation

public struct ShellSegment: Sendable, Equatable {
    public let text: String
    public let depth: Int

    public init(text: String, depth: Int) {
        self.text = text
        self.depth = depth
    }
}

public enum ShellParseError: Error, Sendable, Equatable {
    case unbalancedQuote
    case unbalancedSubstitution
    case tooDeep
    case danglingEscape
}

public enum ShellSegmenter {
    public static func segments(_ line: String) -> Result<[ShellSegment], ShellParseError> {
        var index = 0
        do { return .success(try parse(Array(line), index: &index, depth: 0, closing: nil)) }
        catch let error as ShellParseError { return .failure(error) }
        catch { return .failure(.unbalancedSubstitution) }
    }

    /// Each substitution gets a fresh quote context: outer double quotes do not quote
    /// the command inside $(). Keep original text for the Python-compatible regexes.
    private static func parse(_ chars: [Character], index: inout Int, depth: Int,
                              closing: Character?) throws -> [ShellSegment] {
        guard depth <= 8 else { throw ShellParseError.tooDeep }
        var pieces: [ShellSegment] = []
        var nested: [ShellSegment] = []
        var buffer = ""
        var quote: Character?
        var parentheses = 0

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(ShellSegment(text: text, depth: depth)) }
            buffer.removeAll(keepingCapacity: true)
        }

        while index < chars.count {
            let c = chars[index]
            if quote == "'" {
                buffer.append(c)
                if c == "'" { quote = nil }
                index += 1
                continue
            }
            if c == "\\" {
                buffer.append(c)
                index += 1
                guard index < chars.count else { throw ShellParseError.danglingEscape }
                // In double quotes, backslash only escapes these shell characters.
                if quote == nil || ["$", "`", "\"", "\\", "\n"].contains(chars[index]) {
                    buffer.append(chars[index])
                    index += 1
                }
                continue
            }
            if quote == nil, c == closing, parentheses == 0 {
                flush()
                index += 1
                return pieces + nested
            }

            let startsSubstitution = index + 1 < chars.count && chars[index + 1] == "("
                && (c == "$" || (quote == nil && (c == "<" || c == ">")))
            if c == "`" || startsSubstitution {
                let start = index
                index += c == "`" ? 1 : 2
                nested += try parse(chars, index: &index, depth: depth + 1,
                                    closing: c == "`" ? "`" : ")")
                buffer += String(chars[start..<index])
                continue
            }
            if c == "\"" || (quote == nil && c == "'") {
                quote = quote == c ? nil : c
                buffer.append(c)
                index += 1
                continue
            }
            if quote == nil, closing == ")" {
                if c == "(" { parentheses += 1 }
                if c == ")" { parentheses -= 1 }
            }
            if quote == nil && (c == ";" || c == "\n" || c == "&" || c == "|") {
                flush()
                if (c == "&" || c == "|") && index + 1 < chars.count && chars[index + 1] == c {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            buffer.append(c)
            index += 1
        }

        if quote != nil { throw ShellParseError.unbalancedQuote }
        if closing != nil { throw ShellParseError.unbalancedSubstitution }
        flush()
        return pieces + nested
    }
}

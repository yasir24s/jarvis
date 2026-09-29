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
}

public enum ShellSegmenter {
    public static func segments(_ line: String) -> Result<[ShellSegment], ShellParseError> {
        parse(line, depth: 0)
    }

    private static func parse(_ line: String, depth: Int) -> Result<[ShellSegment], ShellParseError> {
        guard depth <= 8 else { return .failure(.tooDeep) }
        let chars = Array(line)
        var pieces: [ShellSegment] = []
        var nested: [ShellSegment] = []
        var buffer = ""
        var quote: Character?
        var escaped = false
        var index = 0

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(ShellSegment(text: text, depth: depth)) }
            buffer.removeAll(keepingCapacity: true)
        }

        while index < chars.count {
            let c = chars[index]
            if escaped {
                buffer.append(c)
                escaped = false
                index += 1
                continue
            }
            if c == "\\" {
                buffer.append(c)
                escaped = true
                index += 1
                continue
            }
            if let active = quote {
                buffer.append(c)
                if c == active { quote = nil }
                index += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                buffer.append(c)
                index += 1
                continue
            }

            if c == "`" {
                guard let close = chars[(index + 1)...].firstIndex(of: "`") else {
                    return .failure(.unbalancedSubstitution)
                }
                let body = String(chars[(index + 1)..<close])
                switch parse(body, depth: depth + 1) {
                case .failure(let error): return .failure(error)
                case .success(let values): nested.append(contentsOf: values)
                }
                buffer += String(chars[index...close])
                index = close + 1
                continue
            }

            let startsSubstitution = c == "$" && index + 1 < chars.count && chars[index + 1] == "("
                || (c == "<" || c == ">") && index + 1 < chars.count && chars[index + 1] == "("
            if startsSubstitution {
                let open = c == "$" ? index + 1 : index
                var cursor = open + 1
                var level = 1
                var innerQuote: Character?
                var innerEscaped = false
                while cursor < chars.count {
                    let inner = chars[cursor]
                    if innerEscaped { innerEscaped = false; cursor += 1; continue }
                    if inner == "\\" { innerEscaped = true; cursor += 1; continue }
                    if let q = innerQuote {
                        if inner == q { innerQuote = nil }
                        cursor += 1
                        continue
                    }
                    if inner == "'" || inner == "\"" { innerQuote = inner; cursor += 1; continue }
                    if inner == "(" { level += 1 }
                    if inner == ")" {
                        level -= 1
                        if level == 0 { break }
                    }
                    cursor += 1
                }
                guard cursor < chars.count, level == 0 else {
                    return .failure(.unbalancedSubstitution)
                }
                let bodyStart = open + 1
                let body = String(chars[bodyStart..<cursor])
                switch parse(body, depth: depth + 1) {
                case .failure(let error): return .failure(error)
                case .success(let values): nested.append(contentsOf: values)
                }
                buffer += String(chars[index...cursor])
                index = cursor + 1
                continue
            }

            if c == ";" || c == "\n" || c == "&" || c == "|" {
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

        if quote != nil { return .failure(.unbalancedQuote) }
        if escaped { buffer.append("\\") }
        flush()
        return .success(pieces + nested)
    }
}

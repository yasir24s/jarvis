import Foundation
import JarvisCore

/// `plistlib`'s XML reader (`_PlistParser`), ported onto Foundation's SAX parser so an XML
/// Info.plist that Python refuses is refused here too. CoreFoundation is more lenient: it reads
/// `<key>` elements inside an `<array>` as strings, where plistlib raises "unexpected key"
/// (found on a real app bundle; A-APP-1). Same state machine: character data is collected per
/// element, `add_object` places each value by the current key and the open container, and the
/// same shapes raise.
final class PlistXML: NSObject, XMLParserDelegate {
    private enum Container {
        case dict([String: PlistValue])
        case array([PlistValue])
    }

    private var stack: [Container] = []
    private var currentKey: String?
    private var root: PlistValue?
    private var data = ""
    private var failed = false

    /// The root object, `.none` for a document with none (plistlib returns None), or nil where
    /// plistlib raises (malformed XML, an entity declaration, a misplaced element, a value its
    /// converters reject).
    static func parse(_ bytes: Data) -> PlistValue? {
        let reader = PlistXML()
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse(), !reader.failed, reader.stack.isEmpty else { return nil }
        return reader.root ?? PlistValue.none
    }

    private func fail(_ parser: XMLParser) {
        failed = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        data = ""
        switch element {
        case "dict": if add(.dict([:]), parser) { stack.append(.dict([:])) }
        case "array": if add(.array([]), parser) { stack.append(.array([])) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        data += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        data += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let text = data
        data = ""
        switch element {
        case "dict":
            if !(currentKey ?? "").isEmpty { return fail(parser) }          // missing value for key
            close(parser)
        case "array":
            close(parser)
        case "key":
            guard (currentKey ?? "").isEmpty, case .dict? = stack.last else { return fail(parser) }  // unexpected key
            currentKey = text
        case "true": _ = add(.bool(true), parser)
        case "false": _ = add(.bool(false), parser)
        case "string": _ = add(.string(text), parser)
        case "integer":
            guard let value = Self.pyInt(text) else { return fail(parser) }
            _ = add(value, parser)
        case "real":
            guard let value = SystemText.pyFloat(text) else { return fail(parser) }
            _ = add(.real(value), parser)
        case "data":
            let cleaned = text.unicodeScalars.filter { !Py.isSpace($0) }
            guard let value = Data(base64Encoded: String(String.UnicodeScalarView(cleaned)), options: .ignoreUnknownCharacters)
            else { return fail(parser) }
            _ = add(.data(value), parser)
        case "date":
            guard let value = Self.pyDate(text) else { return fail(parser) }
            _ = add(.date(value), parser)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser)                                   // plistlib refuses entity declarations
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) {
        fail(parser)
    }

    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?, notationName: String?) {
        fail(parser)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }

    /// `add_object`: under the current key in a dict, as the root, or appended to a list.
    /// A new container is placed now and filled as it closes, so `close` writes it back.
    private func add(_ value: PlistValue, _ parser: XMLParser) -> Bool {
        let slot: Slot
        if let key = currentKey {
            guard case .dict(var d)? = stack.last else { fail(parser); return false }
            d[key] = value
            stack[stack.count - 1] = .dict(d)
            currentKey = nil
            slot = .key(key)
        } else if stack.isEmpty {
            root = value
            slot = .root
        } else {
            guard case .array(var a)? = stack.last else { fail(parser); return false }
            a.append(value)
            stack[stack.count - 1] = .array(a)
            slot = .index(a.count - 1)
        }
        switch value {
        case .dict, .array: pending.append(slot)       // filled in as it closes
        default: break                                 // a scalar is final as placed
        }
        return true
    }

    /// Where each open container was placed in its parent.
    private enum Slot { case root, key(String), index(Int) }
    private var pending: [Slot] = []

    private func close(_ parser: XMLParser) {
        guard let container = stack.popLast(), let slot = pending.popLast() else { return fail(parser) }
        let value: PlistValue = switch container {
        case .dict(let d): .dict(d)
        case .array(let a): .array(a)
        }
        switch slot {
        case .root:
            root = value
        case .key(let key):
            guard case .dict(var d)? = stack.last else { return fail(parser) }
            d[key] = value
            stack[stack.count - 1] = .dict(d)
        case .index(let i):
            guard case .array(var a)? = stack.last, i < a.count else { return fail(parser) }
            a[i] = value
            stack[stack.count - 1] = .array(a)
        }
    }

    /// `int(raw, 16)` for a `0x`/`0X` prefix, else `int(raw)`: surrounding whitespace, a sign
    /// and single underscores between digits are accepted, as Python's int() accepts them.
    static func pyInt(_ raw: String) -> PlistValue? {
        let hex = raw.hasPrefix("0x") || raw.hasPrefix("0X")
        var t = Py.strip(raw)
        var negative = false
        if t.hasPrefix("-") || t.hasPrefix("+") { negative = t.hasPrefix("-"); t.removeFirst() }
        if hex { t.removeFirst(2) }
        let radix = hex ? 16 : 10
        guard !t.isEmpty, !t.hasPrefix("_"), !t.hasSuffix("_"), !t.contains("__") else { return nil }
        let digits = t.replacingOccurrences(of: "_", with: "")
        guard let magnitude = Int64(digits, radix: radix) else { return nil }
        return .int(negative ? -magnitude : magnitude)
    }

    /// `_date_from_string`: YYYY[-MM[-DD[THH[:MM[:SS]]]]]Z matched at the start; datetime()
    /// needs at least year, month and day, each in range. Naive UTC, as plistlib returns it.
    static func pyDate(_ s: String) -> Date? {
        let pattern = /^(\d{4})(?:-(\d{2})(?:-(\d{2})(?:T(\d{2})(?::(\d{2})(?::(\d{2}))?)?)?)?)?Z/
        guard let m = s.firstMatch(of: pattern.asciiOnlyDigits()), let month = m.2, let day = m.3 else { return nil }
        var parts = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"))
        parts.year = Int(m.1)
        parts.month = Int(month)
        parts.day = Int(day)
        parts.hour = m.4.flatMap { Int($0) } ?? 0
        parts.minute = m.5.flatMap { Int($0) } ?? 0
        parts.second = m.6.flatMap { Int($0) } ?? 0
        guard parts.isValidDate, let date = parts.date else { return nil }
        return date
    }
}

import Foundation
import JarvisCore

/// SPEAKER_THRESHOLD and WAKE_SPK_THRESHOLD as jarvis.py reads them (J:5155-5156), a
/// compatibility surface:
///
///     SPEAKER_THRESHOLD  = float(os.environ.get("JARVIS_SPK_THRESH", "0.60"))
///     WAKE_SPK_THRESHOLD = float(os.environ.get("JARVIS_WAKE_SPK_THRESH", "0.38"))
///
/// A value Python's `float()` refuses stops Python JARVIS at import. Here it is logged and the
/// default is used instead (DEV-M10-03), so a typo cannot keep JARVIS from starting.
public struct SpeakerThresholds: Sendable, Equatable {
    /// `speaker_ok`'s bar for a command (and `_barge_in_speaker_match`'s).
    public var speaker: Double
    /// The wake gate's lower bar: speaker_ok(wake_clip, threshold=WAKE_SPK_THRESHOLD).
    public var wake: Double

    public static let speakerVariable = "JARVIS_SPK_THRESH"
    public static let wakeVariable = "JARVIS_WAKE_SPK_THRESH"
    public static let defaults = SpeakerThresholds(speaker: 0.60, wake: 0.38)

    public init(speaker: Double, wake: Double) {
        self.speaker = speaker
        self.wake = wake
    }

    public static func from(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                            log: (String) -> Void = { _ in }) -> SpeakerThresholds {
        func read(_ name: String, _ fallback: String, _ value: Double) -> Double {
            let text = environment[name] ?? fallback
            if let parsed = PythonFloat.parse(text) { return parsed }
            log("speaker: \(name)=\(text.debugDescription) is not a number Python's float() reads; using \(fallback)")
            return value
        }
        return SpeakerThresholds(speaker: read(speakerVariable, "0.60", defaults.speaker),
                                 wake: read(wakeVariable, "0.38", defaults.wake))
    }
}

/// Python's `float(s)` for a str (CPython 3.14's PyFloat_FromString), golden-checked by
/// m10_thresholds against jarvis.py's own threshold expressions:
/// 1. non-ASCII whitespace becomes a space and Unicode decimal digits become ASCII ones; any
///    other character from DEL up fails;
/// 2. an underscore must sit between two digits, and is then dropped;
/// 3. ASCII whitespace (tab, LF, VT, FF, CR, space) is stripped from both ends;
/// 4. what is left must be a decimal, `[sign](digits[.digits]|.digits)[(e|E)[sign]digits]`, or
///    `[sign]inf`, `[sign]infinity` or `[sign]nan` in any case.
enum PythonFloat {
    static func parse(_ text: String) -> Double? {
        var ascii: [UInt8] = []
        for scalar in text.unicodeScalars {
            if scalar.value < 127 {
                ascii.append(UInt8(scalar.value))
            } else if Py.isSpace(scalar) {
                ascii.append(0x20)
            } else if scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue,
                      value >= 0, value <= 9 {
                ascii.append(0x30 + UInt8(value))
            } else {
                return nil
            }
        }
        if ascii.contains(0) { return nil }
        if ascii.contains(UInt8(ascii: "_")) {
            var kept: [UInt8] = []
            var previous: UInt8 = 0
            for c in ascii {
                if c == UInt8(ascii: "_") {
                    guard isDigit(previous) else { return nil }
                } else {
                    if previous == UInt8(ascii: "_") && !isDigit(c) { return nil }
                    kept.append(c)
                }
                previous = c
            }
            if previous == UInt8(ascii: "_") { return nil }
            ascii = kept
        }
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || (0x09 ... 0x0D).contains($0) }
        guard let first = ascii.firstIndex(where: { !isSpace($0) }),
              let last = ascii.lastIndex(where: { !isSpace($0) }) else { return nil }
        let body = Array(ascii[first ... last])
        var i = 0
        var negative = false
        if i < body.count, body[i] == UInt8(ascii: "+") || body[i] == UInt8(ascii: "-") {
            negative = body[i] == UInt8(ascii: "-")
            i += 1
        }
        let word = String(decoding: body[i...], as: UTF8.self).lowercased()
        switch word {
        case "inf", "infinity": return negative ? -.infinity : .infinity
        case "nan": return negative ? -Double.nan : .nan
        default: break
        }
        // The decimal grammar, checked here; the value is then Swift's correctly rounded parse.
        var digits = 0
        while i < body.count, isDigit(body[i]) { i += 1; digits += 1 }
        if i < body.count, body[i] == UInt8(ascii: ".") {
            i += 1
            while i < body.count, isDigit(body[i]) { i += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if i < body.count, body[i] == UInt8(ascii: "e") || body[i] == UInt8(ascii: "E") {
            i += 1
            if i < body.count, body[i] == UInt8(ascii: "+") || body[i] == UInt8(ascii: "-") { i += 1 }
            var exponent = 0
            while i < body.count, isDigit(body[i]) { i += 1; exponent += 1 }
            guard exponent > 0 else { return nil }
        }
        guard i == body.count else { return nil }
        return Double(String(decoding: body, as: UTF8.self))
    }

    private static func isDigit(_ c: UInt8) -> Bool { (0x30 ... 0x39).contains(c) }
}

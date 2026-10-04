import Foundation
import JarvisCore

/// The text cleaning in Python's `speak()` (jarvis.py 723-729), proven by the m8_textclean
/// golden suite, which records the real function:
///
///     clean = re.sub(r'[*_`#\[\]()|\\~>•]', '', text).strip()
///     clean = re.sub(r'\s+', ' ', clean)
///     if not clean: return
///
/// Python works on code points, so this works on Unicode scalars. Its `strip()` and `\s` are
/// the same 29-scalar whitespace set (`Py.isSpace`).
public enum TextClean {
    /// The characters `speak()` removes: `* _ ` # [ ] ( ) | \ ~ > •`.
    public static let removed: Set<Unicode.Scalar> = [
        "*", "_", "`", "#", "[", "]", "(", ")", "|", "\\", "~", ">", "\u{2022}",
    ]

    /// The text to speak, or nil when nothing is left (Python returns without speaking).
    public static func clean(_ text: String) -> String? {
        var kept = String.UnicodeScalarView()
        for u in text.unicodeScalars where !removed.contains(u) {
            kept.append(u)
        }
        var out = String.UnicodeScalarView()
        var inSpace = false
        for u in Py.strip(String(kept)).unicodeScalars {
            if Py.isSpace(u) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(u)
                inSpace = false
            }
        }
        return out.isEmpty ? nil : String(out)
    }
}

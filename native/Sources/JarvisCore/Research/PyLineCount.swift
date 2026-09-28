import Foundation

// Python's text-mode line count, `sum(1 for _ in open(p))` (plan: M01b §2.2, §3.2): universal
// newlines, so "\n", "\r\n" and a lone "\r" each end a line and a final unterminated line
// counts. Only those three end a line when iterating a file ("\v", "\x85", U+2028 do not).
// Counting bytes equals counting decoded text because UTF-8 never puts 0x0A / 0x0D inside a
// multibyte sequence; it is exactly the `errors="replace"` variant (golden: m1b_line_count).

public enum PyLineCount {
    public static func lines(_ data: Data) -> Int {
        var n = 0
        var lineOpen = false                     // bytes seen since the last line end
        var afterCR = false                      // the previous byte was a line-ending "\r"
        for b in data {
            switch b {
            case 0x0D:
                n += 1
                lineOpen = false
                afterCR = true
            case 0x0A:
                if !afterCR { n += 1 }           // "\r\n" already counted at the "\r"
                lineOpen = false
                afterCR = false
            default:
                lineOpen = true
                afterCR = false
            }
        }
        return lineOpen ? n + 1 : n
    }

    /// Schema 2 `code_native` (plan §3.7 H2 reference `_research_code_native`, native-specified):
    /// `os.walk(sources)` top-down without following symlinks, directories and files in code
    /// point order; counts names ending ".swift" that are regular files and not symlinks
    /// (`isfile and not islink`). A directory that cannot be listed is skipped (os.walk's
    /// default); a file that cannot be read stops the walk and the partial totals are
    /// returned (the reference's single try/except around the loop).
    public static func codeNative(_ sources: URL) -> (bytes: Int, lines: Int, files: Int) {
        var totals = (bytes: 0, lines: 0, files: 0)
        var root = sources.path(percentEncoded: false)
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        _ = walk(root, &totals)
        return totals
    }

    /// false once a file read failed (the walk stops there).
    private static func walk(_ dir: String, _ totals: inout (bytes: Int, lines: Int, files: Int)) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return true }
        var dirs: [String] = []
        var files: [String] = []
        for name in names {
            var st = stat()
            let path = dir + "/" + name
            guard lstat(path, &st) == 0 else { files.append(name); continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: dirs.append(name)
            case S_IFLNK: continue                   // never descended, never counted
            default: files.append(name)
            }
        }
        for name in files.sorted(by: PyStr.less) where hasSwiftSuffix(name) {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            guard let data = AtomicFile.read(path) else { return false }
            totals.lines += lines(data)
            totals.bytes += data.count
            totals.files += 1
        }
        for name in dirs.sorted(by: PyStr.less) {
            if !walk(dir + "/" + name, &totals) { return false }
        }
        return true
    }

    private static func hasSwiftSuffix(_ name: String) -> Bool {
        let suffix = Array(".swift".unicodeScalars)
        let u = Array(name.unicodeScalars)
        return u.count >= suffix.count && Array(u[(u.count - suffix.count)...]) == suffix
    }
}

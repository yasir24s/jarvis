import CryptoKit
import Foundation
import JarvisCore

/// The SHA-256 of a document's bytes, lower-case hex: a file fact's `source` is `file:` and
/// this (D-51 P3). Read in 1 MB pieces with dataless materialisation off, so a file evicted to
/// iCloud gives nil instead of a download. An .rtfd package hashes each file inside it, in
/// name order, as its name, a NUL, its length and its bytes.
public enum FileDigest {
    static let pieceBytes = 1 << 20

    public static func sha256(of candidate: FileCandidate) -> String? {
        NoDownloads.run {
            var hasher = SHA256()
            if candidate.kind == .rtfd {
                guard let names = try? FileManager.default.contentsOfDirectory(
                    atPath: candidate.url.path(percentEncoded: false)) else { return nil }
                for name in names.sorted() {
                    let url = candidate.url.appending(path: name, directoryHint: .notDirectory)
                    guard let size = regularFileSize(url) else { return nil }
                    hasher.update(data: Data(name.utf8) + Data([0]) + Data("\(size)".utf8))
                    guard hash(url, into: &hasher) else { return nil }
                }
            } else {
                guard hash(candidate.url, into: &hasher) else { return nil }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func hash(_ url: URL, into hasher: inout SHA256) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            while let piece = try handle.read(upToCount: pieceBytes), !piece.isEmpty {
                hasher.update(data: piece)
            }
            return true
        } catch {
            return false
        }
    }

    private static func regularFileSize(_ url: URL) -> Int? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(st.st_size)
    }
}

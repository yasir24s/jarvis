import Foundation

/// A 16 kHz mono 16-bit PCM WAV, as the M10 speaker corpus stores its `say` clips. Used by the
/// `--selftest-dlopen` embedding and the speaker tests; nothing in the app records to WAV.
public enum WAVFile {
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public let why: String
        public var description: String { "WAV: \(why)" }
    }

    /// The samples of `url`. The RIFF chunks are walked; any but `fmt ` and `data` are skipped.
    public static func samples(_ url: URL) throws -> [Int16] {
        try samples(Data(contentsOf: url), name: url.lastPathComponent)
    }

    public static func samples(_ data: Data, name: String = "data") throws -> [Int16] {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        guard bytes.count >= 12, String(bytes: bytes[0 ..< 4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8 ..< 12], encoding: .ascii) == "WAVE" else { throw Unreadable(why: "\(name) is not RIFF/WAVE") }
        var o = 12, format = false
        while o + 8 <= bytes.count {
            let id = String(bytes: bytes[o ..< o + 4], encoding: .ascii) ?? "", size = u32(o + 4)
            if id == "fmt " {
                guard o + 24 <= bytes.count, u16(o + 8) == 1, u16(o + 10) == 1, u32(o + 12) == 16000, u16(o + 22) == 16 else {
                    throw Unreadable(why: "\(name) is not 16 kHz mono 16-bit PCM")
                }
                format = true
            } else if id == "data" {
                guard format, o + 8 + size <= bytes.count else { throw Unreadable(why: "\(name): data before fmt, or short") }
                return stride(from: o + 8, to: o + 8 + size - 1, by: 2).map {
                    Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
                }
            }
            o += 8 + size + size % 2
        }
        throw Unreadable(why: "\(name) has no data chunk")
    }
}

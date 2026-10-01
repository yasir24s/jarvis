import ApplicationServices
import Foundation
import JarvisCore

/// Reads the general pasteboard's plain text. Tests inject a fake, so no test reads the live
/// pasteboard.
protocol ClipboardReading: Sendable {
    /// The `public.utf8-plain-text` bytes of the first item that has them, or nil when the
    /// pasteboard holds no plain text (an image or RTF only, or nothing).
    func plainTextData() async -> Data?
}

/// `read_clipboard` (plan: M05-M06 §2a, §3.5, A-SYS-8). Python: `pbpaste` with `text=True`
/// and a 5 s timeout, "" on any failure, then `execute_tool`'s `[:3500]` in code points.
/// Untrusted: the gateway taints the turn after it runs (TaintPolicy.untrusted).
struct ReadClipboard: ToolImpl {
    static let name = "read_clipboard"
    static let schema = BuiltInTools.catalogSchema(named: name)
    /// execute_tool's slice.
    static let limit = 3500
    let clipboard: any ClipboardReading

    /// pbpaste's text=True decode (strict UTF-8, universal newlines), "" where Python's try
    /// returns "", then the slice. Translation happens before the slice, as in Python.
    static func reply(_ data: Data?) -> String {
        guard let data, let text = PyText.decode(data) else { return "" }
        return Py.prefix(text, limit)
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(Self.reply(await clipboard.plainTextData()))
    }
}

/// The live reader: the Pasteboard Manager (HIServices, in ApplicationServices), which reads
/// the same general pasteboard and flavor as `NSPasteboard.general.string(forType: .string)`
/// without linking AppKit outside JarvisApp. No child process. An RTF-only pasteboard gives
/// nil, where pbpaste prints the RTF source (R12).
struct LivePasteboard: ClipboardReading {
    /// pbpaste's timeout in Python.
    var timeout: Double = 5

    func plainTextData() async -> Data? {
        await Self.firstOf(timeout: timeout) { Self.readPlainText() }
    }

    /// The general pasteboard's name (`kPasteboardClipboard`, a CFSTR macro Swift cannot import).
    static let general = "com.apple.pasteboard.clipboard"

    static func readPlainText(named name: String = general) -> Data? {
        var board: Pasteboard?
        guard PasteboardCreate(name as CFString, &board) == noErr,
              let board else { return nil }
        PasteboardSynchronize(board)
        var count = 0
        guard PasteboardGetItemCount(board, &count) == noErr, count > 0 else { return nil }
        for index in 1...count {                              // Pasteboard Manager items are 1-based
            var item: PasteboardItemID?
            guard PasteboardGetItemIdentifier(board, index, &item) == noErr, let item else { continue }
            var data: CFData?
            if PasteboardCopyItemFlavorData(board, item, "public.utf8-plain-text" as CFString, &data) == noErr,
               let data {
                return data as Data
            }
        }
        return nil
    }

    /// Runs `work` on a dispatch thread and returns nil if it has not finished within
    /// `timeout` (the thread is left to finish on its own; the pasteboard read cannot be
    /// cancelled).
    static func firstOf(timeout: Double, _ work: @escaping @Sendable () -> Data?) async -> Data? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}

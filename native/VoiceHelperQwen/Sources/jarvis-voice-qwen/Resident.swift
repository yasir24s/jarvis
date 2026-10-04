import Darwin
import Foundation
import MLX
import MLXNN

// V10: keeps the loaded model in memory. Live (8 GB Mac, about 10 min idle) the next reply had to
// page the model back in: its warm-up "Right." took 7.4 s, and the reply ran dry 25 times at 0.63x
// real time.
//
// MLX's wired limit was tried first and did not do it: with the limit at 1988 MB, the V10 probe's
// helper still swapped 1.78 GB back in for the reply after memory pressure (1.50 GB with it off),
// and `footprint -w` showed 0 B wired. So the weights' own pages are locked with mlock(): MLX keeps
// each array in a Metal buffer in shared memory, mapped into this process, and its address is the
// array's data pointer. If mlock is refused, the fallback touches one byte of every page of the
// weights every `touchInterval`, which keeps them recently used rather than pinned.
//
// The app turns resident off when the voice is not Qwen, when speech has been muted a long while,
// or when memory is critically short; off unlocks the pages (or stops the touching).

enum Residency {
    static let touchInterval: TimeInterval = 60
    static let pageSize = Int(getpagesize())

    enum Mechanism: String {
        case mlock, touch
    }

    /// A page-aligned range of the weights.
    struct Range {
        let start: UnsafeRawPointer
        let length: Int
    }

    nonisolated(unsafe) private static var ranges: [Range] = []
    nonisolated(unsafe) private(set) static var mechanism: Mechanism?
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    /// Bytes held resident while on.
    nonisolated(unsafe) private(set) static var residentBytes = 0
    /// The arrays whose pages are held, so their buffers stay alive while locked.
    nonisolated(unsafe) private static var held: [MLXArray] = []

    static var isOn: Bool { mechanism != nil }

    /// The weights' page-aligned ranges, merged where they touch or overlap.
    static func pageRanges(_ spans: [(start: UInt, length: Int)], pageSize: Int) -> [(start: UInt, length: Int)] {
        let page = UInt(pageSize)
        let aligned = spans.filter { $0.length > 0 }.map { span -> (UInt, UInt) in
            let lo = span.start / page * page
            let hi = (span.start + UInt(span.length) + page - 1) / page * page
            return (lo, hi)
        }.sorted { $0.0 < $1.0 }
        var merged: [(UInt, UInt)] = []
        for (lo, hi) in aligned {
            if let last = merged.last, lo <= last.1 {
                merged[merged.count - 1].1 = max(last.1, hi)
            } else {
                merged.append((lo, hi))
            }
        }
        return merged.map { (start: $0.0, length: Int($0.1 - $0.0)) }
    }

    /// Turns resident on for `model`'s weights, or off; returns the log line, or nil when nothing
    /// changed.
    static func set(_ on: Bool, model: Module?) -> String? {
        if on {
            guard mechanism == nil, let model else { return nil }
            let arrays = model.parameters().flattened().map(\.1)
            var spans: [(start: UInt, length: Int)] = []
            for array in arrays {
                let data = array.asData(access: .noCopy).data
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { spans.append((UInt(bitPattern: base), raw.count)) }
                }
            }
            let pages = pageRanges(spans, pageSize: pageSize)
            ranges = pages.compactMap { span in
                UnsafeRawPointer(bitPattern: span.start).map { Range(start: $0, length: span.length) }
            }
            held = arrays
            residentBytes = ranges.reduce(0) { $0 + $1.length }
            var locked: [Range] = []
            var failure: Int32 = 0
            for range in ranges {
                if mlock(range.start, range.length) == 0 {
                    locked.append(range)
                } else {
                    failure = errno
                    break
                }
            }
            if failure == 0 {
                mechanism = .mlock
                return "resident \(residentBytes / 1_048_576) MB (mlock), \(ranges.count) ranges"
            }
            for range in locked { munlock(range.start, range.length) }
            mechanism = .touch
            startTouching()
            return "resident \(residentBytes / 1_048_576) MB (touch), mlock refused: \(String(cString: strerror(failure)))"
        }
        guard let was = mechanism else { return nil }
        switch was {
        case .mlock: for range in ranges { munlock(range.start, range.length) }
        case .touch:
            timer?.cancel()
            timer = nil
        }
        mechanism = nil
        ranges = []
        held = []
        let bytes = residentBytes
        residentBytes = 0
        return "resident off (\(bytes / 1_048_576) MB released)"
    }

    /// Reads one byte of every page of `ranges`; returns their sum so the reads stay.
    @discardableResult
    static func touch(_ ranges: [Range]) -> UInt64 {
        var sum: UInt64 = 0
        for range in ranges {
            let bytes = range.start.assumingMemoryBound(to: UInt8.self)
            var offset = 0
            while offset < range.length {
                sum &+= UInt64(bytes[offset])
                offset += pageSize
            }
        }
        return sum
    }

    private static func startTouching() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "jarvis-voice-qwen.touch"))
        source.schedule(deadline: .now() + touchInterval, repeating: touchInterval)
        // The handler keeps its own copy of the ranges and the arrays behind them, so turning
        // resident off cannot free a buffer under a touch in progress.
        let snapshot = ranges, keep = held
        source.setEventHandler { withExtendedLifetime(keep) { touch(snapshot) } }
        source.resume()
        timer = source
    }
}

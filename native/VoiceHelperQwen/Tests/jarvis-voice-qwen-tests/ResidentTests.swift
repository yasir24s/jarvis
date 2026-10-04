import Foundation
import Testing
@testable import jarvis_voice_qwen

/// V10: the weights' spans become whole pages, merged where they touch or overlap, so each page is
/// locked (or touched) once.
@Suite("V10 resident page ranges")
struct ResidentTests {
    @Test func spansAreWidenedToWholePagesAndMerged() {
        let page = 16_384
        let ranges = Residency.pageRanges([
            (start: UInt(page * 10 + 100), length: 50),          // inside page 10
            (start: UInt(page * 10 + 4_000), length: page),      // pages 10 and 11
            (start: UInt(page * 20), length: page * 2),          // pages 20 and 21, exactly
            (start: UInt(page * 12), length: 1),                 // page 12, touching 11
            (start: UInt(page * 30), length: 0),                 // empty: dropped
        ], pageSize: page)
        #expect(ranges.map(\.start) == [UInt(page * 10), UInt(page * 20)])
        #expect(ranges.map(\.length) == [page * 3, page * 2])
    }

    @Test func noSpansNoRanges() {
        #expect(Residency.pageRanges([], pageSize: 16_384).isEmpty)
    }
}

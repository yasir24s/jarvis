import AppKit
@testable import JarvisApp
import Testing

@Suite("Composer measured height")
@MainActor
struct ComposerHeightTests {
    @Test func wrapsCapsAndShrinksOnTheSameTextView() {
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
        view.font = JarvisTheme.bodyNSFont
        view.isHorizontallyResizable = false
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        var heights: [CGFloat] = []
        view.onHeight = { heights.append($0) }
        view.string = "Short draft."
        view.reportHeight()
        #expect(heights.last == 48)
        view.string = Array(repeating: "This text wraps onto several lines.", count: 20)
            .joined(separator: " ")
        view.reportHeight()
        #expect(heights.last == 120)
        view.string = "Short again."
        view.reportHeight()
        #expect(heights.last == 48)
        let count = heights.count
        view.reportHeight()
        #expect(heights.count == count)
    }
}

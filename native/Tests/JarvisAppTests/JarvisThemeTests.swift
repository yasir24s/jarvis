import Foundation
@testable import JarvisApp
import Testing

/// UI1 part 1: the theme's contrast, on the numbers the views draw. Text needs WCAG 2.2 AA's
/// 4.5:1 against what it sits on; an outline that marks a control, and the focus ring, need 3:1.
/// Each ratio is printed, so the run shows the numbers.
@Suite("UI1 theme contrast")
struct JarvisThemeTests {
    typealias T = JarvisTheme

    /// The formula against WCAG's own reference points: white on black is 21:1, #767676 on
    /// white is the 4.54:1 grey, and a colour against itself is 1:1.
    @Test func contrastMatchesWCAGReferencePoints() {
        let white = T.RGB(hex: 0xFFFFFF), black = T.RGB(hex: 0x000000)
        #expect(abs(T.contrast(white, black) - 21) < 1e-9)
        #expect(abs(T.contrast(T.RGB(hex: 0x767676), white) - 4.54) < 0.005)
        #expect(T.contrast(T.cyan, T.cyan) == 1)
        #expect(T.contrast(T.navy, T.ice) == T.contrast(T.ice, T.navy))
    }

    /// The palette is hud.html's, digit for digit.
    @Test func paletteIsThePythonHUDs() {
        #expect(T.cyan == T.RGB(red: 95 / 255, green: 220 / 255, blue: 255 / 255))
        #expect(T.cyanDim == T.RGB(red: 27 / 255, green: 110 / 255, blue: 133 / 255))
        #expect(T.gold == T.RGB(red: 255 / 255, green: 207 / 255, blue: 107 / 255))
        #expect(T.ice == T.RGB(red: 234 / 255, green: 250 / 255, blue: 255 / 255))
        #expect(T.navy == T.RGB(red: 6 / 255, green: 14 / 255, blue: 22 / 255))
    }

    /// A fill at an alpha composites between its two colours, ends included.
    @Test func overCompositesAtAlpha() {
        #expect(T.cyan.over(T.navy, alpha: 1) == T.cyan)
        #expect(T.cyan.over(T.navy, alpha: 0) == T.navy)
        let half = T.RGB(hex: 0xFFFFFF).over(T.RGB(hex: 0x000000), alpha: 0.5)
        #expect(abs(half.red - 0.5) < 1e-12 && abs(half.green - 0.5) < 1e-12 && abs(half.blue - 0.5) < 1e-12)
    }

    static let textPairs: [(String, T.RGB, T.RGB)] = [
        ("window text: ice on navy", T.ice, T.navy),
        ("his messages: ice on the cyan fill", T.ice, T.replyFill),
        ("your messages and the composer: ice on the panel", T.ice, T.panel),
        ("notes: muted on navy", T.muted, T.navy),
        ("retracted rows: muted on the cyan fill", T.muted, T.replyFill),
        ("links: cyan on the cyan fill", T.cyan, T.replyFill),
        ("busy line: gold on navy", T.gold, T.navy),
        ("card text: ice on the gold fill", T.ice, T.attentionFill),
        ("card countdown: gold on the gold fill", T.gold, T.attentionFill),
        ("selected text: ice on dim cyan", T.ice, T.selection),
    ]

    @Test func everyTextPairMeetsAA() {
        for (name, text, background) in Self.textPairs {
            let ratio = T.contrast(text, background)
            print(String(format: "UI1 contrast %5.2f:1  %@", ratio, name))
            #expect(ratio >= 4.5, "\(name): \(ratio)")
        }
    }

    /// UI1 part 2: text that sits on the window, not in a message, can pass over the reactor
    /// behind the transcript. Its brightest point is the core's white centre, at the backdrop's
    /// opacity; the brief allows up to 0.12, so that is checked too.
    @Test func textOverTheReactorKeepsAA() {
        for alpha in [ReactorBackdrop.opacity, 0.12] {
            let brightest = T.RGB(hex: 0xFFFFFF).over(T.navy, alpha: alpha)
            for (name, text) in [("ice", T.ice), ("notes, muted", T.muted), ("gold", T.gold)] {
                let ratio = T.contrast(text, brightest)
                print(String(format: "UI1 contrast %5.2f:1  %@ over the reactor's core at %.2f", ratio, name, alpha))
                #expect(ratio >= 4.5, "\(name) at \(alpha): \(ratio)")
            }
        }
    }

    static let outlinePairs: [(String, T.RGB, T.RGB)] = [
        ("your messages' outline: dim cyan on navy", T.cyanDim, T.navy),
        ("your messages' outline: dim cyan on the panel", T.cyanDim, T.panel),
        ("focus ring: cyan on navy", T.cyan, T.navy),
        ("focus ring: cyan on the panel", T.cyan, T.panel),
        ("card outline: gold on navy", T.gold.over(T.navy, alpha: 0.55), T.navy),
    ]

    @Test func everyOutlineMeetsTheNonTextMinimum() {
        for (name, line, background) in Self.outlinePairs {
            let ratio = T.contrast(line, background)
            print(String(format: "UI1 contrast %5.2f:1  %@", ratio, name))
            #expect(ratio >= 3, "\(name): \(ratio)")
        }
    }
}

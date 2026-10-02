import AppKit
import SwiftUI

/// UI1 part 1: the J.A.R.V.I.S. look, taken from the Python HUD (`hud.html`): its cyan, dim cyan
/// and gold over a near-black navy, ice-white text, and its two faces, Helvetica Neue and Avenir
/// Next. The chat window is always dark: navy to its edges, cyan hairlines and focus ring, his
/// messages on a faint cyan glow, the user's outlined in dim cyan, and gold for confirmations and
/// anything else that needs the user's attention.
///
/// Each colour is kept as sRGB components, and each fill as the opaque colour it composites to,
/// so `JarvisThemeTests` checks the contrast of the very numbers the views draw (WCAG 2.2 AA:
/// 4.5:1 for text, 3:1 for the outline of a control).
enum JarvisTheme {
    /// An opaque sRGB colour, components 0...1.
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// From `0xRRGGBB`, as CSS writes it.
        init(hex: UInt32) {
            self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        /// This colour drawn at `alpha` over `background`: the opaque colour the eye gets.
        func over(_ background: RGB, alpha: Double) -> RGB {
            RGB(red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha))
        }

        /// WCAG 2.2 relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }

    /// WCAG 2.2's contrast ratio: (L1 + 0.05) / (L2 + 0.05), the lighter colour's luminance over
    /// the darker's. 1 for the same colour, 21 for white on black.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (a.luminance, b.luminance)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - hud.html's palette

    /// `--cyan`: the rings, the bars, the hairlines and the focus ring.
    static let cyan = RGB(hex: 0x5FDCFF)
    /// `--cyan-dim`: the core's edge; here the outline of the user's messages.
    static let cyanDim = RGB(hex: 0x1B6E85)
    /// `--gold`: the speaking core; here confirmations and whatever needs the user.
    static let gold = RGB(hex: 0xFFCF6B)
    /// The status pill's and the caption's text, `#eafaff`.
    static let ice = RGB(hex: 0xEAFAFF)
    /// The pill's and the caption's backdrop, `rgba(6,14,22,…)`, at full strength: the window.
    static let navy = RGB(hex: 0x060E16)

    // MARK: - Derived surfaces and text

    /// One step up from the window: the composer and the user's messages.
    static let panel = RGB(hex: 0x0B1824)
    /// Secondary text: the app's own notes, the countdown, the backend line.
    static let muted = RGB(hex: 0x8FB3C2)
    /// His messages: cyan at 7% over the window.
    static let replyFill = cyan.over(navy, alpha: 0.07)
    /// The confirmation card: gold at 10% over the window.
    static let attentionFill = gold.over(navy, alpha: 0.10)
    /// Selected text in the composer.
    static let selection = cyanDim

    /// His messages' border and glow, and the hairlines: cyan, faint.
    static let hairlineAlpha = 0.30
    static let replyBorderAlpha = 0.25
    static let glowAlpha = 0.22
    /// The reactor's `drop-shadow(0 0 8px …)`.
    static let glowRadius: CGFloat = 8

    // MARK: - Faces

    /// The body face, `"Helvetica Neue"`, 14 pt like the HUD's caption.
    static let bodySize: CGFloat = 14
    static let body = Font.custom("Helvetica Neue", size: bodySize, relativeTo: .body)
    /// Smaller body text: notes, the busy line, the card.
    static let small = Font.custom("Helvetica Neue", size: 12, relativeTo: .callout)
    /// The labels' face, `"Avenir Next"`: letter-spaced capitals like the HUD's status pill.
    static let label = Font.custom("Avenir Next", size: 11, relativeTo: .caption).weight(.semibold)
    /// The pill's `letter-spacing: .4em` at 11 pt.
    static let labelTracking: CGFloat = 4.4

    /// The composer's face, the body face in AppKit.
    static var bodyNSFont: NSFont {
        NSFont(name: "Helvetica Neue", size: bodySize) ?? .preferredFont(forTextStyle: .body)
    }

    // MARK: - Windows

    /// The chat window: dark whatever the system setting, and navy to its edges, title bar too.
    @MainActor
    static func style(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = navy.nsColor
        window.titlebarAppearsTransparent = true
    }
}

extension View {
    /// A faint cyan glow, the HUD's drop shadow.
    func jarvisGlow(alpha: Double = JarvisTheme.glowAlpha) -> some View {
        shadow(color: JarvisTheme.cyan.color.opacity(alpha), radius: JarvisTheme.glowRadius)
    }
}

/// A one-point cyan hairline, the theme's divider.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(JarvisTheme.cyan.color.opacity(JarvisTheme.hairlineAlpha))
            .frame(height: 1)
    }
}

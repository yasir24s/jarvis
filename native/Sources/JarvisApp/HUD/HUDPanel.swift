import AppKit

/// UI1 part 3: the floating HUD's window (plan: M08-M13 §3.7): borderless and non-activating,
/// clear, click-through, at the screen-saver level on every Space and over full-screen apps,
/// 360×430 at (28, 48) on the main screen. It never becomes key or main, so showing it never
/// takes focus from the frontmost app. The app stays a regular app (D-43): nothing here
/// touches the activation policy.
final class HUDPanel: NSPanel {
    static let size = NSSize(width: 360, height: 430)
    /// From the screen's bottom-left corner: Python's `x=28, y=(SH - H) - 48` on pywebview's
    /// top-left origin, on the full frame, not the visible frame.
    static let inset = NSPoint(x: 28, y: 48)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel's frame on `screen`'s full frame.
    static func frame(on screen: NSRect) -> NSRect {
        NSRect(x: screen.minX + inset.x, y: screen.minY + inset.y, width: size.width, height: size.height)
    }
}

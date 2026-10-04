import AppKit
import JarvisChat
import SwiftUI

/// The chat composer (plan: M02-M04 §3.12): an `NSTextView` whose paste and drag-and-drop
/// call `onPaste`, so the next input is `pasted: true` (X-8). Return sends and Shift+Return
/// adds a newline (`ComposerReturn`). Both are handled at `insertNewline:` in `doCommandBy`
/// rather than in `keyDown`, so keys an input method takes never reach them. UI1 part 4: Esc
/// (`cancelOperation:`) stops a reply, the same way.
struct Composer: NSViewRepresentable {
    @Binding var text: String
    let onPaste: () -> Void
    let onSubmit: () -> Void
    /// UI1: told when the text view takes or gives up the keyboard (the cyan focus ring).
    var onFocus: (Bool) -> Void = { _ in }
    /// UI1 part 4: Esc. True when it stopped something; otherwise the text view handles it.
    var onEscape: () -> Bool = { false }
    var onHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false   // UI1: the panel behind it shows through

        let size = scrollView.contentSize
        let textView = ComposerTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // UI1 part 1: the theme's body face, ice-white on the panel, a cyan caret, and selected
        // text on dim cyan.
        textView.font = JarvisTheme.bodyNSFont
        textView.textColor = JarvisTheme.ice.nsColor
        textView.insertionPointColor = JarvisTheme.cyan.nsColor
        textView.drawsBackground = false
        textView.selectedTextAttributes = [.backgroundColor: JarvisTheme.selection.nsColor,
                                           .foregroundColor: JarvisTheme.ice.nsColor]
        textView.typingAttributes = [.font: JarvisTheme.bodyNSFont, .foregroundColor: JarvisTheme.ice.nsColor]
        textView.string = text
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPaste = { [weak coordinator] in coordinator?.parent.onPaste() }
        // After the current update: taking the keyboard can happen while SwiftUI lays the view out.
        textView.onFocus = { [weak coordinator] focused in
            let coordinator = coordinator
            Task { @MainActor in coordinator?.parent.onFocus(focused) }
        }
        textView.onHeight = { [weak coordinator] height in
            Task { @MainActor in coordinator?.parent.onHeight(height) }
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only when the model changed it (sent, or a refused draft coming back), so typing
        // keeps its selection.
        if textView.string != text {
            textView.string = text
        }
        (textView as? ComposerTextView)?.reportHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Composer

        init(_ parent: Composer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            (textView as? ComposerTextView)?.reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                return parent.onEscape()
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch ComposerReturn.action(shift: shift) {
            case .send:
                parent.onSubmit()
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
            }
            return true
        }
    }
}

/// The composer's text view. Every paste variant and every drop calls `onPaste` before the
/// text lands, so the flag is never set later than the text arrives.
final class ComposerTextView: NSTextView {
    var onPaste: (() -> Void)?
    /// UI1: true when it takes the keyboard, false when it gives it up.
    var onFocus: ((Bool) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0

    func reportHeight() {
        guard let onHeight, let layoutManager, let textContainer, bounds.width > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = min(120, max(48, ceil(layoutManager.usedRect(for: textContainer).height
                                         + textContainerInset.height * 2)))
        guard height != reportedHeight else { return }
        reportedHeight = height
        onHeight(height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportHeight()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func paste(_ sender: Any?) {
        onPaste?()
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onPaste?()
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        onPaste?()
        super.pasteAsRichText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onPaste?()
        return super.performDragOperation(sender)
    }

    /// The composer takes the keyboard when the chat window opens.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

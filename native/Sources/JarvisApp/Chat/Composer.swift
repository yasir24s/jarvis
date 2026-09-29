import AppKit
import JarvisChat
import SwiftUI

/// The chat composer (plan: M02-M04 §3.12): an `NSTextView` whose paste and drag-and-drop
/// call `onPaste`, so the next input is `pasted: true` (X-8). Return sends and Shift+Return
/// adds a newline (`ComposerReturn`). While an input method is composing, Return confirms
/// the composition and sends nothing, because the text view only issues `insertNewline:`
/// once no text is marked.
struct Composer: NSViewRepresentable {
    @Binding var text: String
    let onPaste: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

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
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = text
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPaste = { [weak coordinator] in coordinator?.parent.onPaste() }

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
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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

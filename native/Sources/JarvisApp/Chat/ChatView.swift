import AppKit
import JarvisChat
import JarvisTools
import SwiftUI

/// The chat window (plan: M02-M04 §3.12): the transcript, the confirmation card while one is
/// pending, and the composer.
struct ChatView: View {
    static let windowID = "chat"

    @Bindable var model: ChatViewModel
    /// Hands the app this window's opener each time the window appears, so the Dock icon can
    /// reopen it (D-43).
    var onAppear: (OpenWindowAction) -> Void = { _ in }
    /// Hands the app the window this view is in (U1 saves and restores its frame).
    var onWindow: (NSWindow) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    /// UI1: whether the composer has the keyboard, for its focus ring.
    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .scrollTargetLayout()   // U1: lets scrollPosition report the top row
                    .padding(16)
                }
                // UI1 part 2: the arc reactor, faint and still behind the scrolling transcript.
                .background { ReactorBackdrop() }
                // U1: where the transcript is scrolled, for a live update to hand over.
                .scrollPosition(id: $model.scrollTop, anchor: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
                } action: { _, atBottom in
                    model.scrolledToBottom = atBottom
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // U1: a restored scroll position, applied once the restored rows are laid out.
                .onChange(of: model.scrollRequest, initial: true) {
                    guard let request = model.takeScrollRequest() else { return }
                    DispatchQueue.main.async {
                        if request.atBottom, let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else if let row = request.row {
                            proxy.scrollTo(row, anchor: .top)
                        }
                    }
                }
            }
            Hairline()
            if let pending = model.pending {
                ConfirmationCard(pending: pending, enabled: model.isConnected && !model.responding,
                                 onConfirm: { _ = model.confirmPending() },
                                 onCancel: { _ = model.cancelPending() })
            }
            if model.busy {
                Text(ChatViewModel.busyNotice)
                    .font(JarvisTheme.small)
                    .foregroundStyle(JarvisTheme.gold.color)   // UI1: it needs the user's attention
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Composer(text: $model.draft.text, onPaste: { model.notePaste() }, onSubmit: { _ = model.send() },
                     onFocus: { composerFocused = $0 })
                .frame(minHeight: 36, idealHeight: 56, maxHeight: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                // UI1: a panel with a cyan focus ring, dim cyan while the composer is not focused.
                .background(JarvisTheme.panel.color, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(composerFocused ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color,
                                      lineWidth: composerFocused ? 1.5 : 1)
                }
                .padding(8)
                .onChange(of: model.draft.text) { model.noteTyping() }   // U1: typing holds an update back
        }
        .frame(minWidth: 420, minHeight: 360)
        // UI1 part 1: always dark, navy to the edges, ice-white text in the body face.
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        .tint(JarvisTheme.cyan.color)
        .background(JarvisTheme.navy.color)
        .preferredColorScheme(.dark)
        .background(WindowReader(onWindow: { window in
            JarvisTheme.style(window)
            onWindow(window)
        }))
        .onAppear {
            onAppear(openWindow)
        }
        .onChange(of: appearsActive, initial: true) {
            model.windowIsKey = appearsActive
        }
        .onDisappear {
            model.windowIsKey = false
        }
    }
}

/// The pending confirmation (plan §3.4, §3.12): what it will do, the seconds left of its 25,
/// and Confirm and Cancel. Confirm is the same as typing "confirm", so the system sheet
/// follows; Cancel sends nothing to the brain. Neither has a keyboard shortcut: Return belongs
/// to the composer.
private struct ConfirmationCard: View {
    let pending: PendingConfirmation
    let enabled: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(verbatim: pending.desc)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(JarvisTheme.gold.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(TextConfirmation.secondsLeft(until: pending.deadline, now: .now)) s")
                    .monospacedDigit()
                    .foregroundStyle(JarvisTheme.gold.color)
            }
            Button("Cancel", role: .cancel, action: onCancel)
            Button("Confirm", action: onConfirm)
        }
        .disabled(!enabled)
        .padding(10)
        // UI1: gold, the colour of whatever needs the user.
        .background(JarvisTheme.attentionFill.color, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(JarvisTheme.gold.color.opacity(0.55), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// One transcript row. User text and streaming text are plain; a finished assistant row is
/// markdown. A row fed by a retracted message (R6) is plain and struck through. An assistant
/// row with no text yet shows a spinner. A system row is the app's own note, small and centred.
/// UI1: the user's rows are outlined in dim cyan, his sit on a faint cyan glow.
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(verbatim: message.text)
                .padding(10)
                .background(JarvisTheme.panel.color, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(JarvisTheme.cyanDim.color, lineWidth: 1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Group {
                if message.retracted {
                    Text(verbatim: message.text)
                        .strikethrough()
                        .foregroundStyle(JarvisTheme.muted.color)
                } else if message.rendersMarkdown {
                    MarkdownText(text: message.text)
                } else if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(verbatim: message.text)
                }
            }
            .padding(10)
            .background(JarvisTheme.replyFill.color, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(JarvisTheme.cyan.color.opacity(JarvisTheme.replyBorderAlpha), lineWidth: 1)
            }
            .jarvisGlow()
            .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(verbatim: message.text)
                .font(JarvisTheme.small)
                .foregroundStyle(JarvisTheme.muted.color)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Reports the NSWindow its view is placed in (U1: the chat window's frame is saved before a
/// live update and restored after it).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        Reader(onWindow: onWindow)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Reader: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

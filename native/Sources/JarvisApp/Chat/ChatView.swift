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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive

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
                    .padding(16)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            if let pending = model.pending {
                ConfirmationCard(pending: pending, enabled: model.isConnected && !model.responding,
                                 onConfirm: { _ = model.confirmPending() },
                                 onCancel: { _ = model.cancelPending() })
            }
            if model.busy {
                Text(ChatViewModel.busyNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Composer(text: $model.draft.text, onPaste: { model.notePaste() }, onSubmit: { _ = model.send() })
                .frame(minHeight: 36, idealHeight: 56, maxHeight: 120)
                .padding(8)
                .onChange(of: model.draft.text) { model.noteTyping() }   // U1: typing holds an update back
        }
        .frame(minWidth: 420, minHeight: 360)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(TextConfirmation.secondsLeft(until: pending.deadline, now: .now)) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: onCancel)
            Button("Confirm", action: onConfirm)
        }
        .disabled(!enabled)
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// One transcript row. User text and streaming text are plain; a finished assistant row is
/// markdown. A row fed by a retracted message (R6) is plain and struck through. An assistant
/// row with no text yet shows a spinner. A system row is the app's own note, small and centred.
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(verbatim: message.text)
                .padding(8)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Group {
                if message.retracted {
                    Text(verbatim: message.text)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                } else if message.rendersMarkdown {
                    MarkdownText(text: message.text)
                } else if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(verbatim: message.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(verbatim: message.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

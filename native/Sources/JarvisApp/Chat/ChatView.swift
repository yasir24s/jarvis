import JarvisChat
import SwiftUI

/// The chat window (plan: M02-M04 §3.12): the transcript and the composer. The confirmation
/// card belongs to the next batch.
struct ChatView: View {
    static let windowID = "chat"

    @Bindable var model: ChatViewModel

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
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            AppDelegate.reassertAccessoryPolicy()
        }
    }
}

/// One transcript row. User text and streaming text are plain; a finished assistant row is
/// markdown. An assistant row with no text yet shows a spinner.
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
                if message.rendersMarkdown {
                    MarkdownText(text: message.text)
                } else if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(verbatim: message.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import AppKit
import JarvisChat
import JarvisTools
import SwiftUI

/// The chat window (plan: M02-M04 §3.12): the transcript, the confirmation card while one is
/// pending, and the composer.
struct ChatView: View {
    static let windowID = "chat"

    @Bindable var model: ChatViewModel
    /// M9a: push-to-talk (the mic button, and the live text while it listens); nil hides it.
    var talk: PushToTalkModel? = nil
    var brain: BrainSetting? = nil
    var mute: SpeechMute? = nil
    var speak: SpeakRepliesToggle? = nil
    /// Hands the app this window's opener each time the window appears, so the Dock icon can
    /// reopen it (D-43).
    var onAppear: (OpenWindowAction) -> Void = { _ in }
    /// Hands the app the window this view is in (U1 saves and restores its frame).
    var onWindow: (NSWindow) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    /// UI1: whether the composer has the keyboard, for its focus ring.
    @State private var composerFocused = false
    @State private var composerHeight: CGFloat = 48
    /// UI1 part 5: the user message being edited, and its text.
    @State private var editing: UUID?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label(brain.map { BrainSetting.title($0.shown) } ?? "Brain",
                      systemImage: "brain")
                    .help(model.backendLine)
                    .accessibilityLabel("Selected brain")
                    .accessibilityValue(brain.map { BrainSetting.title($0.shown) } ?? "Unknown")
                Spacer()
                let muted = mute?.muted ?? false
                let repliesOff = !(speak?.isOn ?? true)
                Label(muted ? "Muted" : (repliesOff ? "Typed replies silent" : "Voice on"),
                      systemImage: muted || repliesOff ? "speaker.slash" : "speaker.wave.2")
                    .accessibilityLabel("Speech status")
                    .accessibilityValue(muted ? "Muted" : (repliesOff ? "Typed replies silent" : "Voice on"))
            }
            .font(JarvisTheme.small)
            .foregroundStyle(JarvisTheme.cyan.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, edit: rowEditing(message))
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
            // M9a: why nothing was sent, for a few seconds, or that access is off.
            if let notice = talk?.notice {
                Text(notice)
                    .font(JarvisTheme.small)
                    .foregroundStyle(JarvisTheme.gold.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            let listening = (talk?.phase ?? .idle) != .idle
            HStack(alignment: .bottom, spacing: 8) {
                Composer(text: $model.draft.text, onPaste: { model.notePaste() }, onSubmit: { _ = model.send() },
                         onFocus: { composerFocused = $0 },
                         onEscape: {
                             guard model.canStop else { return false }
                             model.stop()
                             return true
                         }, onHeight: { composerHeight = $0 })
                    .frame(height: composerHeight)
                    // M9a: while the microphone is open the live text shows in the composer's
                    // place; the draft underneath is kept as it was.
                    .opacity(listening ? 0 : 1)
                    .overlay {
                        if listening, let talk { ListeningText(text: talk.preview) }
                    }
                if let talk { MicButton(talk: talk) }
                // UI1 part 4: Send, or Stop while a reply is being written or spoken.
                SendButton(canStop: model.canStop, canSend: model.isConnected && model.draft.input != nil,
                           onSend: { _ = model.send() }, onStop: { _ = model.stop() })
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // UI1: a panel with a cyan focus ring, dim cyan while the composer is not focused.
            .background(JarvisTheme.panel.color, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(composerFocused || listening ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color,
                                  lineWidth: composerFocused || listening ? 1.5 : 1)
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

extension ChatView {
    /// UI1 part 5: what a row needs to be edited and to switch versions.
    func rowEditing(_ message: ChatMessage) -> RowEditing {
        RowEditing(canEdit: model.canEdit(message), versions: model.versions(of: message),
                   versionsEnabled: !model.responding,
                   text: editing == message.id ? $editText : nil,
                   begin: {
                       editText = message.text
                       editing = message.id
                   },
                   cancel: { editing = nil },
                   send: {
                       if model.edit(message.id, to: editText) != nil { editing = nil }
                   },
                   show: { model.showVersion($0, of: message.id) })
    }
}

/// UI1 part 5: a user row's Edit and its versions' arrows.
struct RowEditing {
    let canEdit: Bool
    let versions: (index: Int, count: Int)?
    let versionsEnabled: Bool
    /// The text being edited, when this row is.
    let text: Binding<String>?
    let begin: () -> Void
    let cancel: () -> Void
    let send: () -> Void
    let show: (Int) -> Void
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
/// UI1: the user's rows are outlined in dim cyan, his sit on a faint cyan glow. UI1 part 5: a
/// user row shows Edit while hovered, and ‹ n/m › arrows once it has been edited.
private struct MessageRow: View {
    let message: ChatMessage
    let edit: RowEditing

    var body: some View {
        switch message.role {
        case .user:
            UserMessage(message: message, edit: edit)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.retracted {
                    Text(verbatim: message.text)
                        .strikethrough()
                        .foregroundStyle(JarvisTheme.muted.color)
                } else if message.rendersMarkdown {
                    if !message.text.isEmpty {
                        MarkdownText(text: message.text)
                    }
                } else if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(verbatim: message.text)
                }
                // UI1 part 4: what was shown before Stop stays, marked.
                if message.stopped {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(JarvisTheme.label)
                        .tracking(JarvisTheme.labelTracking / 2)
                        .textCase(.uppercase)
                        .foregroundStyle(JarvisTheme.muted.color)
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

/// UI1 part 5: one of the user's messages. Hovered, it offers Edit (when it can be edited);
/// editing shows its text in a field with Cancel and Send (Return sends, Esc cancels). An
/// edited message has arrows to switch between its versions.
struct UserMessage: View {
    let message: ChatMessage
    let edit: RowEditing
    @State private var hovering: Bool

    /// `hovering` starts the row as hovered (the snapshots); the pointer sets it after that.
    init(message: ChatMessage, edit: RowEditing, hovering: Bool = false) {
        self.message = message
        self.edit = edit
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let text = edit.text {
                EditField(text: text, cancel: edit.cancel, send: edit.send)
            } else {
                HStack(alignment: .center, spacing: 6) {
                    Button(action: edit.begin) {
                        Label("Edit", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JarvisTheme.cyan.color)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                    .accessibilityLabel("Edit")
                    .opacity(edit.canEdit && hovering ? 1 : 0)
                    .disabled(!(edit.canEdit && hovering))
                    Text(verbatim: message.text)
                        .padding(10)
                        .background(JarvisTheme.panel.color, in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(JarvisTheme.cyanDim.color, lineWidth: 1)
                        }
                }
            }
            if let versions = edit.versions, edit.text == nil {
                VersionArrows(index: versions.index, count: versions.count, enabled: edit.versionsEnabled,
                              show: edit.show)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
    }
}

/// UI1 part 5: the field an edit is written in.
struct EditField: View {
    @Binding var text: String
    let cancel: () -> Void
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(JarvisTheme.body)
                .foregroundStyle(JarvisTheme.ice.color)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .padding(10)
                .background(JarvisTheme.panel.color, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(JarvisTheme.cyan.color, lineWidth: 1.5)
                }
            HStack(spacing: 8) {
                Button("Cancel", action: cancel)
                Button("Send", action: send)
            }
            .font(JarvisTheme.small)
        }
        .frame(maxWidth: 440)
        .onAppear { focused = true }
    }
}

/// UI1 part 5: ‹ n/m ›, under an edited message.
struct VersionArrows: View {
    let index: Int
    let count: Int
    let enabled: Bool
    let show: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { show(index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(!enabled || index == 0)
                .accessibilityLabel("Previous version")
            Text(verbatim: "\(index + 1)/\(count)")
                .font(JarvisTheme.label)
                .monospacedDigit()
            Button { show(index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(!enabled || index == count - 1)
                .accessibilityLabel("Next version")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(JarvisTheme.muted.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version \(index + 1) of \(count)")
    }
}

/// UI1 part 4: the composer's button. Send (Return does the same); while a reply is being
/// written or spoken it is Stop, and Esc presses it.
private struct SendButton: View {
    let canStop: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        if canStop {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(JarvisTheme.cyan.color)
                    .frame(width: 28, height: 28)
                    .background(JarvisTheme.navy.color, in: .circle)
                    .overlay(Circle().strokeBorder(JarvisTheme.cyan.color, lineWidth: 1.5))
                    .jarvisGlow()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Stop (Esc)")
            .accessibilityLabel("Stop")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(JarvisTheme.navy.color)
                    .frame(width: 28, height: 28)
                    .background(canSend ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
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

import AppKit
import JarvisChat
import JarvisVoice
import SwiftUI

/// The setup window (M10 part 4) in the J.A.R.V.I.S. theme: navy to the edges, the reactor
/// faint behind, his words in the body face, tracked capitals for the headings, cyan for what
/// can be pressed and gold for what needs the user. One step at a time, with Back and Continue.
struct SetupView: View {
    static let windowID = "setup"
    static let size = CGSize(width: 580, height: 500)

    @Bindable var model: SetupModel
    /// Off in the snapshot tests, which set the step themselves: the window's appearing does not
    /// start the setup, and its closing does not stop a take.
    var startsOnAppear = true
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupHeader(step: model.step)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepContent
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Hairline()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        .tint(JarvisTheme.cyan.color)
        .background { ReactorBackdrop() }
        .background(JarvisTheme.navy.color)
        .preferredColorScheme(.dark)
        .background(SetupWindowReader { JarvisTheme.style($0) })
        .onAppear {
            model.close = { dismissWindow(id: Self.windowID) }
            if startsOnAppear { model.start() }
        }
        .onDisappear {
            if startsOnAppear { model.cancelRecording() }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome:
            Paragraph(SetupModel.Lines.welcome)
            Button {
                model.sayWelcome()
            } label: {
                Label("Say it again", systemImage: "speaker.wave.2")
            }
            .buttonStyle(SetupButtonStyle(kind: .quiet))
        case .permissions:
            Paragraph(SetupModel.Lines.permissions)
            PermissionsStatus(model: model)
        case .voice:
            VoiceStep(model: model)
        case .files:
            Paragraph(SetupModel.Lines.files)
            Toggle(FileLearningConsent.menuTitle, isOn: Bindable(model.fileLearning).isOn)
                .toggleStyle(.switch)
        case .speech:
            Paragraph(SetupModel.Lines.speech)
            Toggle("Speak replies", isOn: Bindable(model.speakReplies).isOn)
                .toggleStyle(.switch)
        case .done:
            Paragraph(SetupModel.Lines.done)
        }
    }

    private var footer: some View {
        HStack {
            if model.canGoBack {
                Button("Back") { model.back() }
                    .buttonStyle(SetupButtonStyle(kind: .quiet))
            }
            Spacer()
            if model.step == .done {
                Button("Done") { model.finish() }
                    .buttonStyle(SetupButtonStyle(kind: .prominent))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.next() }
                    .buttonStyle(SetupButtonStyle(kind: .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
        }
    }
}

/// "J.A.R.V.I.S. SETUP", the step's heading and six dots, cyan up to the current step.
private struct SetupHeader: View {
    let step: SetupModel.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("J.A.R.V.I.S.  SETUP")
                    .font(JarvisTheme.label)
                    .tracking(JarvisTheme.labelTracking)
                    .foregroundStyle(JarvisTheme.cyan.color)
                    .jarvisGlow()
                Text(step.heading)
                    .font(JarvisTheme.label)
                    .tracking(JarvisTheme.labelTracking / 2)
                    .foregroundStyle(JarvisTheme.muted.color)
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(SetupModel.Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s <= step ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color.opacity(0.6))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(SetupModel.Step.allCases.count)")
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionsStatus: View {
    let model: SetupModel

    var body: some View {
        switch model.access {
        case .unknown:
            Button("Allow Microphone and Speech Recognition") { model.askPermissions() }
                .buttonStyle(SetupButtonStyle(kind: .prominent))
        case .asking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS…").foregroundStyle(JarvisTheme.muted.color)
            }
        case .granted:
            Label("The microphone and speech recognition are on.", systemImage: "checkmark.circle")
                .foregroundStyle(JarvisTheme.cyan.color)
        case .microphoneDenied:
            Attention(SetupModel.Lines.microphoneDenied)
        case .speechRecognitionDenied:
            Attention(SetupModel.Lines.speechDenied)
        }
    }
}

/// Text that needs the user: gold on the attention fill, as the chat's confirmation card.
private struct Attention: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(JarvisTheme.small)
            .foregroundStyle(JarvisTheme.gold.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(JarvisTheme.attentionFill.color, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(JarvisTheme.gold.color.opacity(0.55), lineWidth: 1))
    }
}

/// The voice step: the voiceprint already there, the three takes with their meter, a retry.
private struct VoiceStep: View {
    let model: SetupModel

    var body: some View {
        switch model.voice {
        case .recording, .checking:
            Text("PHRASE \(take + 1) OF \(SetupModel.phrases.count)")
                .font(JarvisTheme.label)
                .tracking(JarvisTheme.labelTracking / 2)
                .foregroundStyle(JarvisTheme.muted.color)
            Text("“\(model.voiceLine)”")
                .font(.custom("Helvetica Neue", size: 20, relativeTo: .title3))
                .foregroundStyle(JarvisTheme.ice.color)
                .fixedSize(horizontal: false, vertical: true)
            LevelMeter(level: model.voice == .checking(take: take) ? 0 : model.level)
            Text(model.voice == .checking(take: take) ? "Checking…" : "Listening…")
                .font(JarvisTheme.small)
                .foregroundStyle(JarvisTheme.cyan.color)
        default:
            Paragraph(model.voiceLine)
        }
        TakeDots(good: model.goodTakes, shown: showsDots)
        actions
    }

    private var take: Int {
        switch model.voice {
        case .ready(let t), .recording(let t), .checking(let t), .retry(let t, _): t
        default: 0
        }
    }

    private var showsDots: Bool {
        switch model.voice {
        case .ready, .recording, .checking, .retry, .saving, .enrolled: true
        default: false
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.voice {
        case .waiting, .saving:
            ProgressView().controlSize(.small)
        case .existing:
            HStack(spacing: 12) {
                Button("Keep my voiceprint") { model.keepVoiceprint() }
                    .buttonStyle(SetupButtonStyle(kind: .prominent))
                Button("Record again for best accuracy") { model.recordAgain() }
                    .buttonStyle(SetupButtonStyle(kind: .quiet))
            }
        case .ready(let take):
            if model.microphoneAllowed {
                HStack(spacing: 12) {
                    Button(take == 0 ? "Begin" : "Record phrase \(take + 1)") { model.recordTake() }
                        .buttonStyle(SetupButtonStyle(kind: .prominent))
                    Button("Not now") { model.skipVoice() }
                        .buttonStyle(SetupButtonStyle(kind: .quiet))
                }
            } else {
                Attention(SetupModel.Lines.micOff)
                Button("Not now") { model.skipVoice() }
                    .buttonStyle(SetupButtonStyle(kind: .quiet))
            }
        case .retry:
            Button("Try again") { model.recordTake() }
                .buttonStyle(SetupButtonStyle(kind: .prominent))
        case .recording, .checking, .enrolled, .kept, .skipped, .failed:
            EmptyView()
        }
    }
}

/// The live level: a cyan bar over the panel, its length the frame's level.
private struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(JarvisTheme.panel.color)
                Capsule()
                    .fill(JarvisTheme.cyan.color)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, level))))
                    .jarvisGlow()
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 8)
        .overlay(Capsule().strokeBorder(JarvisTheme.cyan.color.opacity(JarvisTheme.hairlineAlpha), lineWidth: 1))
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// Three dots, one per phrase, cyan once its take is good.
private struct TakeDots: View {
    let good: Int
    let shown: Bool

    var body: some View {
        if shown {
            HStack(spacing: 8) {
                ForEach(0 ..< SetupModel.phrases.count, id: \.self) { i in
                    Image(systemName: i < good ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(i < good ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color)
                }
                Text("\(good) of \(SetupModel.phrases.count) phrases")
                    .font(JarvisTheme.small)
                    .foregroundStyle(JarvisTheme.muted.color)
            }
        }
    }
}

/// The window's buttons: prominent ones cyan with navy text, quiet ones outlined.
struct SetupButtonStyle: ButtonStyle {
    enum Kind { case prominent, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JarvisTheme.small.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(kind == .prominent ? JarvisTheme.navy.color : JarvisTheme.cyan.color)
            .background(kind == .prominent ? JarvisTheme.cyan.color : JarvisTheme.panel.color, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JarvisTheme.cyan.color.opacity(kind == .prominent ? 0 : 0.6), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(.rect(cornerRadius: 7))
    }
}

/// The hosting window, once there, for the theme's window styling.
private struct SetupWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

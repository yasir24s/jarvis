import JarvisChat
import SwiftUI

/// M9a: the composer's mic button, beside Send and drawn the same way: a cyan ring on navy, and
/// filled cyan with a glow while the microphone is open, breathing with its level. Hold it to
/// talk and let go to send; a click turns listening on and the next click sends.
struct MicButton: View {
    let talk: PushToTalkModel
    @State private var pressed = false

    var body: some View {
        let on = talk.isOn
        let finishing = talk.phase == .finishing
        Image(systemName: finishing ? "waveform" : (on ? "mic.fill" : "mic"))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(on ? JarvisTheme.navy.color : JarvisTheme.cyan.color)
            .frame(width: 28, height: 28)
            .background(on ? JarvisTheme.cyan.color : JarvisTheme.navy.color, in: .circle)
            .overlay(Circle().strokeBorder(on || finishing ? JarvisTheme.cyan.color : JarvisTheme.cyanDim.color,
                                           lineWidth: 1.5))
            .scaleEffect(on ? 1 + 0.12 * talk.level : 1)
            .animation(.easeOut(duration: 0.08), value: talk.level)
            .jarvisGlow(alpha: on ? JarvisTheme.glowAlpha + 0.5 * talk.level : 0)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        talk.buttonDown()
                    }
                    .onEnded { _ in
                        pressed = false
                        talk.buttonUp()
                    }
            )
            .opacity(talk.isConnected ? 1 : 0.45)
            .allowsHitTesting(talk.isConnected)
            .help(on ? "Listening: let go, or click again, to send"
                     : "Hold to talk, or click to start and click again to send (hold ⌥Space; ⌃⌥J anywhere)")
            .accessibilityElement()
            .accessibilityLabel(on ? "Stop listening and send" : "Talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { talk.toggle() }
    }
}

/// M9a: what the composer shows while the microphone is open: the live text, or "Listening…"
/// until there is some.
struct ListeningText: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                Text("Listening…")
                    .foregroundStyle(JarvisTheme.muted.color)
            } else {
                Text(text)
                    .foregroundStyle(JarvisTheme.ice.color)
            }
        }
        .font(JarvisTheme.body)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 5)
        .padding(.top, 1)
        .accessibilityLabel(text.isEmpty ? "Listening" : "Heard: \(text)")
    }
}

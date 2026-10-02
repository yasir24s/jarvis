import JarvisChat
import SwiftUI

/// UI1 part 3: hud.html drawn natively: the reactor, the status pill and the caption, bottom
/// centred, scaling from 0.8 and rising 8 pt as it shows over 0.45 s.
struct HUDView: View {
    let model: HUDModel

    var body: some View {
        let shown = model.shown
        let speaking = model.state == .speaking
        let accent = speaking ? JarvisTheme.gold.color : JarvisTheme.cyan.color
        VStack(spacing: 0) {
            ReactorView(mode: ReactorMode(model.state), level: model.level, paused: !shown)
            // .status: 11 pt bold capitals, letter-spaced .4em, on a dark translucent pill.
            Text(model.status)
                .font(.custom("Helvetica Neue", size: 11).weight(.bold))
                .tracking(JarvisTheme.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(JarvisTheme.ice.color)
                .shadow(color: accent, radius: 3)
                .shadow(color: .black, radius: 1, y: 1)
                .padding(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 14))
                .background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill(JarvisTheme.navy.color.opacity(0.55)))
                .overlay(Capsule().strokeBorder(speaking ? JarvisTheme.gold.color.opacity(0.5)
                                                         : JarvisTheme.cyan.color.opacity(0.35), lineWidth: 1))
                .padding(.top, 18)
            // .caption: 14 pt, at most 330 pt wide, fading in and out over .25 s.
            Text(model.caption ?? " ")
                .font(.custom("Helvetica Neue", size: 14))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(JarvisTheme.ice.color)
                .shadow(color: .black, radius: 1.5, y: 1)
                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                .background(RoundedRectangle(cornerRadius: 14).fill(JarvisTheme.navy.color.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(JarvisTheme.cyan.color.opacity(0.25),
                                                                         lineWidth: 1))
                .frame(maxWidth: 330)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .opacity(model.caption == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: model.caption == nil)
        }
        .scaleEffect(shown ? 1 : 0.8)
        .offset(y: shown ? 0 : 8)
        .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.45), value: shown)
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.45), value: shown)
        .frame(width: HUDPanel.size.width, height: HUDPanel.size.height - 14, alignment: .bottom)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
    }
}

extension ReactorMode {
    init(_ state: HUDState) {
        switch state {
        case .idle: self = .idle
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        }
    }
}

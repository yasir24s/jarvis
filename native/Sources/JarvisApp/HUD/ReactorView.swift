import AppKit
import SwiftUI

/// What the reactor shows: hud.html's `data-state`.
enum ReactorMode: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

/// UI1: hud.html's arc reactor, drawn natively. The 190 pt design, scaled to `diameter`:
/// - r1: a 2 pt ring, its top side cyan and its right side clear, turning every 7 s;
/// - r2: inset 16, dashed, turning back every 13 s;
/// - r3: inset 34, 2 pt, its bottom side gold and its left side clear, every 9 s;
/// - r4: inset 50, still;
/// - the ticks, inset 6: a 0.7° tick every 8.7°, 77 to 86 pt out, turning every 40 s;
/// - the core, inset 66: a radial gradient that breathes (scale 0.93 to 1.06, opacity 0.9 to 1)
///   every 3.4 s, every 1.1 s while thinking, and turns gold while speaking;
/// - 22 bars under it, 2 pt wide and 3 to 23 pt tall, centre-weighted, gold while speaking.
///
/// Every part is a shape that only turns, inside one `TimelineView`, so a frame changes
/// transforms and nothing is drawn again on the CPU. `paused` stops the timeline.
struct ReactorView: View {
    var mode: ReactorMode = .idle
    /// The bars' level, 0...1 (`jarvisLevel`): 0.6 listening and speaking, 0.35 thinking.
    var level: Double = 0
    var diameter: CGFloat = 190
    /// 1 turns at hud.html's periods; 0.5 at half its speed.
    var pace: Double = 1
    /// The shortest time between two frames.
    var frameInterval: TimeInterval = 1.0 / 30
    var paused = false
    /// Frames from a timer at `frameInterval` instead of the display's refresh, which an
    /// `.animation` timeline wakes for even when it draws less often.
    var steps = false
    var showsBars = true
    /// The reactor's drop shadow and the core's glow (the HUD); the chat's faint copy has none.
    var glows = true

    var body: some View {
        Group {
            if steps && !paused {
                TimelineView(.periodic(from: .now, by: frameInterval)) { timeline in
                    frame(at: timeline.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
                    frame(at: timeline.date)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func frame(at date: Date) -> ReactorFrame {
        ReactorFrame(time: date.timeIntervalSinceReferenceDate * pace, mode: mode, level: level,
                     diameter: diameter, showsBars: showsBars, glows: glows)
    }

    // MARK: - hud.html's numbers

    static let design: CGFloat = 190
    static let r1Period = 7.0, r2Period = 13.0, r3Period = 9.0, ticksPeriod = 40.0
    static let breathe = 3.4, breatheThinking = 1.1
    static let barCount = 22

    /// The turn of a part that spins every `period` seconds, in degrees, at `time`.
    static func spin(_ time: Double, period: Double) -> Double {
        let turns = (time / period).truncatingRemainder(dividingBy: 1)
        return (turns < 0 ? turns + 1 : turns) * 360
    }

    /// `breathe`: 0 at 0% and 100% of the period, 1 at 50%, eased in and out.
    static func breath(_ time: Double, period: Double) -> Double {
        0.5 - 0.5 * cos(2 * .pi * time / period)
    }

    /// Bar `index`'s height in design points: `3 + level·20·c·(0.5 + r)`, where `c` weights the
    /// centre and `r` in 0...1 wanders smoothly (hud.html draws a fresh random number per frame).
    static func barHeight(_ index: Int, level: Double, time: Double) -> Double {
        let middle = Double(barCount - 1) / 2
        let centre = 1 - abs(Double(index) - middle) / middle
        let rate = 9 + Double((index * 7) % 11) * 0.6
        let wander = 0.5 + 0.5 * sin(time * rate + Double(index) * 2.39)
        return 3 + level * 20 * centre * (0.5 + wander)
    }
}

/// One frame of the reactor at `time` (seconds, already scaled by the pace).
private struct ReactorFrame: View {
    let time: Double
    let mode: ReactorMode
    let level: Double
    let diameter: CGFloat
    let showsBars: Bool
    let glows: Bool

    private var scale: CGFloat { diameter / ReactorView.design }
    private var cyan: Color { JarvisTheme.cyan.color }
    /// `.ring`'s border colour, rgba(95,220,255,.22).
    private var faint: Color { cyan.opacity(0.22) }

    var body: some View {
        let s = scale
        let breath = ReactorView.breath(time, period: mode == .thinking ? ReactorView.breatheThinking : ReactorView.breathe)
        ZStack {
            // r1: 2 pt; top cyan, right clear, bottom and left faint.
            ZStack {
                side(inset: 0, width: 2, from: 0.125, to: 0.625, faint)
                side(inset: 0, width: 2, from: 0.625, to: 0.875, cyan)
            }
            .rotationEffect(.degrees(ReactorView.spin(time, period: ReactorView.r1Period)))
            // r2: inset 16, 1 pt dashed at .32, turning back.
            Circle()
                .inset(by: 16.5 * s)
                .stroke(cyan.opacity(0.32), style: StrokeStyle(lineWidth: s, dash: [3 * s, 3 * s]))
                .rotationEffect(.degrees(-ReactorView.spin(time, period: ReactorView.r2Period)))
            // r3: inset 34, 2 pt; bottom gold, left clear, top and right faint.
            ZStack {
                side(inset: 34, width: 2, from: 0.125, to: 0.375, JarvisTheme.gold.color)
                side(inset: 34, width: 2, from: 0.625, to: 1, faint)
                side(inset: 34, width: 2, from: 0, to: 0.125, faint)
            }
            .rotationEffect(.degrees(ReactorView.spin(time, period: ReactorView.r3Period)))
            // r4: inset 50, 1 pt at .16, still.
            Circle()
                .inset(by: 50.5 * s)
                .stroke(cyan.opacity(0.16), lineWidth: s)
            // The ticks.
            ReactorTicks()
                .fill(cyan.opacity(0.4))
                .rotationEffect(.degrees(ReactorView.spin(time, period: ReactorView.ticksPeriod)))
            core(s)
                .scaleEffect(0.93 + 0.13 * breath)
                .opacity(0.9 + 0.1 * breath)
            if showsBars {
                bars(s)
            }
        }
        .frame(width: diameter, height: diameter)
        .modifier(Glow(on: glows, color: cyan.opacity(0.45), radius: 4 * s))
    }

    /// One side of a bordered circle, as CSS splits a border at the diagonals. `from` and `to`
    /// run clockwise from 3 o'clock, in turns.
    private func side(inset: CGFloat, width: CGFloat, from: CGFloat, to: CGFloat, _ color: Color) -> some View {
        Circle()
            .inset(by: (inset + width / 2) * scale)
            .trim(from: from, to: to)
            .stroke(color, lineWidth: width * scale)
    }

    /// The core and its highlight (`.core`, `.core::after`), gold while speaking.
    @ViewBuilder
    private func core(_ s: CGFloat) -> some View {
        let speaking = mode == .speaking
        let gold = JarvisTheme.gold.color
        let stops: [Gradient.Stop] = speaking
            ? [.init(color: Color(.sRGB, red: 1, green: 0xF3 / 255, blue: 0xDA / 255), location: 0),
               .init(color: gold, location: 0.40),
               .init(color: Color(.sRGB, red: 0x8A / 255, green: 0x6A / 255, blue: 0x1F / 255), location: 0.74),
               .init(color: .clear, location: 1)]
            : [.init(color: JarvisTheme.ice.color, location: 0),
               .init(color: cyan, location: 0.38),
               .init(color: JarvisTheme.cyanDim.color, location: 0.72),
               .init(color: .clear, location: 1)]
        // `circle at 50% 45%` reaches its farthest corner, 43.1 pt away in the 58 pt core.
        ZStack {
            if glows {
                // box-shadow: 0 0 8px, 0 0 18px (20px speaking), 0 0 32px (36px speaking): each the
                // core's disc blurred by half its blur length, side by side as CSS draws them.
                let shadows: [(Color, CGFloat)] = speaking
                    ? [(gold, 8), (gold, 20), (gold.opacity(0.4), 36)]
                    : [(cyan, 8), (cyan, 18), (JarvisTheme.cyanDim.color, 32)]
                ForEach(shadows.indices, id: \.self) { index in
                    Circle()
                        .fill(shadows[index].0)
                        .blur(radius: shadows[index].1 / 2 * s)
                }
            }
            Circle()
                .fill(RadialGradient(stops: stops, center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0,
                                     endRadius: 43.1 * s))
            Circle()
                .fill(RadialGradient(stops: [.init(color: .white, location: 0),
                                             .init(color: .white.opacity(0.4), location: 0.45),
                                             .init(color: .clear, location: 0.70)],
                                     center: .center, startRadius: 0, endRadius: 22.6 * s))
                .padding(13 * s)
        }
        .frame(width: 58 * s, height: 58 * s)
    }

    /// `.bars`: centred, their bottom 4 pt below the reactor's.
    private func bars(_ s: CGFloat) -> some View {
        let color = mode == .speaking ? JarvisTheme.gold.color : cyan
        return HStack(alignment: .bottom, spacing: 2 * s) {
            ForEach(0..<ReactorView.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: s)
                    .fill(color)
                    .frame(width: 2 * s, height: ReactorView.barHeight(index, level: level, time: time) * s)
            }
        }
        .frame(height: 23 * s, alignment: .bottom)
        .modifier(Glow(on: glows, color: color, radius: 2.5 * s))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .offset(y: 4 * s)
    }
}

/// A glow (a shadow all round) when `on`; otherwise nothing, so no layer is drawn off screen.
private struct Glow: ViewModifier {
    let on: Bool
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        if on {
            content.compositingGroup().shadow(color: color, radius: radius)
        } else {
            content
        }
    }
}

/// `.ticks`: `repeating-conic-gradient(transparent 0 8deg, rgba(95,220,255,.4) 8deg 8.7deg)`
/// under a mask that keeps 77 to 86 pt from the centre: 41 ticks, from 12 o'clock clockwise.
struct ReactorTicks: Shape {
    static let period = 8.7, gap = 8.0
    static var count: Int { Int(((360 - gap) / period).rounded(.down)) + 1 }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / ReactorView.design
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let inner = 76.5 * s, outer = 86.5 * s
        var path = Path()
        for k in 0..<Self.count {
            let start = (Self.period * Double(k) + Self.gap - 90) * .pi / 180
            let end = start + (Self.period - Self.gap) * .pi / 180
            func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
                CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
            }
            path.move(to: point(inner, start))
            path.addLine(to: point(outer, start))
            path.addLine(to: point(outer, end))
            path.addLine(to: point(inner, end))
            path.closeSubpath()
        }
        return path
    }
}

/// UI1 part 2: the reactor behind the transcript, centred and faint. It turns at a fifth of
/// hud.html's speed, in steps twice a second, and stops while its window is off screen
/// (minimised, covered, on another Space, or the app hidden) and under Reduce Motion.
///
/// Twice a second is what keeps it cheap. Measured on screen, any timeline that drew four or
/// more times a second held about 3% of a core (the display stays awake between frames), while
/// three steps a second cost 0.37% and two 0.24%. At a fifth of the speed a step turns the outer
/// ring about 5°.
struct ReactorBackdrop: View {
    /// How strongly it shows (the brief: 0.08 to 0.12).
    static let opacity = 0.10
    static let pace = 1.0 / 5
    static let frameInterval = 1.0 / 2
    /// Its diameter, as a share of the shorter side of the transcript.
    static let share: CGFloat = 0.78

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    var body: some View {
        GeometryReader { proxy in
            ReactorView(diameter: min(proxy.size.width, proxy.size.height) * Self.share, pace: Self.pace,
                        frameInterval: Self.frameInterval, paused: reduceMotion || !onScreen, steps: true,
                        showsBars: false, glows: false)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .opacity(Self.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(WindowVisibilityReader { onScreen = $0 })
    }
}

/// Reports whether its window can be seen: not minimised, not wholly covered, on the current
/// Space, and the app not hidden (`NSWindow.occlusionState`). It reports once when it lands in
/// a window, then on every change.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Reader {
        Reader(onChange: onChange)
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.onChange = onChange
    }

    final class Reader: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            // After the current layout pass: SwiftUI state must not change during an update.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }
    }
}

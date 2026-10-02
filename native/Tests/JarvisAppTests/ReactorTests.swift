import AppKit
import Foundation
@testable import JarvisApp
import JarvisChat
import SwiftUI
import Testing
import WebKit

/// UI1 part 2: the reactor's numbers are hud.html's.
@Suite("UI1 reactor")
struct ReactorTests {
    @Test func partsTurnAtHUDPeriods() {
        #expect(ReactorView.spin(0, period: 7) == 0)
        #expect(abs(ReactorView.spin(3.5, period: 7) - 180) < 1e-9)
        #expect(abs(ReactorView.spin(7 + 1.75, period: 7) - 90) < 1e-9)
        #expect(abs(ReactorView.spin(-1.75, period: 7) - 270) < 1e-9)
        #expect((ReactorView.r1Period, ReactorView.r2Period, ReactorView.r3Period, ReactorView.ticksPeriod)
                == (7, 13, 9, 40))
    }

    @Test func coreBreathesOverThreePointFourSecondsAndFasterWhileThinking() {
        #expect(ReactorView.breath(0, period: ReactorView.breathe) == 0)
        #expect(abs(ReactorView.breath(1.7, period: ReactorView.breathe) - 1) < 1e-12)
        #expect(abs(ReactorView.breath(3.4, period: ReactorView.breathe)) < 1e-12)
        #expect(abs(ReactorView.breath(0.55, period: ReactorView.breatheThinking) - 1) < 1e-12)
        #expect((ReactorView.breathe, ReactorView.breatheThinking) == (3.4, 1.1))
    }

    @Test func barsAreCentreWeightedFromThreePoints() {
        #expect(ReactorView.barCount == 22)
        for t in stride(from: 0.0, to: 5, by: 0.37) {
            for i in 0..<ReactorView.barCount {
                #expect(ReactorView.barHeight(i, level: 0, time: t) == 3)
                let h = ReactorView.barHeight(i, level: 0.6, time: t)
                #expect(h >= 3 && h <= 3 + 0.6 * 20 * 1.5)
            }
            // The end bars carry no weight; the middle ones the most.
            #expect(ReactorView.barHeight(0, level: 0.6, time: t) == 3)
            #expect(ReactorView.barHeight(21, level: 0.6, time: t) == 3)
        }
    }

    @Test func fortyOneTicks() {
        #expect(ReactorTicks.count == 41)
    }

    @Test func backdropIsFaintAndSlow() {
        #expect(ReactorBackdrop.opacity >= 0.08 && ReactorBackdrop.opacity <= 0.12)
        #expect(ReactorBackdrop.pace < 1)
        #expect(ReactorBackdrop.frameInterval >= 0.5)
    }
}

/// UI1 part 2: what the reactor costs, measured on screen. Runs only with UI1_MEASURE=1, as it
/// opens a window for about a minute.
@Suite("UI1 reactor CPU", .serialized, .enabled(if: ProcessInfo.processInfo.environment["UI1_MEASURE"] == "1"))
@MainActor
struct ReactorCPUTests {
    /// Takes the view out of the window before closing it, so nothing in it keeps ticking.
    static func tearDown(_ window: NSWindow) {
        window.contentView = nil
        window.close()
        _ = cpuInAppLoop(over: 1)
    }

    static func window<V: View>(_ view: V) -> NSWindow {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 620),
                              styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        return window
    }

    /// The process's CPU time over `seconds` of `NSApp.run()`, the app's own loop, as a
    /// percentage of one core.
    static func cpuInAppLoop(over seconds: Double) -> Double {
        _ = NSApplication.shared
        let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wall = Date()
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                NSApp.stop(nil)
                NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
                                                   data1: 0, data2: 0)!, atStart: false)
            }
        }
        NSApp.run()
        let used = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start) / 1e9
        return used / Date().timeIntervalSince(wall) * 100
    }

    /// Each part on its own, to find what costs what.
    @Test func partsCPU() async throws {
        _ = Self.cpuInAppLoop(over: 0.5)   // NSApp launches once, as in the app
        var cases: [(String, AnyView)] = [
            ("text", AnyView(Text("still").frame(maxWidth: .infinity, maxHeight: .infinity))),
            ("reactor paused", AnyView(ReactorView(paused: true))),
        ]
        for fps in [12.0, 4, 3, 2] {
            cases.append(("backdrop-size reactor, steps at \(Int(fps)) a second",
                          AnyView(ReactorView(diameter: 440, pace: ReactorBackdrop.pace, frameInterval: 1 / fps,
                                              steps: true, showsBars: false, glows: false))))
        }
        cases.append(("HUD reactor speaking, animation 30 fps", AnyView(ReactorView(mode: .speaking, level: 0.6))))
        for (name, view) in cases {
            let window = Self.window(view)
            _ = Self.cpuInAppLoop(over: 2)
            let used = Self.cpuInAppLoop(over: 8)
            Self.tearDown(window)
            print(String(format: "UI1 CPU part %@: %.2f%%", name, used))
        }
    }

    @Test func chatBackdropIdleCPU() async throws {
        let model = ChatViewModel()
        model.post("Good evening, sir.")

        _ = Self.cpuInAppLoop(over: 0.5)   // NSApp launches once, as in the app
        // The same window with nothing animating: what the rest of the process costs.
        let still = Self.window(Text("still").frame(maxWidth: .infinity, maxHeight: .infinity))
        _ = Self.cpuInAppLoop(over: 2)
        let baseline = Self.cpuInAppLoop(over: 15)
        Self.tearDown(still)

        let chat = Self.window(ChatView(model: model))
        _ = Self.cpuInAppLoop(over: 3)
        let running = Self.cpuInAppLoop(over: 20)
        chat.miniaturize(nil)
        _ = Self.cpuInAppLoop(over: 3)
        let minimised = Self.cpuInAppLoop(over: 15)
        Self.tearDown(chat)

        print(String(format: "UI1 CPU chat backdrop: idle window %.2f%%, reactor turning %.2f%%, minimised %.2f%%",
                     baseline, running, minimised))
        #expect(running < 1)
        #expect(minimised < 0.2)
    }
}

/// UI1 part 2: the reactor as it draws, for the eye, next to hud.html (UI1_SNAPSHOT_DIR).
@Suite("UI1 reactor snapshots", .serialized, .enabled(if: UISnapshot.enabled))
@MainActor
struct ReactorSnapshotTests {
    @Test func reactorInEachMode() async throws {
        let modes: [(String, ReactorMode, Double)] = [("idle", .idle, 0), ("listening", .listening, 0.6),
                                                      ("thinking", .thinking, 0.35), ("speaking", .speaking, 0.6)]
        let row = HStack(spacing: 24) {
            ForEach(modes, id: \.0) { name, mode, level in
                VStack(spacing: 12) {
                    ReactorView(mode: mode, level: level, paused: true)
                    Text(name).font(JarvisTheme.label).tracking(JarvisTheme.labelTracking).textCase(.uppercase)
                        .foregroundStyle(JarvisTheme.ice.color)
                }
            }
        }
        .padding(30)
        .background(Color(white: 0.16))
        let url = try await UISnapshot.write(row, size: CGSize(width: 980, height: 300), name: "ui1-part2-reactor-modes")
        print("UI1 snapshot \(url.path)")
    }
}

/// The reference: the Python HUD's own hud.html, drawn by WebKit in each state, for the side by
/// side with `reactorInEachMode` (UI1_SNAPSHOT_DIR).
@Suite("UI1 hud.html reference", .serialized, .enabled(if: UISnapshot.enabled))
@MainActor
struct HUDReferenceSnapshotTests {
    static let hudHTML = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "hud.html")

    @Test func pythonHUDInEachState() async throws {
        _ = NSApplication.shared
        for (state, caption) in [("idle", ""), ("thinking", "What's on my calendar this afternoon?"),
                                 ("speaking", "You have two things, sir.")] {
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 430))
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            web.loadFileURL(Self.hudHTML, allowingReadAccessTo: Self.hudHTML.deletingLastPathComponent())
            for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            // An off-screen page runs no transitions, so they are switched off to show the end state.
            let js = "document.body.style.background='#292929';"
                + "const s=document.createElement('style');s.textContent='#hud,.caption{transition:none!important}';"
                + "document.head.appendChild(s);jarvisState('\(state)');"
                + (caption.isEmpty ? "" : "jarvisCaption(\(String(reflecting: caption)));")
            _ = try? await web.evaluateJavaScript(js)
            try await Task.sleep(for: .milliseconds(700))
            let image = try await web.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]), let folder = UISnapshot.folder else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = folder.appending(path: "ui1-reference-hudhtml-\(state).png")
            try png.write(to: url)
            print("UI1 snapshot \(url.path)")
            window.close()
        }
    }
}

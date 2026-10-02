import AppKit
import JarvisChat
import Observation
import SwiftUI

/// UI1 part 3: puts `HUDModel` on screen. The panel is ordered in when the model shows and out
/// once the hide animation is over, and the reactor's timeline is paused while hidden, so a
/// hidden HUD costs nothing. `JARVIS_NO_HUD=1` means no controller, so no panel (§3.7).
@MainActor
final class HUDController {
    /// hud.html's `.45s` show and hide.
    static let transition: Duration = .milliseconds(450)

    let model: HUDModel
    /// The panel; tests look at whether it is on screen.
    let panel = HUDPanel()
    private var orderOut: Task<Void, Never>?

    /// nil when the environment turns the HUD off (`JARVIS_NO_HUD=1`).
    static func make(model: HUDModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> HUDController? {
        environment["JARVIS_NO_HUD"] == "1" ? nil : HUDController(model: model)
    }

    init(model: HUDModel) {
        self.model = model
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: HUDPanel.size)
        panel.contentView = host
        follow()
    }

    /// Orders the panel in or out each time `model.shown` changes.
    private func follow() {
        withObservationTracking {
            _ = model.shown
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.shownChanged()
                self.follow()
            }
        }
    }

    private func shownChanged() {
        orderOut?.cancel()
        orderOut = nil
        if model.shown {
            if !panel.isVisible {
                panel.setFrame(HUDPanel.frame(on: (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero),
                               display: false)
            }
            panel.orderFrontRegardless()
        } else {
            orderOut = Task { [weak self] in
                try? await Task.sleep(for: Self.transition)
                guard !Task.isCancelled, let self, !self.model.shown else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

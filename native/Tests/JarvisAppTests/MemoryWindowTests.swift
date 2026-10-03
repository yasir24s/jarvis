import AppKit
import JarvisBrain
import JarvisChat
import JarvisCore
import SwiftUI
import Testing
@testable import JarvisApp

/// Batch C part 3: "Memory…" in both menus, and the window's view builds with and without a store.
@Suite("Batch C memory window, app side", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MemoryWindowTests {
    @Test("both menus list Memory…")
    func menus() throws {
        try BrainMenuTests.withDefaults { defaults in
            let menus = BrainMenuTests.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true))
            for menu in [menus.bar, menus.app] {
                menu.update()
                #expect(menu.items.contains { $0.title == MemoryEditor.menuTitle })
            }
        }
    }

    @Test("the window view lays out with no store attached")
    func view() {
        let host = NSHostingView(rootView: MemoryView(editor: MemoryEditor()))
        host.frame = NSRect(origin: .zero, size: MemoryWindowController.size)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}

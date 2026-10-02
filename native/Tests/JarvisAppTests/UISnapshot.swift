import AppKit
import Foundation
import SwiftUI

/// UI1: renders a view to a PNG, so the look can be checked by eye without launching the app.
/// The snapshot suites run only when `UI1_SNAPSHOT_DIR` names a folder; a plain `swift test`
/// skips them and writes nothing.
@MainActor
enum UISnapshot {
    nonisolated static let folder: URL? = ProcessInfo.processInfo.environment["UI1_SNAPSHOT_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    nonisolated static var enabled: Bool { folder != nil }

    /// Hosts `view` in an off-screen window of `size`, lets SwiftUI lay it out, and writes what
    /// it draws to `<folder>/<name>.png`. Returns the file.
    @discardableResult
    static func write<V: View>(_ view: V, size: CGSize, name: String,
                               settle: Duration = .milliseconds(400)) async throws -> URL {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: settle / 3)
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), let folder else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).png")
        try png.write(to: url)
        window.close()
        return url
    }
}

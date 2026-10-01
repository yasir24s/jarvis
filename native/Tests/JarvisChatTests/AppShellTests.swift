import Foundation
import JarvisChat
import Testing

/// The app shell (D-43): a regular app whose main window is the chat. Checked without
/// launching anything: the launch-argument rule, and the bundle's Info.plist.
@Suite("M4 app shell (D-43)")
struct AppShellTests {
    /// `native/`, found from this file.
    static let native = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("the chat window opens at launch unless the app was started with --background")
    func backgroundFlag() {
        #expect(ChatLaunch.backgroundFlag == "--background")
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS"]))
        #expect(!ChatLaunch.opensWindow(arguments: ["JARVIS", "--background"]))
        #expect(!ChatLaunch.opensWindow(arguments: ["JARVIS", "-NSQuitAlwaysKeepsWindows", "NO", "--background"]))
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS", "-NSQuitAlwaysKeepsWindows", "NO"]))
        // Only the exact flag, and never the executable's own name.
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS", "--background=1"]))
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS", "--Background"]))
        #expect(ChatLaunch.opensWindow(arguments: ["--background"]))
        #expect(ChatLaunch.opensWindow(arguments: []))
    }

    @Test("the bundle's Info.plist does not make JARVIS a UI element, and build-app.sh does not add it")
    func noLSUIElement() throws {
        let data = try Data(contentsOf: Self.native.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "com.jarvis.assistant")
        #expect(plist["LSUIElement"] == nil)
        #expect(plist["LSBackgroundOnly"] == nil)
        let script = try String(contentsOf: Self.native.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        #expect(!script.contains("LSUIElement"))
        #expect(!script.contains("LSBackgroundOnly"))
    }

    @Test("the Dock icon: Info.plist names AppIcon, and build-app.sh makes it from jarvis_icon.png")
    func dockIcon() throws {
        let data = try Data(contentsOf: Self.native.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        let script = try String(contentsOf: Self.native.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("$REPO/jarvis_icon.png"))
        #expect(script.contains("iconutil -c icns \"$ICONSET\" -o \"$STAGE/Contents/Resources/AppIcon.icns\""))
        let source = Self.native.deletingLastPathComponent().appending(path: "jarvis_icon.png")
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("Info.plist explains the Location request that get_wifi_status needs for the network name")
    func locationUsageStrings() throws {
        let data = try Data(contentsOf: Self.native.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
            let text = try #require(plist[key] as? String, "\(key) is missing")
            #expect(text.contains("Wi-Fi network"))
        }
    }
}

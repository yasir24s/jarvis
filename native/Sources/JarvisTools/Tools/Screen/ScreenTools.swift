import CoreGraphics
import Foundation
import ImageIO
import JarvisCore
import UniformTypeIdentifiers

/// `see_screen` (plan: M05-M06 §2a, §3.5, A-SCR-1). Python: `_screen_text()[:3500] or "Screen
/// not accessible."`, where `_screen_text` captures to `$TMPDIR/jarvis_screen.png`, OCRs it and
/// unlinks it, "" on any failure. Native hands the captured image straight to Vision, so no
/// screen PNG is written. Untrusted: the gateway taints the turn after it runs.
struct SeeScreen: ToolImpl {
    static let name = "see_screen"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let limit = 3500
    static let unavailable = "Screen not accessible."
    let capturer: any ScreenCapturing
    let recognizer: any TextRecognizing

    static func reply(_ text: String) -> String {
        let cut = Py.prefix(text, limit)
        return cut.isEmpty ? unavailable : cut
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard let image = await capturer.captureMainDisplay() else { return .text(Self.reply("")) }
        return .text(Self.reply(await recognizer.recognizeText(in: image)))
    }
}

/// `take_screenshot` (A-SCR-1). Python: `screencapture -x "~/Desktop/JARVIS Screenshot
/// <%Y-%m-%d at %H.%M.%S>.png"`, then success iff that file exists. Native writes the captured
/// main display as a PNG at the same path and answers by the same existence check. `clock` and
/// `timeZone` stand in for `datetime.now()`; `home` for `$HOME` in `expanduser`.
struct TakeScreenshot: ToolImpl {
    static let name = "take_screenshot"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let saved = "Screenshot saved to your desktop, sir."
    static let failed = "The screenshot failed, sir — check Screen Recording permission."
    let capturer: any ScreenCapturing
    let clock: any JarvisClock
    let timeZone: TimeZone
    let home: String

    /// `os.path.join(os.path.expanduser("~/Desktop"), f"JARVIS Screenshot {stamp}.png")`.
    func path() -> String {
        let stamp = PyTime.strftime("%Y-%m-%d at %H.%M.%S", Date(timeIntervalSince1970: clock.now()),
                                    timeZone: timeZone)
        let user = Py.rstrip(home, "/")
        return (user.isEmpty ? "/" : user) + "/Desktop/JARVIS Screenshot \(stamp).png"
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let path = path()
        if let image = await capturer.captureMainDisplay() {
            _ = Self.writePNG(image, to: path)
        }
        return .text(FileManager.default.fileExists(atPath: path) ? Self.saved : Self.failed)
    }

    /// ImageIO's PNG encoder; false when the folder is missing or the write fails.
    static func writePNG(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.7: see_screen and take_screenshot against m5_screen. The OCR cases run the native Vision
/// request on the rendered fixture PNGs that the REAL `_ocr_image` read (G17, exact text on the
/// same OS); the screen is always a fixture image, never a real capture.
@Suite("ScreenToolsTests")
struct ScreenToolsTests {
    static let suite = "m5_screen"

    static func cases(_ prefix: String) throws -> [M5Fixture.Case] {
        try M5Fixture.cases(Self.suite).filter { $0.name.hasPrefix(prefix + "/") }
    }

    @Test func fixtureHoldsEveryCase() throws {
        #expect(try Self.cases("ocr").count == 5)
        #expect(try Self.cases("see_screen").count == 6)
        #expect(try Self.cases("screenshot").count == 4)
    }

    /// G17: the native recogniser gives `_ocr_image`'s exact text for each fixture image.
    @Test func ocrMatchesPythonOnTheFixtureImages() async throws {
        let broken = await OCRProbe.accurateBroken.value
        try await withKnownIssue(OCRProbe.reason, isIntermittent: true) {
        for c in try Self.cases("ocr") {
            let relative = try #require(c.input.string("image"))
            let url = M5Fixture.url("x").deletingLastPathComponent().appending(path: relative)
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == c.input.string("sha256"), "\(c): the PNG is not the one Python read")
            let want = try #require(c.expected.string("text"))
            let text = await VisionTextRecognizer().recognizeText(in: try FixtureScreen.decode(relative))
            #expect(text == want, "\(c)")
        }
        } when: { broken }
    }

    /// The whole tool through the gateway over a fixture screen, then the turn is tainted.
    @Test func seeScreenThroughTheGatewayTaintsTheTurn() async throws {
        let broken = await OCRProbe.accurateBroken.value
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        try await withKnownIssue(OCRProbe.reason, isIntermittent: true) {
        for c in try Self.cases("see_screen") {
            let screen = try FixtureScreen(fixture: c.input.string("image"))
            let gateway = await M5Fixture.gateway(.fake(screen: screen, recognizer: VisionTextRecognizer()),
                                                  sandbox: sandbox)
            let turn = TurnContext(channel: .voice)
            let result = await gateway.call("see_screen", JSONObject(), turn: turn, origin: .model(.claude))
            let want = try #require(c.expected.string("text"))
            #expect(result.text == want, "\(c)")
            #expect(!result.isError, "\(c)")
            #expect(screen.captures == 1, "\(c)")
            #expect(await turn.tainted, "\(c): see_screen must taint the turn")
        }
        } when: { broken }
    }

    /// `[:3500] or "Screen not accessible."`, which the fixture images cannot reach.
    @Test func seeScreenSlicesAndFallsBack() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let image = try FixtureScreen.decode("m5_ocr/blank.png")
        let long = String(repeating: "😀", count: 5000)
        for (text, want) in [(long, Py.prefix(long, 3500)), ("", "Screen not accessible."), ("a", "a")] {
            let recognizer = FakeRecognizer(text)
            let gateway = await M5Fixture.gateway(.fake(screen: FixtureScreen(image), recognizer: recognizer),
                                                  sandbox: sandbox)
            let result = await gateway.call("see_screen", JSONObject(), turn: TurnContext(channel: .text),
                                            origin: .model(.local))
            #expect(Py.eq(result.text, want))
            #expect(recognizer.calls == 1)
        }
        // No capture (no Screen Recording grant): the recogniser is never asked.
        let recognizer = FakeRecognizer("never")
        let gateway = await M5Fixture.gateway(.fake(screen: FixtureScreen(nil), recognizer: recognizer), sandbox: sandbox)
        let result = await gateway.call("see_screen", JSONObject(), turn: TurnContext(channel: .text),
                                        origin: .model(.local))
        #expect(result.text == "Screen not accessible.")
        #expect(recognizer.calls == 0)
    }

    /// The Python path (with the stamp from the pinned clock), the reply, and the file: a PNG of
    /// the captured image, written under a temporary home.
    @Test func takeScreenshotMatchesPython() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let home = sandbox.root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: "Desktop"), withIntermediateDirectories: true)
        let homePath = home.path(percentEncoded: false)
        let source = try FixtureScreen.decode("m5_ocr/plain.png")
        for c in try Self.cases("screenshot") {
            let saved = c.input["saved"] == .bool(true)
            let clock = ManualClock(try #require(c.input.double("epoch")))
            let gateway = await M5Fixture.gateway(.fake(screen: FixtureScreen(saved ? source : nil), home: homePath),
                                                  clock: clock, sandbox: sandbox)
            let result = await gateway.call("take_screenshot", JSONObject(), turn: TurnContext(channel: .voice),
                                            origin: .model(.claude))
            #expect(result.text == c.expected.string("text"), "\(c)")
            let argv = (c.expected["argv"]?.arrayValue ?? []).compactMap { $0.stringValue }
            #expect(argv.count == 3 && argv.first == "screencapture", "\(c)")
            let pythonPath = try #require(argv.last)
            let want = Py.rstrip(homePath, "/") + pythonPath.dropFirst("${JARVIS_HOME}".count)
            let tool = TakeScreenshot(capturer: FixtureScreen(nil), clock: clock,
                                      timeZone: TimeZone(identifier: "Europe/London")!, home: homePath)
            #expect(tool.path() == want, "\(c)")
            #expect(FileManager.default.fileExists(atPath: want) == saved, "\(c)")
            if saved {
                let written = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: want) as CFURL, nil))
                #expect(CGImageSourceGetType(written) as String? == "public.png", "\(c)")
                let image = try #require(CGImageSourceCreateImageAtIndex(written, 0, nil))
                #expect(image.width == source.width && image.height == source.height, "\(c)")
                try FileManager.default.removeItem(atPath: want)
            }
        }
    }

    @Test func takeScreenshotFailsWithoutADesktopFolder() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let homePath = sandbox.root.appending(path: "no-desktop").path(percentEncoded: false)
        let gateway = await M5Fixture.gateway(.fake(screen: FixtureScreen(try FixtureScreen.decode("m5_ocr/blank.png")),
                                                    home: homePath), sandbox: sandbox)
        let result = await gateway.call("take_screenshot", JSONObject(), turn: TurnContext(channel: .voice),
                                        origin: .model(.claude))
        #expect(result.text == TakeScreenshot.failed)
        #expect(!FileManager.default.fileExists(atPath: homePath))
    }

    @Test func registeredSchemasAreTheCatalogEntries() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        let listed = await gateway.toolList()
        for schema in [SeeScreen.schema, TakeScreenshot.schema] {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == schema.name })
            #expect(schema == catalog)
            #expect(listed.first { $0.name == schema.name } == catalog)
        }
    }
}

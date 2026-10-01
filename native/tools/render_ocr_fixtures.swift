// Renders the G17 OCR fixture images (plan: M05-M06 §4 G17) with CoreText, once. The PNGs are
// committed; tools/golden_m5_screen.py runs the real `_ocr_image` on them and the Swift tests run
// the native Vision request on the same files, so both sides see identical pixels.
//
//     swift native/tools/render_ocr_fixtures.swift native/Tests/Fixtures/golden/m5_ocr
//
// CoreGraphics, CoreText and ImageIO only (no AppKit).
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Spec {
    let name: String
    let width: Int
    let height: Int
    let background: CGColor
    let foreground: CGColor
    let font: String
    let size: CGFloat
    let columns: [[String]]
}

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let darkGrey = CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
let lightGrey = CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)

let specs = [
    Spec(name: "plain", width: 1400, height: 420, background: white, foreground: black,
         font: "Helvetica", size: 30, columns: [[
            "The quick brown fox jumps over the lazy dog.",
            "Native JARVIS reads the screen with the Vision framework,",
            "one line per observation, joined with a newline.",
            "Meeting moved to Thursday at 3:30 PM in room 204.",
         ]]),
    Spec(name: "code", width: 1500, height: 420, background: white, foreground: black,
         font: "Menlo-Regular", size: 26, columns: [[
            "func total(_ xs: [Int]) -> Int {",
            "    return xs.reduce(0, +) // sum",
            "}",
            "if (a && b) || c != 0 { print(\"$5.00 @ 50%\") }",
            "let path = \"/tmp/report_v2.txt\"",
         ]]),
    Spec(name: "columns", width: 1600, height: 420, background: white, foreground: black,
         font: "Helvetica", size: 28, columns: [
            ["Left column heading", "Apples cost two pounds.", "Pears are on sale today."],
            ["Right column heading", "Trains leave at noon.", "Platform nine is closed."],
         ]),
    Spec(name: "dark", width: 1400, height: 360, background: darkGrey, foreground: lightGrey,
         font: "Helvetica", size: 30, columns: [[
            "Dark mode text is light on a dark background.",
            "Battery at 70 percent, on battery.",
            "Downloads folder: 12 items, 3.4 GB.",
         ]]),
    Spec(name: "blank", width: 800, height: 300, background: white, foreground: black,
         font: "Helvetica", size: 30, columns: [[]]),
]

func render(_ spec: Spec, to directory: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: spec.width, height: spec.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "render", code: 1)
    }
    ctx.setFillColor(spec.background)
    ctx.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
    let font = CTFontCreateWithName(spec.font as CFString, spec.size, nil)
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: spec.foreground]
    let columnWidth = CGFloat(spec.width) / CGFloat(spec.columns.count)
    for (c, lines) in spec.columns.enumerated() {
        for (i, line) in lines.enumerated() {
            let text = CFAttributedStringCreate(nil, line as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(text)
            let y = CGFloat(spec.height) - 60 - CGFloat(i) * spec.size * 2.0
            ctx.textPosition = CGPoint(x: 40 + CGFloat(c) * columnWidth, y: y)
            CTLineDraw(ctLine, ctx)
        }
    }
    guard let image = ctx.makeImage() else { throw NSError(domain: "render", code: 2) }
    let url = directory.appending(path: "\(spec.name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "render", code: 3)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "render", code: 4) }
    print("wrote \(url.lastPathComponent) \(spec.width)x\(spec.height)")
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for spec in specs { try render(spec, to: out) }

#!/usr/bin/env swift
// Measures small Home Screen widgets in an iPhone screenshot, to compare this widget with a reference
// widget (the Revolut one). See docs/widget-design.md.
//
// Usage:
//   swift scripts/compare-widget.swift measure <screenshot.png>
//     Finds the widgets, then prints for each one the text rows, the glyphs in each row
//     (position, size, ink), the darkest color of each row, and the button fill color.
//   swift scripts/compare-widget.swift fit <screenshot.png> <widget> <row> <text> [<first glyph> <last glyph>]
//     Renders <text> with Inter (Widget/Fonts/InterVariable.ttf) and the system font at many
//     sizes and weights, and prints the best matches for that row. <widget> and <row> are the
//     indexes that `measure` prints. When a row mixes fonts (for example "124" and ",82 €"),
//     give the glyph indexes (from 0, in `measure` order) of one part and only that part's text. The Mac draws text darker than the iPhone, so weights from
//     `fit` can be too light: check them with glyphs that both widgets show (see the docs).
//
// All values are in points, relative to the widget's top-left corner. Screenshots must be 3x.

import AppKit
import CoreText

let scale = 3.0

// MARK: - Pixels

/// Darkness of each pixel: 0 is white, 1 is black. Also keeps RGB for color reports.
struct Pixels {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        rgba = Array(UnsafeBufferPointer(start: buffer, count: width * height * 4))
    }

    // The bitmap context memory starts with the top row of the image.
    private func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = offset(x, y)
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
    }

    func darkness(_ x: Int, _ y: Int) -> Double {
        let (r, g, b) = rgb(x, y)
        return 1 - Double(r + g + b) / 765
    }

    func isWhite(_ x: Int, _ y: Int) -> Bool { darkness(x, y) < 0.015 }
}

func loadImage(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Cannot read image at \(path)")
    }
    return image
}

// MARK: - Widgets, rows, glyphs

struct Widget {
    let left: Int
    let top: Int
    let size: Int
}

/// Finds white widgets. The row with the most long white runs crosses the empty middle of each widget;
/// each run gives a widget's left and right edges. Small widgets are square, so the width gives the height.
func findWidgets(_ pixels: Pixels) -> [Widget] {
    func whiteRuns(_ y: Int) -> [(start: Int, end: Int)] {
        var runs: [(Int, Int)] = []
        var x = 0
        while x < pixels.width {
            guard pixels.isWhite(x, y) else { x += 1; continue }
            let start = x
            while x < pixels.width, pixels.isWhite(x, y) { x += 1 }
            if x - start >= 300 { runs.append((start, x - 1)) }
        }
        return runs
    }
    let rows = (0..<pixels.height).map { whiteRuns($0) }
    let best = rows.max { a, b in
        (a.count, a.reduce(0) { $0 + $1.end - $1.start }) < (b.count, b.reduce(0) { $0 + $1.end - $1.start })
    } ?? []
    let bestY = rows.firstIndex { $0.count == best.count && $0.map(\.start) == best.map(\.start) } ?? 0

    return best.map { run in
        let size = run.end - run.start + 1
        // Walk up at 70% of the width: between the title text and the badge, away from the rounded corners.
        let x = run.start + size * 7 / 10
        var top = bestY
        while top > 0, pixels.isWhite(x, top - 1) { top -= 1 }
        return Widget(left: run.start, top: top, size: size)
    }
}

struct Row {
    let top: Int
    let bottom: Int
}

struct Glyph {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int
    /// Sum of darkness, in units of fully dark points (pt²).
    let ink: Double
}

/// Text rows: bands of pixel rows with dark pixels in the left 75% of the widget
/// (the right side holds the badge and the update time).
func findRows(_ pixels: Pixels, _ widget: Widget) -> [Row] {
    let xs = (widget.left + widget.size / 20)..<(widget.left + widget.size * 3 / 4)
    var rows: [Row] = []
    var start: Int?
    for y in (widget.top + 4)..<(widget.top + widget.size - 4) {
        let hasInk = xs.contains { pixels.darkness($0, y) > 0.3 }
        if hasInk, start == nil { start = y }
        if !hasInk, let s = start {
            if y - s >= 6 { rows.append(Row(top: s, bottom: y - 1)) }
            start = nil
        }
    }
    return rows
}

/// Glyphs in a row: runs of columns that have any ink. Faint pixels (button fill) do not count.
func findGlyphs(_ pixels: Pixels, _ widget: Widget, _ row: Row) -> [Glyph] {
    let threshold = 0.05
    let xs = (widget.left + widget.size / 20)..<(widget.left + widget.size * 3 / 4)
    func columnHasInk(_ x: Int) -> Bool { (row.top...row.bottom).contains { pixels.darkness(x, $0) > threshold } }

    var glyphs: [Glyph] = []
    var x = xs.lowerBound
    while x < xs.upperBound {
        guard columnHasInk(x) else { x += 1; continue }
        let start = x
        while x < xs.upperBound, columnHasInk(x) { x += 1 }
        var top = row.bottom, bottom = row.top, ink = 0.0
        for gx in start..<x {
            for y in row.top...row.bottom {
                let d = pixels.darkness(gx, y)
                guard d > threshold else { continue }
                ink += d
                if d > 0.5 { top = min(top, y); bottom = max(bottom, y) }
            }
        }
        // A faint glyph (cut by the 75% limit) has no strong pixel: use the row height.
        if top > bottom { (top, bottom) = (row.top, row.bottom) }
        glyphs.append(Glyph(left: start, right: x - 1, top: top, bottom: bottom, ink: ink / (scale * scale)))
    }
    return glyphs
}

/// Text color: the median of the solid pixels (at least 80% of the darkest one), so antialiased
/// edges do not count.
func textColor(_ pixels: Pixels, _ glyphs: [Glyph]) -> (Int, Int, Int) {
    let all = glyphs.flatMap { g in (g.top...g.bottom).flatMap { y in (g.left...g.right).map { (pixels.darkness($0, y), $0, y) } } }
    let maxDark = all.map(\.0).max() ?? 0
    let solid = all.filter { $0.0 >= maxDark * 0.8 }.map { pixels.rgb($0.1, $0.2) }
    guard !solid.isEmpty else { return (255, 255, 255) }
    func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
    return (median(solid.map(\.0)), median(solid.map(\.1)), median(solid.map(\.2)))
}

func pt(_ pixels: Int) -> String { String(format: "%6.2f", Double(pixels) / scale) }

// MARK: - Commands

func measure(_ path: String) {
    let pixels = Pixels(loadImage(path))
    let widgets = findWidgets(pixels)
    guard !widgets.isEmpty else { fatalError("No widget found. Use a 3x screenshot with white widgets.") }

    for (index, widget) in widgets.enumerated() {
        print("widget \(index): origin px (\(widget.left), \(widget.top)), size \(pt(widget.size)) pt")
        for (rowIndex, row) in findRows(pixels, widget).enumerated() {
            let glyphs = findGlyphs(pixels, widget, row)
            let inkSum = glyphs.reduce(0) { $0 + $1.ink }
            print("  row \(rowIndex): y \(pt(row.top - widget.top))...\(pt(row.bottom + 1 - widget.top))",
                  "text rgb \(textColor(pixels, glyphs))", String(format: "ink %.2f", inkSum))
            for glyph in glyphs {
                print("    x \(pt(glyph.left - widget.left)) w \(pt(glyph.right - glyph.left + 1))",
                      "y \(pt(glyph.top - widget.top)) h \(pt(glyph.bottom - glyph.top + 1))",
                      String(format: "ink %7.2f", glyph.ink))
            }
        }
        // Button fill: a pixel inside the first button, 6 pt from its left edge, at the last row's middle.
        if let last = findRows(pixels, widget).last {
            let x = widget.left + Int(22 * scale), y = (last.top + last.bottom) / 2
            print("  button fill rgb near (22, \(pt(y - widget.top))) pt: \(pixels.rgb(x, y))")
        }
    }
}

/// Ink of rendered text, cropped to its bounding box and normalized to the darkest pixel,
/// so gray and black text compare by shape.
struct InkImage {
    let width: Int
    let height: Int
    let values: [Double]

    init(_ pixels: Pixels, x: Range<Int>, y: Range<Int>) {
        var raw = [Double]()
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min
        for yy in y { for xx in x where pixels.darkness(xx, yy) > 0.3 {
            x0 = min(x0, xx); x1 = max(x1, xx); y0 = min(y0, yy); y1 = max(y1, yy)
        } }
        let maxDark = y.flatMap { yy in x.map { pixels.darkness($0, yy) } }.max() ?? 1
        for yy in y0...y1 { for xx in x0...x1 { raw.append(pixels.darkness(xx, yy) / maxDark) } }
        width = x1 - x0 + 1
        height = y1 - y0 + 1
        values = raw
    }

    func difference(to other: InkImage) -> Double {
        let w = max(width, other.width), h = max(height, other.height)
        var total = 0.0
        for y in 0..<h { for x in 0..<w {
            let a = x < width && y < height ? values[y * width + x] : 0
            let b = x < other.width && y < other.height ? other.values[y * other.width + x] : 0
            total += abs(a - b)
        } }
        return total / Double(w * h)
    }
}

func render(_ text: String, font: CTFont) -> Pixels {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let width = Int((bounds.width + 10) * scale), height = Int((bounds.height + 10) * scale)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: 5 - bounds.minX, y: 5 - bounds.minY)
    CTLineDraw(line, context)
    return Pixels(context.makeImage()!)
}

func interFont(size: Double, weight: Double, opticalSize: Double) -> CTFont {
    let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../Widget/Fonts/InterVariable.ttf").standardizedFileURL
    guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor])?.first else {
        fatalError("Cannot read \(fontURL.path)")
    }
    let axes = [0x7767_6874: weight, 0x6F70_737A: opticalSize] // 'wght', 'opsz'
    let variation = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: axes] as CFDictionary)
    return CTFontCreateWithFontDescriptor(variation, size, nil)
}

func fit(_ path: String, widgetIndex: Int, rowIndex: Int, text: String, glyphRange: ClosedRange<Int>?) {
    let pixels = Pixels(loadImage(path))
    let widget = findWidgets(pixels)[widgetIndex]
    let row = findRows(pixels, widget)[rowIndex]
    let allGlyphs = findGlyphs(pixels, widget, row)
    let glyphs = glyphRange.map { Array(allGlyphs[$0]) } ?? allGlyphs
    let target = InkImage(pixels, x: glyphs.first!.left..<(glyphs.last!.right + 1), y: row.top..<(row.bottom + 1))

    // For each font and weight, a render at 20 pt gives the size with the target's width.
    // Only sizes within 1 pt of that are tried.
    typealias Candidate = (name: String, make: (Double) -> CTFont)
    var candidates: [Candidate] = []
    for weight in stride(from: 300.0, through: 900, by: 25) {
        candidates.append((String(format: "Inter %3.0f, text design", weight), { interFont(size: $0, weight: weight, opticalSize: 14) }))
        candidates.append((String(format: "Inter %3.0f, auto optical size", weight), { interFont(size: $0, weight: weight, opticalSize: $0) }))
    }
    for (name, weight) in [("regular", NSFont.Weight.regular), ("medium", .medium), ("semibold", .semibold), ("bold", .bold), ("heavy", .heavy)] {
        candidates.append(("System \(name)", { NSFont.systemFont(ofSize: $0, weight: weight) as CTFont }))
    }

    func ink(_ font: CTFont) -> InkImage {
        let rendered = render(text, font: font)
        return InkImage(rendered, x: 0..<rendered.width, y: 0..<rendered.height)
    }

    var results: [(difference: Double, name: String)] = []
    for candidate in candidates {
        let estimate = 20 * Double(target.width) / Double(ink(candidate.make(20)).width)
        for size in stride(from: (estimate * 4).rounded() / 4 - 1, through: (estimate * 4).rounded() / 4 + 1, by: 0.25) {
            let image = ink(candidate.make(size))
            guard abs(image.width - target.width) <= 6, abs(image.height - target.height) <= 3 else { continue }
            results.append((target.difference(to: image), String(format: "%@, %5.2f pt", candidate.name, size)))
        }
    }
    print("target \(pt(target.width)) x \(pt(target.height)) pt; lower difference is better")
    for result in results.sorted(by: { $0.difference < $1.difference }).prefix(8) {
        print(String(format: "  %.4f  %@", result.difference, result.name))
    }
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "measure" where arguments.count == 3:
    measure(arguments[2])
case "fit" where arguments.count == 6 || arguments.count == 8:
    let range = arguments.count == 8 ? Int(arguments[6])!...Int(arguments[7])! : nil
    fit(arguments[2], widgetIndex: Int(arguments[3])!, rowIndex: Int(arguments[4])!, text: arguments[5], glyphRange: range)
default:
    print("""
    Usage:
      swift scripts/compare-widget.swift measure <screenshot.png>
      swift scripts/compare-widget.swift fit <screenshot.png> <widget> <row> <text> [<first glyph> <last glyph>]
    """)
    exit(1)
}

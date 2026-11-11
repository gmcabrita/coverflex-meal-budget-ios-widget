#!/usr/bin/env swift
// Renders the widget on the Mac to docs/images/widget.png (used in README.md):
// light mode, dark mode, and "sign-in required", with a sample balance.
//
// Usage: swift scripts/render-widget-preview.swift [output.png]
//
// The widget view is iOS code, but SwiftUI, WidgetKit, and App Intents also exist on macOS.
// The script copies the widget sources to a temporary folder, removes what only the iOS targets
// need (`@main`, `#Preview`, `import CoverflexCore`), adds a small `main`, and compiles them with
// the CoverflexCore sources. The Mac draws text slightly darker than the iPhone.

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "..").standardizedFileURL
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appending(path: "docs/images/widget.png")

let work = FileManager.default.temporaryDirectory.appending(path: "render-widget-preview-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// Copies a source file without the parts that only work inside the iOS targets.
func copySource(_ relativePath: String) throws {
    var lines = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        .components(separatedBy: "\n")
    if let preview = lines.firstIndex(where: { $0.hasPrefix("#Preview") }) {
        lines.removeSubrange(preview...)
    }
    lines = lines
        .filter { $0 != "@main" && $0 != "import CoverflexCore" }
        .map { $0.hasPrefix("@main ") ? String($0.dropFirst("@main ".count)) : $0 }
    let name = relativePath.replacingOccurrences(of: "/", with: "_")
    try lines.joined(separator: "\n").write(to: work.appending(path: name), atomically: true, encoding: .utf8)
}

let coreSources = try FileManager.default
    .contentsOfDirectory(atPath: root.appending(path: "Packages/CoverflexCore/Sources/CoverflexCore").path)
    .filter { $0.hasSuffix(".swift") }
    .map { "Packages/CoverflexCore/Sources/CoverflexCore/\($0)" }
let sharedSources = try FileManager.default
    .contentsOfDirectory(atPath: root.appending(path: "Shared").path)
    .filter { $0.hasSuffix(".swift") }
    .map { "Shared/\($0)" }
for source in coreSources + sharedSources + ["Widget/MealBudgetWidget.swift", "Widget/InterFont.swift"] {
    try copySource(source)
}

let main = #"""
import AppKit
import CoreText
import SwiftUI

@main
struct RenderWidgetPreview {
    static func main() {
        MainActor.assumeIsolated { render() }
    }

    @MainActor
    static func render() {
        let arguments = CommandLine.arguments
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: arguments[1]) as CFURL, .process, nil)
        let time = Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: .now)!

        let content = HStack(spacing: 20) {
            card(BudgetSnapshot(balanceCents: 1248, fetchedAt: time), dark: false)
            card(BudgetSnapshot(balanceCents: 1248, fetchedAt: time), dark: true)
            card(BudgetSnapshot(balanceCents: 1248, fetchedAt: time, problem: .signInRequired("")), dark: false)
        }
        .padding(24)
        .background(
            LinearGradient(colors: [Color(white: 0.78), Color(white: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let png = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: arguments[2]))
    }

    /// One small widget (170 pt) with the Home Screen corner radius.
    @MainActor
    static func card(_ snapshot: BudgetSnapshot, dark: Bool) -> some View {
        MealBudgetWidgetView(snapshot: snapshot)
            .frame(width: 170, height: 170)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(dark ? Color(white: 0.11) : .white)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            )
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
"""#
try main.write(to: work.appending(path: "RenderWidgetPreview.swift"), atomically: true, encoding: .utf8)

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let sources = try FileManager.default.contentsOfDirectory(atPath: work.path)
    .filter { $0.hasSuffix(".swift") }
    .map { work.appending(path: $0).path }
let binary = work.appending(path: "render").path
guard try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", "-o", binary] + sources) == 0 else {
    fatalError("Compilation failed")
}
let font = root.appending(path: "Widget/Fonts/InterVariable.ttf").path
guard try run(binary, [font, output.path]) == 0 else { fatalError("Rendering failed") }
print("Wrote \(output.path)")

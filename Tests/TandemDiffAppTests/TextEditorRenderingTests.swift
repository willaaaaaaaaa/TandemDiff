import AppKit
import TandemDiffCore
import SwiftUI
import XCTest
@testable import TandemDiff

@MainActor
final class TextEditorRenderingTests: XCTestCase {
    func testCharacterDetailsStayWithTheirAlignmentAcrossFiltersAndEdits() async throws {
        let model = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        let left = "🧭 AAA\nanchor\n", right = "🧭 BBB\nanchor\nadded"
        XCTAssertTrue(model.edit(.left, raw: NSRange(), replacement: left))
        XCTAssertTrue(model.edit(.right, raw: NSRange(), replacement: right))
        for _ in 0..<200 where model.aligning { try await Task.sleep(for: .milliseconds(10)) }
        let original = try XCTUnwrap(model.characterDetails)
        XCTAssertEqual(original.spans(at: 0)?.left, [NSRange(location: 3, length: 3)])
        XCTAssertEqual(original.spans(at: 0)?.right, [NSRange(location: 3, length: 3)])
        XCTAssertEqual(original.spans(at: 2)?.left, [])
        XCTAssertEqual(original.spans(at: 2)?.right, [NSRange(location: 0, length: 5)])
        model.updateSettings { $0.mode = .changes }
        XCTAssertTrue(model.characterDetails === original)

        XCTAssertTrue(model.edit(.right, raw: NSRange(location: 3, length: 3), replacement: "AAB"))
        XCTAssertNil(model.characterDetails)
        for _ in 0..<200 where model.aligning { try await Task.sleep(for: .milliseconds(10)) }
        let updated = try XCTUnwrap(model.characterDetails)
        XCTAssertFalse(updated === original)
        XCTAssertEqual(updated.spans(at: 0)?.left, [NSRange(location: 5, length: 1)])
        XCTAssertEqual(updated.spans(at: 0)?.right, [NSRange(location: 5, length: 1)])

        let a = String(repeating: "A", count: 400), b = String(repeating: "B", count: 400)
        XCTAssertTrue(model.edit(.left, raw: NSRange(location: 0, length: left.utf16.count), replacement: a + "x" + a))
        XCTAssertTrue(model.edit(.right, raw: NSRange(location: 0, length: right.utf16.count), replacement: b + "x" + b))
        for _ in 0..<200 where model.aligning { try await Task.sleep(for: .milliseconds(10)) }
        let limited = try XCTUnwrap(model.characterDetails)
        XCTAssertNil(limited.spans(at: 0))
        XCTAssertNil(limited.spans(at: 0))
    }

    func testChangedGlyphsAndMissingRowsInBothViewModes() async throws {
        _ = NSApplication.shared
        let model = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(model.edit(.left, raw: NSRange(), replacement: "header\n🧭 common AAAA suffix\nanchor\n"))
        XCTAssertTrue(model.edit(.right, raw: NSRange(), replacement: "header\n🧭 common BBBB suffix\nanchor\nright only"))
        for _ in 0..<200 where model.aligning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.hunks.count, 2)
        for mode in [TextViewMode.all, .changes] {
            model.updateSettings { $0.mode = mode }
            for side in TextSide.allCases {
                let host = NSHostingView(rootView: TextNativeView(model: model, side: side))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: mode == .all ? .aqua : .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let editor = try XCTUnwrap(host.firstTextEditor)
                let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
                layout.ensureLayout(for: container)
                let origin = editor.textContainerOrigin
                func pixels(in text: String) throws -> [NSColor] {
                    let characters = (editor.string as NSString).range(of: text)
                    XCTAssertNotEqual(characters.location, NSNotFound)
                    let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                    let crop = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                    return try self.pixels(editor, in: crop)
                }
                func isRedInk(_ color: NSColor) -> Bool {
                    color.redComponent - color.greenComponent > 0.20 && color.redComponent - color.blueComponent > 0.18
                }
                let changedPixels = try pixels(in: side == .left ? "AAAA" : "BBBB")
                XCTAssertTrue(changedPixels.contains(where: isRedInk), "\(mode) \(side) changed text")
                XCTAssertFalse(try pixels(in: "common").contains(where: isRedInk))
                XCTAssertFalse(try pixels(in: "suffix").contains(where: isRedInk))
                if side == .right {
                    XCTAssertTrue(try pixels(in: "right only").contains(where: isRedInk), "\(mode) \(side) sole text")
                } else {
                    let y = origin.y + layout.extraLineFragmentRect.midY
                    let stripe = try self.pixels(editor, in: NSRect(x: 90, y: y, width: 100, height: 2))
                    let brightness = stripe.map(\.greenComponent)
                    XCTAssertGreaterThan((brightness.max() ?? 0) - (brightness.min() ?? 0), 0.03, "The missing side should show diagonal hatching")
                }
            }
        }
    }

    private func pixels(_ editor: NSTextView, in rect: NSRect) throws -> [NSColor] {
        let crop = rect.integral
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: crop))
        editor.cacheDisplay(in: crop, to: bitmap)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        }
    }

    func testEditorDoesNotPaintOverAdjacentContent() async throws {
        _ = NSApplication.shared
        let model = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.red.frame(height: 40)
            TextNativeView(model: model, side: .left)
            Color.red.frame(height: 40)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for y in [bitmap.pixelsHigh / 15, bitmap.pixelsHigh * 14 / 15] {
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.5, "The editor painted over the adjacent red bar")
        }
    }
}

private extension NSView {
    var firstTextEditor: NSTextView? {
        if let editor = self as? NSTextView { return editor }
        return subviews.lazy.compactMap(\.firstTextEditor).first
    }
}

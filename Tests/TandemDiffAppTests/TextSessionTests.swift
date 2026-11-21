import AppKit
import SwiftUI
import XCTest
@testable import TandemDiff
import TandemDiffCore

@MainActor
final class TextSessionTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Session did not reach expected state")
    }

    func testDifferenceMapKeepsDocumentPositionsAndRevealsSelectedFoldedHunk() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        let left = "start\nleft only\none\nold first\nold second\ntwo\nthree\nfour\nfive\nsix\nseven\nend"
        let right = "start\none\nnew first\nnew second\ntwo\nthree\nfour\nfive\nsix\nseven\nright only\nend"
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: left))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: right))
        try await waitUntil { session.canTransfer }
        for mode in [TextViewMode.all, .changes, .context, .equal] {
            session.updateSettings { $0.mode = mode }
            XCTAssertEqual(session.mapBands.map(\.rows), [1..<2, 3..<5, 11..<12])
            XCTAssertEqual(session.mapBands.map(\.left), [true, true, false])
            XCTAssertEqual(session.mapBands.map(\.right), [false, true, true])
        }

        session.goToMapRow(4)
        XCTAssertEqual(session.currentNumber, 2)
        XCTAssertEqual(session.activeRow, 4)
        XCTAssertEqual(session.settings.mode, .equal)
        for side in TextSide.allCases {
            let pane = session.pane(side)
            XCTAssertEqual(pane.projection.rows.compactMap(\.fold), [1..<2, 11..<12])
            XCTAssertEqual(pane.displaySelection?.location, pane.projection.rows.first(where: { $0.aligned == 4 })?.offset)
        }
        session.next(-1)
        XCTAssertEqual(session.currentNumber, 1)
        session.goToMapRow(4)
        session.next(1)
        XCTAssertEqual(session.currentNumber, 3)
        session.goToMapRow(8)
        XCTAssertEqual(session.currentNumber, 3)
        session.goToMapRow(0)
        XCTAssertEqual(session.currentNumber, 1)
        XCTAssertEqual(session.pane(.left).buffer.content.string, left)
        XCTAssertEqual(session.pane(.right).buffer.content.string, right)
    }

    func testDifferenceMapHonorsHiddenMinorChangesAndEmptyComparisons() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "start\nCase\nanchor\nold"))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "start\ncase\nanchor\nnew"))
        session.updateSettings { $0.ignoreCase = true }
        try await waitUntil { session.canTransfer }
        XCTAssertEqual(session.mapBands.map(\.kind), [.minor, .change])
        session.updateSettings { $0.hideMinor = true }
        XCTAssertEqual(session.mapBands.map(\.rows), [3..<4])
        session.goToMapRow(1)
        XCTAssertEqual(session.activeRow, 3)
        session.apply(from: .left)
        try await waitUntil { session.canTransfer }
        XCTAssertTrue(session.mapBands.isEmpty)
        let before = session.navigation
        session.goToMapRow(1)
        XCTAssertEqual(session.navigation, before)
    }

    func testDifferenceMapAccessibilityAdjustsTheSelectedChange() async throws {
        _ = NSApplication.shared
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "A\nleft\nB\nold"))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "A\nright\nB\nnew"))
        try await waitUntil { session.canTransfer }
        let host = NSHostingView(rootView: TextDifferenceMap(model: session))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 28, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func slider(in view: NSView) -> NSSlider? {
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap(slider).first
        }
        let control = try XCTUnwrap(slider(in: host))
        XCTAssertEqual(control.accessibilityRole(), .slider)
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(session.currentNumber, 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(session.currentNumber, 2)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual((control.accessibilityValue() as? NSNumber)?.intValue, 2)
        XCTAssertEqual((control.accessibilityMaxValue() as? NSNumber)?.intValue, 2)
        XCTAssertTrue(control.accessibilityPerformDecrement())
        XCTAssertEqual(session.currentNumber, 1)
        let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.height * 0.9), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        control.mouseDown(with: click)
        XCTAssertTrue(window.firstResponder === control)
        XCTAssertEqual(session.currentNumber, 2)
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        window.sendEvent(up)
        XCTAssertEqual(session.currentNumber, 1)

        session.apply(from: .left)
        try await waitUntil { session.canTransfer && control.maxValue == 1 }
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(session.currentNumber, 1)
        session.apply(from: .left)
        try await waitUntil { session.canTransfer && !control.isEnabled }
        XCTAssertFalse(control.accessibilityPerformIncrement())
    }

    func testComparisonControlsFollowViewFocusProtectionAndComposition() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "same\nleft"))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "same\nright"))
        try await waitUntil { session.canTransfer }
        session.focus(.right)
        session.updateSettings { $0.mode = .context }
        XCTAssertNil(session.comparisonDisplay)
        session.comparisonDisplay = .same
        XCTAssertEqual(session.settings.mode, .equal)
        session.comparisonDisplay = .differences
        XCTAssertEqual(session.settings.mode, .changes)
        session.comparisonDisplay = .all
        XCTAssertEqual(session.settings.mode, .all)
        XCTAssertEqual(session.focused, .right)

        session.next(1)
        XCTAssertTrue(session.canApplyChange(from: .left))
        XCTAssertTrue(session.canApplyChange(from: .right))
        session.setInheritedProtection(true)
        XCTAssertFalse(session.canApplyChange(from: .left))
        XCTAssertFalse(session.canApplyChange(from: .right))
        XCTAssertTrue(session.canNavigateDifferences)
        session.beginComposition(.right)
        XCTAssertFalse(session.canNavigateDifferences)
        XCTAssertFalse(session.canRefreshComparison)
        session.endComposition(.right)
        try await waitUntil { session.canNavigateDifferences }
        XCTAssertTrue(session.canRefreshComparison)
    }

    func testAlternateNavigationHonorsVoiceOverFieldEditingAndMarkedText() throws {
        var moves: [Int] = []
        let keys = ComparisonNavigationKeys(disabled: false, previous: { moves.append(-1) }, next: { moves.append(1) })
        func arrow(_ scalar: Unicode.Scalar, flags: NSEvent.ModifierFlags = [.control, .option]) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: String(scalar), charactersIgnoringModifiers: String(scalar),
                                           isARepeat: false, keyCode: scalar.value == 0xF700 ? 126 : 125))
        }
        let up = try arrow("\u{F700}"), down = try arrow("\u{F701}")
        XCTAssertTrue(keys.handle(up, responder: nil, voiceOver: false))
        XCTAssertTrue(keys.handle(down, responder: nil, voiceOver: false))
        XCTAssertFalse(keys.handle(up, responder: nil, voiceOver: true))
        XCTAssertFalse(keys.handle(try arrow("\u{F700}", flags: [.command, .option]), responder: nil, voiceOver: false))
        let text = NSTextView()
        text.isFieldEditor = true
        XCTAssertFalse(keys.handle(up, responder: text, voiceOver: false))
        text.isFieldEditor = false
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertFalse(keys.handle(down, responder: text, voiceOver: false))
        XCTAssertEqual(moves, [-1, 1])
    }

    func testEscapeReachesFileViewWithoutStealingFieldOrCompositionCommands() throws {
        var fields: [Bool] = []
        let keys = ComparisonNavigationKeys(disabled: true, previous: {}, next: {}, escape: { editingField in
            fields.append(editingField)
            return !editingField
        })
        func escape(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeated, keyCode: 53))
        }
        let editor = NSTextView()
        XCTAssertTrue(keys.handle(try escape(), responder: editor, voiceOver: false))
        editor.isFieldEditor = true
        XCTAssertFalse(keys.handle(try escape(), responder: editor, voiceOver: false))
        editor.isFieldEditor = false
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(keys.handle(try escape(), responder: editor, voiceOver: false))
        XCTAssertFalse(keys.handle(try escape(.option), responder: nil, voiceOver: false))
        XCTAssertFalse(keys.handle(try escape(repeated: true), responder: nil, voiceOver: false))
        XCTAssertEqual(fields, [false, true])
    }

    func testCopySelectedLinesUsesFindAndHunkNavigation() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        for useFind in [true, false] {
            if useFind {
                XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "A\nX\nB\nW\n"))
                XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "A\nY\nB\nZ\n"))
            } else {
                session.history(.right, redo: false)
            }
            try await waitUntil { session.canTransfer }
            session.select(.left, display: NSRange(location: 2, length: 1), multiple: false, updateFocus: true)
            if useFind {
                session.term = "W"
                session.find()
            } else {
                session.go(3)
            }
            session.apply(from: .left, selected: true)
            XCTAssertEqual(session.pane(.right).buffer.content.string, "A\nY\nB\nW\n")
        }
    }
    func testLineEndingConversionPreservesFinalLineAndIsUndoable() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: NSRange(), replacement: "one\ntwo\nlast"))
        session.convertLineEndings(.left, to: "\r\n")
        XCTAssertEqual(session.pane(.left).buffer.content.string, "one\r\ntwo\r\nlast")
        XCTAssertEqual(session.pane(.right).buffer.content.string, "")
        session.history(.left, redo: false)
        XCTAssertEqual(session.pane(.left).buffer.content.string, "one\ntwo\nlast")
        session.setInheritedProtection(true)
        session.convertLineEndings(.left, to: "\r")
        XCTAssertEqual(session.pane(.left).buffer.content.string, "one\ntwo\nlast")
    }

    func testFileBarsResolvePathsAndKeepBuffersOnFailedOpenAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let left = directory.appendingPathComponent("草 稿.txt"), right = directory.appendingPathComponent("定稿.txt")
        try Data("first".utf8).write(to: left)
        try Data("second".utf8).write(to: right)
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        await session.openPath(left.absoluteString, on: .left)
        await session.openPath("定稿.txt", on: .right)
        XCTAssertEqual(session.leftURL?.path, left.path)
        XCTAssertEqual(session.rightURL?.path, right.path)
        XCTAssertTrue(session.edit(.left, raw: NSRange(), replacement: "draft "))
        XCTAssertTrue(session.edit(.right, raw: NSRange(), replacement: "more "))
        var count = 0
        session.promptUnsaved = { _, _ in
            count += 1
            return count == 1 ? .alertSecondButtonReturn : .alertThirdButtonReturn
        }
        await session.reload()
        XCTAssertEqual(session.pane(.left).buffer.content.string, "draft first")
        XCTAssertEqual(session.pane(.right).buffer.content.string, "more second")
        try FileManager.default.removeItem(at: right)
        session.promptUnsaved = { _, _ in .alertSecondButtonReturn }
        await session.reload()
        XCTAssertTrue(session.pane(.left).buffer.isDirty)
        XCTAssertTrue(session.pane(.right).buffer.isDirty)
        await session.openPath("missing.txt", on: .left)
        XCTAssertEqual(session.leftURL?.path, left.path)
        XCTAssertEqual(session.pane(.left).buffer.content.string, "draft first")
        try Data("new".utf8).write(to: right)
        await session.reload()
        XCTAssertEqual(session.pane(.left).buffer.content.string, "first")
        XCTAssertEqual(session.pane(.right).buffer.content.string, "new")
        XCTAssertFalse(session.isDirty)
    }

    func testOpenReservesSideAndDestinationWhileSavingPreviousEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt"), incoming = directory.appendingPathComponent("incoming.txt")
        try Data("old".utf8).write(to: original)
        try Data("new".utf8).write(to: incoming)
        let registry = EditRegistry()
        let session = TextSessionModel(left: original, right: nil, writer: registry.writer)
        let other = TextSessionModel(left: nil, right: nil, writer: registry.writer)
        registry.register(session, id: UUID()) { true }
        registry.register(other, id: UUID()) { true }
        try await waitUntil { session.canTransfer }
        XCTAssertTrue(session.edit(.left, raw: NSRange(location: 3, length: 0), replacement: "!"))
        session.promptUnsaved = { _, url in
            XCTAssertEqual(url, original)
            return .alertFirstButtonReturn
        }

        await session.openFile(incoming, on: .left) { url in
            session.swap()
            XCTAssertEqual(session.leftURL, original)
            XCTAssertFalse(session.edit(.left, raw: NSRange(), replacement: "reentrant edit"))
            await session.openFile(incoming, on: .right)
            await other.openFile(incoming, on: .left)
            XCTAssertNil(session.rightURL)
            XCTAssertNil(other.leftURL)
            let baseline = try WriteBaseline.read(url, maxBytes: TextBuffer.maxBytes)
            return (baseline, try TextBuffer(data: baseline.data, format: baseline.kind))
        }
        XCTAssertEqual(session.leftURL, incoming)
        XCTAssertEqual(session.pane(.left).buffer.content.string, "new")
        XCTAssertEqual(try Data(contentsOf: original), Data("old!".utf8))
        XCTAssertEqual(try Data(contentsOf: incoming), Data("new".utf8))

        XCTAssertTrue(session.edit(.left, raw: NSRange(location: 3, length: 0), replacement: " draft"))
        session.promptUnsaved = { _, _ in
            session.mayBind = { _ in false }
            return .alertSecondButtonReturn
        }
        await session.openFile(original, on: .left)
        XCTAssertEqual(session.leftURL, incoming)
        XCTAssertEqual(session.pane(.left).buffer.content.string, "new draft")
        XCTAssertTrue(session.isDirty)
    }

    func testCancelledClosePreservesEditsAndReleasesReservation() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "left"))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "right"))
        var count = 0
        session.promptUnsaved = { _, _ in
            count += 1
            return count == 1 ? .alertSecondButtonReturn : .alertThirdButtonReturn
        }
        let cancelled = await session.canClose()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(session.pane(.left).buffer.content.string, "left")
        XCTAssertEqual(session.pane(.right).buffer.content.string, "right")
        session.promptUnsaved = { _, _ in .alertSecondButtonReturn }
        var commit = await session.prepareToClose()
        XCTAssertNotNil(commit)
        XCTAssertFalse(session.edit(.left, raw: .init(), replacement: "blocked"))
        commit = nil
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "kept "))
        XCTAssertEqual(session.pane(.left).buffer.content.string, "kept left")
        let accepted = await session.canClose()
        XCTAssertTrue(accepted)
        XCTAssertFalse(session.isDirty)
    }

    func testSelectedSpacerRangeAndFoldedViewUseVisibleRows() async throws {
        let session = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(session.edit(.left, raw: .init(), replacement: "same\nold\nsame2\nW\n"))
        XCTAssertTrue(session.edit(.right, raw: .init(), replacement: "same\nextra\nplus\nsame2\nZ\n"))
        try await waitUntil { session.canTransfer }
        let left = session.pane(.left)
        let old = try XCTUnwrap(left.projection.rows.first { $0.line == 1 })
        let spacer = try XCTUnwrap(left.projection.rows.first { $0.line == nil })
        session.select(.left, display: NSRange(location: old.offset, length: spacer.offset - old.offset + 1), multiple: false, updateFocus: true)
        session.apply(from: .left, selected: true)
        XCTAssertEqual(session.pane(.right).buffer.content.string, "same\nold\nsame2\nZ\n")
        try await waitUntil { session.canTransfer }
        session.term = "W"
        session.find()
        session.updateSettings { $0.mode = .changes }
        session.apply(from: .left, selected: true)
        XCTAssertEqual(session.pane(.right).buffer.content.string, "same\nold\nsame2\nW\n")
    }
}

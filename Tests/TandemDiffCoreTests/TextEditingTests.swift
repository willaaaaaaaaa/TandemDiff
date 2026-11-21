import Foundation
import XCTest
@testable import TandemDiffCore

final class TextEditingTests: XCTestCase {
    private func buffer(_ string: String, _ kind: TextKind = .utf8) throws -> TextBuffer {
        try TextBuffer(data: kind.encode(string), format: kind)
    }

    func testLongDisjointReplacementsHaveExactCharacterRanges() throws {
        let old = String(repeating: "A", count: 400), new = String(repeating: "B", count: 400)
        for (prefix, suffix) in [("", ""), ("🧭 ", " end")] {
            let changes = try TextAlignment.characterChanges(prefix + old + suffix, prefix + new + suffix)
            let expected = [NSRange(location: prefix.utf16.count, length: 400)]
            XCTAssertEqual(changes.left, expected)
            XCTAssertEqual(changes.right, expected)
        }
    }

    func testEveryEncodingRoundTripsMixedEndingsScalarsAndEmpty() throws {
        for kind: TextKind in [.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            for string in ["", "a\nb\r\n中\rc", "\r\n", "e\u{301} 👩🏽‍💻\n", "\u{feff}extra mark"] {
                let bytes = try kind.encode(string)
                let input = try TextBuffer(data: bytes, format: kind)
                XCTAssertEqual(try input.encoded(), bytes)
                XCTAssertTrue(input.content.string.utf8.elementsEqual(string.utf8))
                XCTAssertFalse(input.isDirty)
            }
        }
        XCTAssertEqual(try buffer("").content.lines.count, 0)
        XCTAssertEqual(try buffer("\n").content.lines.count, 1)
        XCTAssertEqual(try buffer("a\rb\r\nc\n").content.preferredEnding, "\r")
        XCTAssertEqual(try buffer("a\rb\r\nc\r\n").content.preferredEnding, "\r\n")
        XCTAssertThrowsError(try TextBuffer(data: Data([0xff, 0xfe, 0x00, 0xd8]), format: .utf16LE))
    }

    func testFormatChangesScalarDifferencesAndGraphemeBoundaries() throws {
        let a = try buffer("e\u{301}👩🏽‍💻a\nsecond\r\n"), b = try buffer("é👩🏽‍💻b\nsecond")
        let map = try TextAlignment(a.content, b.content)
        XCTAssertEqual(map.rows.map(\.kind), [.change, .ending])
        let ranges = try TextAlignment.characterChanges(a.content.lines[0].text, b.content.lines[0].text)
        XCTAssertEqual(ranges.left.map { (a.content.lines[0].text as NSString).substring(with: $0) }.map { Data($0.utf8) }, [Data("e\u{301}".utf8), Data("a".utf8)])
        XCTAssertEqual(ranges.right.map { (b.content.lines[0].text as NSString).substring(with: $0) }, ["é", "b"])
        let emoji = try TextAlignment.characterChanges("hi👩🏽‍💻!", "hi👨‍👧‍👧!")
        XCTAssertEqual(emoji.left, [NSRange(location: 2, length: "👩🏽‍💻".utf16.count)])
    }

    func testLineTransferHonorsBothJoinsAndSingleUndo() throws {
        let left = try buffer("A\nX"), right = try buffer("A\nY\nZ\n", .utf16LE)
        let map = try TextAlignment(left.content, right.content)
        XCTAssertEqual(map.hunks(), [1..<3])
        let src = map.interval(1..<2, side: .left), dest = map.interval(1..<2, side: .right)
        try right.splice(dest, from: left.content.lines[src])
        XCTAssertEqual(try right.encoded(), Data([0xff,0xfe,65,0,10,0,88,0,10,0,90,0,10,0]))
        try right.undo()
        XCTAssertEqual(right.content.string, "A\nY\nZ\n")
        XCTAssertFalse(right.isDirty)
        try right.redo()
        XCTAssertEqual(right.content.string, "A\nX\nZ\n")
        XCTAssertEqual(try left.encoded(), Data("A\nX".utf8))
        let target = try buffer("head\r\nend")
        try target.splice(2..<2, from: left.content.lines[1..<2])
        XCTAssertEqual(target.content.string, "head\r\nend\r\nX")
        try target.undo()
        XCTAssertEqual(target.content.string, "head\r\nend")
    }

    func testDeletingCharactersBetweenIndependentTerminatorsPreservesBothRows() throws {
        let input = try buffer("X\rYY\nZ\n")
        try input.replace(NSRange(location: 2, length: 2), with: "", keyboardEndings: true)
        XCTAssertEqual(input.content.string, "X\r\n\nZ\n")
        try input.undo()
        XCTAssertTrue(try input.replaceAll("Y", with: "", caseSensitive: true))
        XCTAssertEqual(input.content.string, "X\r\n\nZ\n")
        try input.undo()
        XCTAssertEqual(input.content.string, "X\rYY\nZ\n")
        let crlf = try buffer("A\r\nB\nC\nD")
        XCTAssertTrue(try crlf.replaceAll("\n", with: "\n", caseSensitive: true))
        XCTAssertEqual(crlf.content.string, "A\r\nB\nC\nD")
    }

    func testLineTransfersPreserveBlankRowsAtMixedEndingJoins() throws {
        for (original, target, incoming, expected) in [
            ("Y\n\nZ\n", 0..<1, "X\r", "X\r\n\nZ\n"),
            ("X\rY\n", 1..<2, "\nZ\n", "X\r\r\nZ\n"),
            ("X\rY\n\nZ\n", 1..<2, "", "X\r\n\nZ\n"),
            ("X\rY\n\nZ\n", 1..<2, "\nA\r", "X\r\r\nA\r\n\nZ\n")
        ] {
            let receiver = try buffer(original)
            try receiver.splice(target, from: try buffer(incoming).content.lines[...])
            XCTAssertEqual(try receiver.encoded(), Data(expected.utf8))
            try receiver.undo()
            XCTAssertEqual(try receiver.encoded(), Data(original.utf8))
            try receiver.redo()
            XCTAssertEqual(try receiver.encoded(), Data(expected.utf8))
        }
    }

    func testCompleteBlockTransfersSourceTerminatorsButKeepsEncoding() throws {
        let source = try buffer("core\r\nnew\nend")
        let target = try buffer("core\r\nold\r\nend", .utf16BE)
        let map = try TextAlignment(source.content, target.content)
        let change = try XCTUnwrap(map.hunks().first)
        try target.splice(map.interval(change, side: .right), from: source.content.lines[map.interval(change, side: .left)])
        XCTAssertEqual(try target.encoded(), try TextKind.utf16BE.encode("core\r\nnew\nend"))
        XCTAssertEqual(try source.encoded(), Data("core\r\nnew\nend".utf8))
    }

    func testDisplayRulesKeepEndingsVisibleAndRevealFolds() throws {
        let a = try buffer("same\nxß \tZ\nend\r"), b = try buffer("same\nXSSz\nend\n")
        var options = TextComparisonOptions()
        options.ignoreCase = true; options.ignoreWhitespace = true
        let map = try TextAlignment(a.content, b.content, options: options)
        XCTAssertEqual(map.rows.map(\.kind), [.equal, .minor, .ending])
        XCTAssertEqual(map.hunks(hideMinor: true), [2..<3])
        XCTAssertEqual(map.visible(mode: .changes, context: 3, hideMinor: true, revealed: []), [.fold(0..<2), .line(2)])
        XCTAssertEqual(map.visible(mode: .changes, context: 3, hideMinor: true, revealed: IndexSet(integer: 1)), [.fold(0..<1), .line(1), .line(2)])
        XCTAssertEqual(map.visible(mode: .context, context: 1, hideMinor: true, revealed: []), [.fold(0..<2), .line(2)])
        XCTAssertEqual(a.content.string, "same\nxß \tZ\nend\r")
    }

    func testDeterministicAlignmentWithRepeatedValues() throws {
        let a = try buffer("x\na\na\n"), b = try buffer("y\na\n")
        let c = try buffer("a\nx\n")
        for _ in 0..<2 {
            let map = try TextAlignment(a.content, b.content)
            XCTAssertEqual(map.rows.filter { $0.kind == .equal }.compactMap(\.left), [1])
            let crossed = try TextAlignment(try buffer("x\na\n").content, c.content)
            XCTAssertEqual(crossed.rows.filter { $0.kind == .equal }.compactMap(\.left), [0])
            let repeated = try TextAlignment(try buffer("a\nb\na\n").content, try buffer("b\na\na\n").content)
            XCTAssertEqual(repeated.rows.filter { $0.kind == .equal }.compactMap(\.left), [1, 2])
        }
    }

    func testSpacersNeverBecomeTextAndProjectedCRLFMapsToWholeSeparator() throws {
        let a = try buffer("Start\r\nEnd"), b = try buffer("Start\r\nextra\nEnd")
        let map = try TextAlignment(a.content, b.content)
        let projection = TextProjection(content: a.content, side: .left, map: map, visible: map.visible(mode: .all, context: 3, hideMinor: false, revealed: []))
        XCTAssertEqual(projection.string, "Start\n\nEnd")
        XCTAssertNil(projection.rows[1].line)
        XCTAssertEqual(projection.rawRange(NSRange(location: 0, length: 10)), NSRange(location: 0, length: 10))
        XCTAssertEqual(map.interval(0..<3, side: .left), 0..<2)
        let plain = TextProjection(content: a.content, side: .left)
        XCTAssertEqual(plain.rawRange(NSRange(location: 5, length: 1)), NSRange(location: 5, length: 2))
        let folded = TextProjection(content: a.content, side: .left, map: map, visible: [.fold(0..<2), .line(2)])
        XCTAssertNil(folded.rawRange(NSRange(location: 0, length: 1)))
    }

    func testClipboardAndReplacementExcludeAlignmentPaddingAndFoldCaptions() throws {
        let left = try buffer("通知\r\n周五"), right = try buffer("通知\r\n周六\r\n附录\r\n结语")
        let map = try TextAlignment(left.content, right.content)
        let all = map.visible(mode: .all, context: 3, hideMinor: false, revealed: [])
        let projection = TextProjection(content: left.content, side: .left, map: map, visible: all)
        let entireDisplay = NSRange(location: 0, length: projection.string.utf16.count)
        XCTAssertEqual(projection.clipboardText(in: entireDisplay), left.content.string)
        XCTAssertEqual(projection.rawRange(entireDisplay), NSRange(location: 0, length: left.content.utf16Count))
        let folded = TextProjection(content: left.content, side: .left, map: map, visible: [.fold(0..<1), .line(1)])
        let selection = NSRange(location: 0, length: folded.string.utf16.count)
        XCTAssertEqual(folded.clipboardText(in: selection), "周五")
        XCTAssertNil(folded.rawRange(selection))
    }

    func testKeyboardTerminatorsAndDirtySavepoint() throws {
        let input = try buffer("a\r\nb\r\nc\n")
        try input.replace(NSRange(location: 3, length: 1), with: "p\nq", keyboardEndings: true)
        XCTAssertEqual(input.content.string, "a\r\np\r\nq\r\nc\n")
        input.markSaved(as: .utf8BOM)
        XCTAssertFalse(input.isDirty)
        try input.undo()
        XCTAssertTrue(input.isDirty)
        try input.redo()
        XCTAssertFalse(input.isDirty)
        try input.replace(NSRange(location: 0, length: 0), with: "\u{0}")
        XCTAssertThrowsError(try input.encoded())
        XCTAssertTrue(input.isDirty)
        try input.undo()
        XCTAssertFalse(input.isDirty)
    }

    func testAlignmentGuardAndLargeSpacedEdits() throws {
        let a = try buffer((0..<50_000).map { "line-\($0)\n" }.joined())
        let b = try buffer((0..<50_000).map { $0.isMultiple(of: 500) ? "changed-\($0)\n" : "line-\($0)\n" }.joined())
        let map = try TextAlignment(a.content, b.content)
        XCTAssertEqual(map.hunks().count, 100)
        XCTAssertEqual(map.rows.count, 50_000)
        XCTAssertThrowsError(try TextAlignment(a.content, b.content, workLimit: 5)) { XCTAssertEqual($0 as? TextFailure, .alignmentLimit) }
        XCTAssertFalse(a.isDirty)
        let long = String(repeating: "q", count: 150_000)
        let single = try buffer(long)
        XCTAssertThrowsError(try TextAlignment(single.content, try buffer(long + "x").content)) { XCTAssertEqual($0 as? TextFailure, .alignmentLimit) }
        XCTAssertEqual(try single.encoded(), Data(long.utf8))
    }

    func testLineAndByteLimitsAreInclusiveAndRejectWholeTransaction() throws {
        let input = try buffer(String(repeating: "\n", count: TextBuffer.maxLines - 1))
        try input.replace(NSRange(location: 0, length: 0), with: "\n")
        XCTAssertEqual(input.content.lines.count, TextBuffer.maxLines)
        XCTAssertThrowsError(try input.replace(NSRange(location: 0, length: 0), with: "a\nb\n"))
        XCTAssertEqual(input.content.lines.count, TextBuffer.maxLines)
        try input.undo()
        XCTAssertFalse(input.isDirty)
        let huge = String(repeating: "x", count: (TextBuffer.maxBytes - 2) / 2)
        let utf16 = try buffer(huge, .utf16LE)
        XCTAssertEqual(try utf16.encoded().count, TextBuffer.maxBytes)
        try utf16.replace(NSRange(location: 0, length: 1), with: "y")
        XCTAssertThrowsError(try utf16.replace(NSRange(location: 0, length: 0), with: "xy"))
        XCTAssertEqual(try utf16.encoded().prefix(4), Data([0xff,0xfe,121,0]))
        try utf16.undo()
        XCTAssertFalse(utf16.isDirty)
        XCTAssertThrowsError(try TextKind.utf16BE.encode(huge + "x"))
    }

    func testEncodingChangeAccountsForUndoAndRedoHistory() throws {
        let fit = String(repeating: "x", count: TextBuffer.maxBytes / 2 - 1)
        let undo = try buffer(fit + "x")
        try undo.replace(NSRange(location: 0, length: 1), with: "")
        XCTAssertThrowsError(try undo.encoded(as: .utf16LE)) { XCTAssertEqual($0 as? TextFailure, .historyByteLimit) }
        XCTAssertEqual(try undo.encoded(as: .utf8BOM).count, fit.utf8.count + 3)
        let redo = try buffer(fit)
        try redo.replace(NSRange(), with: "x")
        try redo.undo()
        XCTAssertThrowsError(try redo.encoded(as: .utf16BE)) { XCTAssertEqual($0 as? TextFailure, .historyByteLimit) }
        try redo.redo()
        XCTAssertEqual(redo.content.utf16Count, fit.utf16.count + 1)
    }

    func testLiteralReplaceAllIsOneUndoAndRejectsOversizedExpansion() throws {
        let input = try buffer("Axx\r\nxX\nz")
        XCTAssertTrue(try input.replaceAll("xx", with: "1\n2", caseSensitive: false))
        XCTAssertEqual(input.content.string, "A1\r\n2\r\n1\r\n2\nz")
        try input.undo()
        XCTAssertEqual(input.content.string, "Axx\r\nxX\nz")
        XCTAssertFalse(input.isDirty)
        let many = try buffer(String(repeating: "x", count: 10_000), .utf16LE)
        XCTAssertThrowsError(try many.replaceAll("x", with: String(repeating: "a", count: 2_000), caseSensitive: true))
        XCTAssertFalse(many.isDirty)
        XCTAssertFalse(many.canUndo)
    }

    func testGoldenWorkflowChangesExactlyOneDestinationRegion() throws {
        let a = try buffer((1...300).map { $0 == 12 ? "mode=seed\n" : $0 == 284 ? "ref=base\n" : "line \($0)\n" }.joined())
        let raw = (1...300).map { $0 == 12 ? "mode=leaf\n" : $0 == 284 ? "ref=next\n" : "line \($0)\n" }.joined()
        let b = try buffer(raw)
        let map = try TextAlignment(a.content, b.content)
        XCTAssertEqual(map.hunks(), [11..<12, 283..<284])
        try b.splice(map.interval(283..<284, side: .right), from: a.content.lines[map.interval(283..<284, side: .left)])
        XCTAssertEqual(try b.encoded(), Data(raw.replacingOccurrences(of: "ref=next", with: "ref=base").utf8))
        XCTAssertEqual(try TextAlignment(a.content, b.content).hunks(), [11..<12])
    }
}

import Darwin
import Foundation
import XCTest
@testable import TandemDiffCore

final class FolderTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["TANDEMDIFF_FOLDER_TEST_ROOT"] ?? environment["DIFFNOTCH_FOLDER_TEST_ROOT"] ?? environment["MARGINDIFF_FOLDER_TEST_ROOT"]
        let volume = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        root = (volume ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        left = root.appendingPathComponent("left", isDirectory: true)
        right = root.appendingPathComponent("right", isDirectory: true)
        for dir in [left!, right!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func put(_ bytes: Data, at path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func rows(_ rules: NameRules = NameRules(), reveal: Bool = false) throws -> [FolderEntry] {
        try FolderScanner.scan(left: left, right: right, rules: rules, showExcluded: reveal)
    }

    private func row(_ path: String, in rows: [FolderEntry], file: StaticString = #filePath, line: UInt = #line) throws -> FolderEntry {
        func lookup(_ rows: [FolderEntry]) -> FolderEntry? {
            for entry in rows {
                if entry.path.utf8.elementsEqual(path.utf8) { return entry }
                if let found = lookup(entry.children) { return found }
            }
            return nil
        }
        return try XCTUnwrap(lookup(rows), path, file: file, line: line)
    }

    func testA01LastByteAndIndependentModificationTimes() throws {
        var data = Data(repeating: 65, count: 196_629)
        for dir in [left!, right!] {
            for name in ["same", "diff"] { try put(data, at: name, in: dir) }
        }
        data[data.count - 1] = 66
        try put(data, at: "diff", in: right)
        let fixed = Date(timeIntervalSince1970: 1_600_000_000)
        for file in [left.appendingPathComponent("diff"), right.appendingPathComponent("diff"), left.appendingPathComponent("same")] {
            try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
        }
        let result = try rows()
        XCTAssertEqual(try row("same", in: result).state, .identical)
        XCTAssertEqual(try row("diff", in: result).state, .different)
    }

    func testSelectedFileIsRereadWithMatchingSizeAndDateAndSiblingsKeepTheirResults() throws {
        let paths = ["src/nested/chosen", "src/nested/other", "outside"]
        let fixed = Date(timeIntervalSince1970: 1_600_000_000)
        var data = Data(repeating: 65, count: 131_073)
        for dir in [left!, right!] {
            for path in paths {
                try put(data, at: path, in: dir)
                try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: dir.appendingPathComponent(path).path)
            }
        }
        let previous = try rows()
        data[data.count - 1] = 66
        for path in paths {
            try put(data, at: path, in: right)
            try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: right.appendingPathComponent(path).path)
        }
        let ids: Set<Data> = [Data("src/nested/chosen".utf8)]
        let checked = try FolderScanner.scan(left: left, right: right, rules: NameRules(), rechecking: (ids, previous))
        for path in ["src", "src/nested", "src/nested/chosen"] {
            XCTAssertEqual(try row(path, in: checked).state, .different, path)
        }
        for path in ["src/nested/other", "outside"] {
            XCTAssertEqual(try row(path, in: checked).state, .identical, path)
            XCTAssertEqual(try row(path, in: checked).rightVersion, try row(path, in: previous).rightVersion)
        }
        try put(data, at: "src/nested/chosen", in: left)
        let equal = try FolderScanner.scan(left: left, right: right, rules: NameRules(), rechecking: (ids, checked))
        XCTAssertEqual(try row("src", in: equal).state, .identical)
        XCTAssertTrue(try row("src", in: equal).reason.isEmpty)
    }

    func testSelectedDirectoryReenumeratesDescendantsWithCurrentTypesAndRules() throws {
        for dir in [left!, right!] {
            for path in ["src/gone", "src/changed/old", "removed/file"] { try put(Data(), at: path, in: dir) }
        }
        let rules = NameRules(quickExpression: "-*.tmp")
        let previous = try rows(rules)
        for dir in [left!, right!] {
            for path in ["src/gone", "removed"] { try FileManager.default.removeItem(at: dir.appendingPathComponent(path)) }
        }
        try FileManager.default.removeItem(at: right.appendingPathComponent("src/changed"))
        try put(Data(), at: "src/changed", in: right)
        try put(Data(), at: "src/new/deep/file", in: right)
        try put(Data(), at: "src/new/deep/hidden.tmp", in: right)
        let ids = Set(["src", "src/changed/old", "removed"].map { Data($0.utf8) })
        let result = try FolderScanner.scan(left: left, right: right, rules: rules, rechecking: (ids, previous))
        XCTAssertEqual(result.map(\.path), ["src"])
        let src = try row("src", in: result)
        XCTAssertEqual(src.state, .different)
        XCTAssertEqual(src.children.map(\.path), ["src/changed", "src/new"])
        let changed = try row("src/changed", in: result)
        XCTAssertEqual(changed.state, .conflict)
        XCTAssertTrue(changed.children.isEmpty)
        XCTAssertEqual(try row("src/new/deep/file", in: result).state, .rightOnly)
        XCTAssertEqual(try row("src/new/deep/hidden.tmp", in: result).state, .excluded)
    }

    func testSelectedFileRefreshesAnAncestorWhoseDirectoryWasReplaced() throws {
        for dir in [left!, right!] {
            for path in ["src/chosen", "src/retired", "outside"] { try put(Data("one".utf8), at: path, in: dir) }
        }
        let previous = try rows()
        try FileManager.default.moveItem(at: right.appendingPathComponent("src"), to: root.appendingPathComponent("retired"))
        try put(Data("one".utf8), at: "src/chosen", in: right)
        try put(Data("one".utf8), at: "src/added", in: right)
        try put(Data("two".utf8), at: "outside", in: right)

        let ids: Set<Data> = [Data("src/chosen".utf8)]
        let result = try FolderScanner.scan(left: left, right: right, rules: NameRules(), rechecking: (ids, previous))
        XCTAssertEqual(try row("src", in: result).state, .different)
        XCTAssertEqual(try row("src/chosen", in: result).state, .identical)
        XCTAssertEqual(try row("src/retired", in: result).state, .leftOnly)
        XCTAssertEqual(try row("src/added", in: result).state, .rightOnly)
        XCTAssertEqual(try row("outside", in: result).rightVersion, try row("outside", in: previous).rightVersion)
    }

    func testSelectedFileRefreshesAnAncestorThatAppearsOnTheOtherSide() throws {
        for path in ["src/chosen", "src/sibling"] { try put(Data("one".utf8), at: path, in: left) }
        let previous = try rows()
        for path in ["src/chosen", "src/sibling"] { try put(Data("one".utf8), at: path, in: right) }

        let ids: Set<Data> = [Data("src/chosen".utf8)]
        let result = try FolderScanner.scan(left: left, right: right, rules: NameRules(), rechecking: (ids, previous))
        XCTAssertEqual(try row("src", in: result).state, .identical)
        XCTAssertEqual(try row("src/sibling", in: result).state, .identical)
    }

    func testA02OpaqueEntriesAndStrictFullLengthClassification() throws {
        let fixtures: [(String, Data, Data, FolderState)] = [
            ("wrong.ZIP", Data("x".utf8), Data("text".utf8), .notCompared),
            ("image", Data([0x89, 80, 78, 71]), Data([0x89, 80, 78, 71]), .notCompared),
            ("executable", Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xfe, 0xed, 0xfa, 0xcf]), .notCompared),
            ("unsupported", Data("hello".utf8), Data(repeating: 120, count: 70_000) + Data([0xff]), .notCompared),
            ("empty", Data(), Data(), .identical),
            ("README", Data("a".utf8), Data("b".utf8), .different),
            ("UTF16", Data([0xff, 0xfe, 0x41, 0x00]), Data([0xfe, 0xff, 0x00, 0x41]), .different),
            ("UTF32", Data([0xff, 0xfe, 0, 0]), Data([0xff, 0xfe, 0, 0]), .notCompared),
            ("opaque", Data("%PDF-1.1".utf8), Data("%PDF-1.2".utf8), .notCompared)
        ]
        for (name, a, b, _) in fixtures {
            try put(a, at: name, in: left)
            try put(b, at: name, in: right)
        }
        try put(Data("archive".utf8), at: "single.zip", in: left)
        let result = try rows()
        for (name, _, _, state) in fixtures {
            let entry = try row(name, in: result)
            XCTAssertEqual(entry.state, state, name)
            if state == .notCompared { XCTAssertFalse(entry.reason.isEmpty, name) }
        }
        let unilateral = try row("single.zip", in: result)
        XCTAssertEqual(unilateral.state, .leftOnly)
        XCTAssertNil(unilateral.leftText)
        XCTAssertFalse(unilateral.reason.isEmpty)
        let utf16 = try row("UTF16", in: result)
        XCTAssertEqual(utf16.leftText, .utf16LE)
        XCTAssertEqual(utf16.rightText, .utf16BE)
    }

    func testStrictDecoderAcrossChunkBoundariesAndMemoryParity() throws {
        let prefix = Data(repeating: 0x61, count: 65_535)
        let surrogatePrefix = Data([0xff, 0xfe]) + String(repeating: "1", count: 32_766).data(using: .utf16LittleEndian)!
        let values: [(Data, TextKind?)] = [
            (prefix + Data("😀".utf8), .utf8), (prefix + Data([0xe2, 0x81]), nil),
            (Data([0xc0, 0x80]), nil), (Data([0xed, 0xa0, 0x80]), nil), (Data([0xf4, 0x90, 0x80, 0x80]), nil),
            (Data([0xef, 0xbb, 0xbf, 13, 10, 9]), .utf8BOM), (Data(repeating: 65, count: 15) + Data([0x1f]), nil),
            (surrogatePrefix + Data([0x3d, 0xd8, 0, 0xde]), .utf16LE), (Data([0xfe, 0xff, 0xdc, 0]), nil),
            (Data([0xff, 0xfe, 65]), nil), (Data([0xff, 0xfe, 0x3d, 0xd8]), nil),
            (Data([0xfe, 0xff, 0, 0x04]), nil), (Data([0x2b, 0x2f, 0x76, 0x38]), nil)
        ]
        for (index, fixture) in values.enumerated() {
            let name = "case-\(index)"
            try put(fixture.0, at: name, in: left)
            XCTAssertEqual(TextEligibility.check(fixture.0, name: name), fixture.1, name)
            XCTAssertEqual(try TextEligibility.check(left.appendingPathComponent(name)), fixture.1, name)
        }
    }

    func testA03UnreadableParentsAndOpaqueFilesystemKinds() throws {
        try put(Data(), at: "blocked/invisible", in: left)
        try put(Data(), at: "blocked/other", in: right)
        let blocked = left.appendingPathComponent("blocked")
        let unreadable = right.appendingPathComponent("unreadable")
        try put(Data("private".utf8), at: "unreadable", in: right)
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { _ = chmod(blocked.path, 0o700); _ = chmod(unreadable.path, 0o600) }
        try put(Data(), at: "conflict", in: left)
        try put(Data(), at: "conflict/file", in: right)
        for side in [left!, right!] {
            try put(Data("hidden".utf8), at: "Container.app/Contents/secret", in: side)
            try FileManager.default.createSymbolicLink(atPath: side.appendingPathComponent("loop").path, withDestinationPath: ".")
            XCTAssertEqual(mkfifo(side.appendingPathComponent("pipe").path, 0o600), 0)
        }
        let result = try rows()
        XCTAssertEqual(try row("blocked", in: result).state, .error)
        XCTAssertTrue(try row("blocked", in: result).children.isEmpty)
        let single = try row("unreadable", in: result)
        XCTAssertEqual(single.state, .rightOnly)
        XCTAssertFalse(single.reason.isEmpty)
        XCTAssertNil(single.rightText)
        XCTAssertEqual(try row("conflict", in: result).state, .conflict)
        for name in ["loop", "pipe", "Container.app"] {
            let item = try row(name, in: result)
            XCTAssertEqual(item.state, .notCompared, name)
            XCTAssertTrue(item.children.isEmpty, name)
        }
    }

    func testA03StaleRootAndCancelledGeneration() async throws {
        for name in ["a", "b"] { try put(Data(), at: name, in: left) }
        let added = left.appendingPathComponent("after-enumeration")
        XCTAssertThrowsError(try FolderScanner.scan(left: left, right: right, rules: NameRules()) { row in
            if row.path == "a" { _ = FileManager.default.createFile(atPath: added.path, contents: Data()) }
        })
        let l = left!, r = right!
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FolderScanner.scan(left: l, right: r, rules: NameRules())
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled scan returned a final result") }
        catch is CancellationError {}
        let previous = try rows()
        XCTAssertEqual(try row("after-enumeration", in: previous).state, .leftOnly)
        let ids = Set(previous.map(\.id))
        let interrupted = Task.detached {
            try FolderScanner.scan(left: l, right: r, rules: NameRules(), rechecking: (ids, previous)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await interrupted.value; XCTFail("Interrupted recheck returned a final result") }
        catch is CancellationError {}
    }

    func testA04GlobAdmissionAndExcludedInspection() throws {
        let paths = ["agents/a.swift", "plugins/agents/b.swift", "src/App/main.swift", "src/App/general.txt", "src/App/drop.swift", "src/App/test/other.swift", "src/Other/foo.swift", "other.swift", "src/App/nested/no.swift", "src/App/nested/deeper/no.swift"]
        for path in paths { try put(Data("text".utf8), at: path, in: left) }
        var rules = NameRules()
        rules.includeDirectories = "src/App"
        rules.excludeDirectories = "agents/"
        rules.includeFiles = "**/*.swift"
        rules.excludeFiles = "drop.swift\nsrc/App/**/no.swift"
        let normal = try rows(rules)
        XCTAssertTrue(try row("agents", in: normal).children.isEmpty)
        XCTAssertEqual(try row("src/App/main.swift", in: normal).state, .leftOnly)
        XCTAssertEqual(try row("src/App/test/other.swift", in: normal).state, .leftOnly)
        let shown = try rows(rules, reveal: true)
        for path in paths where !["src/App/main.swift", "src/App/test/other.swift"].contains(path) {
            XCTAssertEqual(try row(path, in: shown).state, .excluded, path)
        }
        XCTAssertEqual(try row("plugins/agents", in: shown).state, .excluded)
        XCTAssertEqual(try row("agents/a.swift", in: shown).leftText, .utf8)
        var bare = NameRules()
        bare.excludeDirectories = "agents/"
        let pruned = try rows(bare)
        for path in ["agents", "plugins/agents"] {
            let item = try row(path, in: pruned)
            XCTAssertEqual(item.state, .excluded)
            XCTAssertTrue(item.children.isEmpty)
        }
    }

    func testFileAndFolderExclusionsOnlyMatchTheirOwnEntryType() throws {
        for path in ["build/output.txt", "src/build", "debug.log", "archive.log/keep.txt"] {
            try put(Data("text".utf8), at: path, in: left)
        }
        var rules = NameRules()
        rules.excludeFiles = "*.log"
        rules.excludeDirectories = "build"

        let result = try rows(rules)
        XCTAssertEqual(try row("debug.log", in: result).state, .excluded)
        let build = try row("build", in: result)
        XCTAssertEqual(build.state, .excluded)
        XCTAssertTrue(build.children.isEmpty)
        XCTAssertEqual(try row("src/build", in: result).state, .leftOnly)
        XCTAssertEqual(try row("archive.log/keep.txt", in: result).state, .leftOnly)
    }

    func testQuickFilterRoundTripsInspectorRulesAndLiteralPunctuation() {
        var rules = NameRules()
        rules.includeFiles = "-dates.txt\n+file\nname with spaces\nsemi;colon\npath\\name"
        rules.excludeFiles = "*.tmp"
        rules.includeDirectories = "projects/"
        rules.excludeDirectories = "agents/\narchive/"
        let edited = NameRules(quickExpression: rules.quickExpression)
        XCTAssertEqual(edited, rules)
        XCTAssertFalse(edited.admitsTextPath("projects/agents/-dates.txt"))
        XCTAssertTrue(edited.admitsTextPath("projects/-dates.txt"))
        XCTAssertTrue(edited.admitsTextPath("projects/semi;colon"))
        XCTAssertEqual(NameRules(quickExpression: ""), NameRules())
    }

    func testA05RawNamePairingAndSymlinkedAncestor() throws {
        let nfc = "caf\u{e9}", nfd = "cafe\u{301}"
        try put(Data(), at: "Case", in: left)
        try put(Data(), at: "case", in: right)
        try put(Data(), at: nfc, in: left)
        try put(Data(), at: nfd, in: right)
        let result = try rows()
        XCTAssertEqual(try row("Case", in: result).state, .leftOnly)
        XCTAssertEqual(try row("case", in: result).state, .rightOnly)
        let equivalent = FileManager.default.fileExists(atPath: right.appendingPathComponent("Case").path)
        XCTAssertEqual(try row("Case", in: result).equivalentDestinationName, equivalent ? "case" : nil)
        XCTAssertEqual(try row("case", in: result).equivalentDestinationName, equivalent ? "Case" : nil)
        let exact = result.filter { $0.path == nfc }
        // The filesystem is authoritative about spellings it can actually store.
        let a = try FileManager.default.contentsOfDirectory(atPath: left.path).first { $0 == nfc }
        let b = try FileManager.default.contentsOfDirectory(atPath: right.path).first { $0 == nfd }
        let expected = Set([Data(try XCTUnwrap(a).utf8), Data(try XCTUnwrap(b).utf8)])
        XCTAssertEqual(Set(exact.map(\.id)), expected)
        if expected.count == 2 { XCTAssertEqual(Set(exact.map(\.state)), [.leftOnly, .rightOnly]) }
        let symlink = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: left)
        XCTAssertThrowsError(try LocalAccess.validate(symlink.appendingPathComponent("Case")))
        XCTAssertThrowsError(try LocalAccess.validate(symlink.appendingPathComponent("absent")))
        XCTAssertThrowsError(try LocalAccess.validate(URL(fileURLWithPath: left.path + "/../right")))
        XCTAssertNoThrow(try LocalAccess.validate(right.appendingPathComponent("new/nested/file")))
    }

    func testA13LargeTextBeyondEditorLimitAndInvalidTail() throws {
        var payload = Data(repeating: 0x61, count: (16 << 20) + 1)
        for dir in [left!, right!] { try put(payload, at: "large", in: dir) }
        XCTAssertEqual(try row("large", in: rows()).state, .identical)
        payload[payload.count - 1] = 0xff
        try put(payload, at: "large", in: right)
        XCTAssertEqual(try row("large", in: rows()).state, .notCompared)
    }

    func testA04DeepAggregateShowsSkippedAndChangedAndDistinguishesEmptyScope() throws {
        for side in [left!, right!] {
            try put(Data("zip".utf8), at: "root/nested/archive.zip", in: side)
            try put(Data("same".utf8), at: "root/nested/file", in: side)
            try FileManager.default.createDirectory(at: side.appendingPathComponent("empty"), withIntermediateDirectories: true)
        }
        try put(Data("new".utf8), at: "root/nested/file", in: right)
        let result = try rows()
        let mixed = try row("root", in: result)
        XCTAssertEqual(mixed.state, .different)
        XCTAssertTrue(mixed.reason.contains("1 not compared"))
        XCTAssertEqual(try row("empty", in: result).state, .identical)
        var rules = NameRules()
        rules.excludeFiles = "*"
        let excluded = try row("root", in: rows(rules))
        XCTAssertEqual(excluded.state, .notCompared)
        XCTAssertTrue(excluded.reason.contains("No included items"))
    }

    func testA03FinderAliasOpaqueAndOrdinaryCloudStorageBasenameAllowed() throws {
        for side in [left!, right!] {
            try put(Data("contents".utf8), at: "CloudStorage/sample", in: side)
            try put(Data("looks like text".utf8), at: "name", in: side)
            var finder = [UInt8](repeating: 0, count: 32)
            finder[8] = 0x80
            let file = side.appendingPathComponent("name")
            XCTAssertEqual(setxattr(file.path, "com.apple.FinderInfo", &finder, finder.count, 0, 0), 0)
        }
        let results = try rows()
        XCTAssertEqual(try row("CloudStorage/sample", in: results).state, .identical)
        XCTAssertEqual(try row("name", in: results).state, .notCompared)
        XCTAssertNil(try row("name", in: results).leftText)
    }

    func testA14PrecontentPolicyRejectsProviderAndManagedAncestors() throws {
        try put(Data("local".utf8), at: "provider/owned", in: left)
        let provider = left.appendingPathComponent("provider")
        let data: UInt8 = 1
        let result = withUnsafeBytes(of: data) { setxattr(provider.path, "com.apple.fileprovider.fixture", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(result, 0)
        XCTAssertThrowsError(try LocalAccess.validate(provider.appendingPathComponent("owned")))
        XCTAssertThrowsError(try LocalAccess.validate(provider.appendingPathComponent("missing")))
        XCTAssertThrowsError(try LocalAccess.validate(URL(string: "file://remotehost/volume/file")!))
        XCTAssertThrowsError(try LocalAccess.validate(left.appendingPathComponent("Library/CloudStorage/drive/sample")))
        XCTAssertThrowsError(try TextEligibility.check(provider.appendingPathComponent("owned")))
        XCTAssertTrue(try row("provider", in: rows()).children.isEmpty)
    }
}

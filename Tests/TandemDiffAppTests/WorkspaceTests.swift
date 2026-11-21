import Foundation
import XCTest
@testable import TandemDiff
import TandemDiffCore

@MainActor
final class WorkspaceTests: XCTestCase {
    func testHomeReactivatesRecentWithoutResolvingPathsOrReplacingEdits() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("draft.txt")
        try Data("draft".utf8).write(to: file)
        let storage = base.appendingPathComponent("sessions.json")
        let library = SessionLibrary(storageURL: storage)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        let recent = SessionRecord(id: UUID(), kind: .text, left: SavedPath(file))
        library.store(recent)
        workspace.open(try XCTUnwrap(SessionLibrary(storageURL: storage).records.first))
        guard let tab = workspace.current, case .text(let editor) = tab.payload else { return XCTFail("Missing editor") }
        XCTAssertEqual(tab.id, recent.id)
        for _ in 0..<200 where !editor.editable(.left) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.edit(.left, raw: NSRange(location: 0, length: 5), replacement: "edited"))
        try FileManager.default.removeItem(at: file)
        workspace.active = nil
        workspace.open(recent)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.active, tab.id)
        guard case .text(let active)? = workspace.current?.payload else { return XCTFail("Missing reactivated editor") }
        XCTAssertEqual(active.pane(.left).buffer.content.string, "edited")
    }

    func testOpeningRecentAfterClearingFolderPathsRestoresSeparateComparison() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("left", isDirectory: true)
        let right = base.appendingPathComponent("right", isDirectory: true)
        for root in [left, right] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: base.appendingPathComponent("sessions.json")))
        workspace.makeFolders(left: left, right: right)
        let recent = try XCTUnwrap(workspace.library.records.first)
        guard case .folders(let original)? = workspace.current?.payload else { return XCTFail("Missing original folder") }
        original.clear()
        workspace.open(recent)
        guard let reopened = workspace.current, case .folders(let folder) = reopened.payload else { return XCTFail("Missing restored folder") }
        XCTAssertNotEqual(reopened.id, recent.id)
        XCTAssertEqual(reopened.title, "left <--> right")
        XCTAssertEqual(folder.left?.path, left.path)
        XCTAssertEqual(folder.right?.path, right.path)
        XCTAssertNil(original.left)
        XCTAssertNil(original.right)
        let currentRecord = try XCTUnwrap(workspace.library.records.first)
        XCTAssertEqual(currentRecord.id, reopened.id)
        workspace.open(currentRecord)
        XCTAssertEqual(workspace.tabs.count, 2)
        for tab in workspace.tabs { await workspace.close(tab.id) }
    }

    func testOpeningRecentAfterSwappingTextKeepsDirtyLiveEditorAndWriteProtection() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("left.txt"), right = base.appendingPathComponent("right.txt")
        try Data("left".utf8).write(to: left)
        try Data("right".utf8).write(to: right)
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: base.appendingPathComponent("sessions.json")))
        workspace.makeText(left: left, right: right)
        let recent = try XCTUnwrap(workspace.library.records.first)
        guard case .text(let original)? = workspace.current?.payload else { return XCTFail("Missing original editor") }
        for _ in 0..<200 where !original.editable(.left) || !original.editable(.right) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(original.edit(.left, raw: NSRange(location: 0, length: 4), replacement: "edited"))
        original.swap()
        workspace.open(recent)
        guard let tab = workspace.current, case .text(let restored) = tab.payload else { return XCTFail("Missing restored editor") }
        XCTAssertNotEqual(tab.id, recent.id)
        XCTAssertEqual(restored.leftURL?.path, left.path)
        XCTAssertEqual(restored.rightURL?.path, right.path)
        XCTAssertTrue(restored.locked(.left))
        XCTAssertTrue(restored.locked(.right))
        XCTAssertEqual(original.pane(.right).buffer.content.string, "edited")
        XCTAssertTrue(original.mayWrite(left))
    }

    func testNamedSessionsWithSamePathsOpenSeparateTabs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("draft.txt")
        try Data("draft".utf8).write(to: file)
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: base.appendingPathComponent("sessions.json")))
        let first = SessionRecord(id: UUID(), name: "Review", kind: .text, left: SavedPath(file))
        let second = SessionRecord(id: UUID(), name: "Copy", kind: .text, left: SavedPath(file))
        workspace.open(first)
        workspace.open(second)
        XCTAssertEqual(workspace.active, second.id)
        workspace.open(first)
        XCTAssertEqual(workspace.active, first.id)
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testHomeTitlesUseComparisonNamesAndIgnoreUnrelatedPathsWithTheSameBasename() {
        func path(_ value: String) -> SavedPath { SavedPath(URL(fileURLWithPath: value)) }
        let folders = SessionRecord(id: UUID(), kind: .folders, left: path("/samples/baseline"), right: path("/samples/release"))
        let readme = SessionRecord(id: UUID(), kind: .text, left: path("/alpha/src/README.md"), right: path("/beta/src/README.md"))
        let more = SessionRecord(id: UUID(), kind: .text, left: path("/alpha/tests/README.md"), right: path("/beta/unique.md"))
        let single = SessionRecord(id: UUID(), kind: .text, right: path("/beta/package.py"))
        let other = SessionRecord(id: UUID(), name: "Review", kind: .text, left: readme.left, right: readme.right)
        let titles = SessionTitles(records: [folders, readme, more, single, other])
        XCTAssertEqual(titles.title(folders), "baseline <--> release")
        XCTAssertEqual(titles.title(readme), "README.md")
        XCTAssertEqual(titles.title(more), "README.md <--> unique.md")
        XCTAssertEqual(titles.title(single), "package.py")
        XCTAssertEqual(titles.title(other), "Review")
        let sameName = SessionRecord(id: UUID(), name: "Review", kind: .text, left: more.left, right: more.right)
        let saved = SessionTitles(records: [other, sameName])
        XCTAssertEqual(saved.title(other), "Review · README.md")
        XCTAssertEqual(saved.title(sameName), "Review · README.md <--> unique.md")
    }

    func testMatchingAutomaticTitlesShowOnlyEnoughParentComponentsToDistinguishThem() {
        func comparison(_ subdirectory: String) -> SessionRecord {
            let left = URL(fileURLWithPath: "/alpha/" + subdirectory + "/src/README.md")
            let right = URL(fileURLWithPath: "/beta/" + subdirectory + "/src/README.md")
            return SessionRecord(id: UUID(), kind: .text, left: SavedPath(left), right: SavedPath(right))
        }
        let docs = comparison("docs")
        let tests = comparison("tests")
        let titles = SessionTitles(records: [docs, tests])
        XCTAssertEqual(titles.title(docs), "docs/src/README.md")
        XCTAssertEqual(titles.title(tests), "tests/src/README.md")
    }

    func testIdenticalSavedTitlesKeepTheirNumbersAcrossReorderingAndReload() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("sessions.json")
        let library = SessionLibrary(storageURL: storage)
        let left = SavedPath(base.appendingPathComponent("left")), right = SavedPath(base.appendingPathComponent("right"))
        let first = SessionRecord(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), name: "Review", kind: .folders, left: left, right: right, showExcluded: false)
        let second = SessionRecord(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")), name: "Review", kind: .folders, left: left, right: right, showExcluded: true)
        library.store(first)
        library.store(second)
        let before = SessionTitles(records: library.records)
        library.markOpened(first)
        let reloaded = SessionLibrary(storageURL: storage)
        XCTAssertEqual(reloaded.records.map(\.id), [first.id, second.id])
        for titles in [before, SessionTitles(records: reloaded.records)] {
            XCTAssertEqual(titles.title(first), "Review · left <--> right (1)")
            XCTAssertEqual(titles.title(second), "Review · left <--> right (2)")
        }
    }

    func testRecentGroupsUseLocalCalendarDaysAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 0, minute: 5)))
        XCTAssertEqual(RecentDay(now.addingTimeInterval(-60), now: now, calendar: calendar), .today)
        XCTAssertEqual(RecentDay(now.addingTimeInterval(-600), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(RecentDay(now.addingTimeInterval(-25 * 3600), now: now, calendar: calendar), .earlier)
    }

    func testCancelAtLaterTabKeepsAllUncommittedDiscards() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: storage))
        workspace.makeText()
        guard let first = workspace.current, case .text(let one) = first.payload else { return XCTFail("Missing first text tab") }
        workspace.makeText()
        guard let second = workspace.current, case .text(let two) = second.payload else { return XCTFail("Missing second text tab") }
        let range = NSRange(location: 0, length: 0)
        XCTAssertTrue(one.edit(.left, raw: range, replacement: "first"))
        XCTAssertTrue(two.edit(.right, raw: range, replacement: "second"))
        one.promptUnsaved = { _, _ in .alertSecondButtonReturn }
        two.promptUnsaved = { _, _ in .alertThirdButtonReturn }
        let rejected = await workspace.prepareWindowClose()
        XCTAssertNil(rejected)
        XCTAssertEqual(one.pane(.left).buffer.content.string, "first")
        XCTAssertEqual(two.pane(.right).buffer.content.string, "second")
        XCTAssertTrue(one.editable(.left))
        two.promptUnsaved = { _, _ in .alertSecondButtonReturn }
        let accepted = await workspace.prepareWindowClose()
        let commit = try XCTUnwrap(accepted)
        XCTAssertEqual(one.pane(.left).buffer.content.string, "first")
        await commit()
        XCTAssertFalse(one.isDirty)
        XCTAssertFalse(two.isDirty)
    }

    func testNamedFolderSnapshotRestoresRulesAndSelection() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let left = base.appendingPathComponent("left", isDirectory: true)
        let right = base.appendingPathComponent("right", isDirectory: true)
        for dir in [left, right] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("README\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("sessions.json")
        let library = SessionLibrary(storageURL: storage)
        var rules = NameRules()
        rules.excludeDirectories = "agents/"
        let readme = Data("README.md".utf8)
        let record = SessionRecord(id: UUID(), name: "Example", kind: .folders, left: SavedPath(left), right: SavedPath(right), rules: rules, folderFilter: FolderFilter.all.rawValue, showExcluded: false, expansion: [], selection: [readme], folderWriteProtected: true)
        library.store(record)
        let reader = SessionLibrary(storageURL: storage)
        let workspace = Workspace(registry: EditRegistry(), library: reader)
        workspace.open(try XCTUnwrap(reader.records.first))
        guard let tab = workspace.current, case .folders(let folder) = tab.payload else { return XCTFail("Missing restored folder session") }
        for _ in 0..<80 where !folder.complete { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(folder.complete)
        XCTAssertEqual(folder.rules, rules)
        XCTAssertEqual(folder.selection, [readme])
        XCTAssertTrue(folder.writeProtected)
        XCTAssertEqual(folder.rows.first?.entry.state, .identical)
        await workspace.close(tab.id)
    }
    func testRestoredInspectionDoesNotReserveWritableBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        try Data("text".utf8).write(to: file)
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: root.appendingPathComponent("library.json")))
        let saved = SessionRecord(id: UUID(), name: "Inspection", kind: .text, left: SavedPath(file), inheritedTextProtection: true)
        workspace.open(saved)
        guard let inspection = workspace.current, case .text(let reader) = inspection.payload else { return XCTFail("Missing restored inspection") }
        XCTAssertTrue(reader.locked(.left))
        XCTAssertFalse(reader.hasWritableBinding(file))
        workspace.makeText(left: file)
        guard let current = workspace.current, case .text(let writer) = current.payload else { return XCTFail("Missing text editor") }
        XCTAssertFalse(writer.locked(.left))
        XCTAssertTrue(writer.mayWrite(file))
    }

}

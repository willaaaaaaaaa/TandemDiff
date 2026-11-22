import AppKit
import SwiftUI
import XCTest
@testable import TandemDiff
import TandemDiffCore

@MainActor
final class FolderSessionTests: XCTestCase {
    private func fixture(_ body: (URL, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        for dir in [left, right] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, left, right)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<60 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected application state was not reached")
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testExternalWriteReplacesFolderVerdict() async throws {
        try await fixture { _, left, right in
            for dir in [left, right] { try Data("one".utf8).write(to: dir.appendingPathComponent("old")) }
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            XCTAssertEqual(session.entries.first?.state, .identical)
            try Data("two".utf8).write(to: right.appendingPathComponent("old"))
            try await waitUntil { session.complete && session.entries.first?.state == .different }
            XCTAssertEqual(session.entries.first?.state, .different)
        }
    }

    func testCompareContentsOfCollapsedSelectionPreservesViewAndUsesCurrentSelection() async throws {
        try await fixture { _, left, right in
            for dir in [left, right] {
                try write("one", to: "selected/nested/file", in: dir)
                try write("one", to: "other", in: dir)
            }
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            let selected = Data("selected".utf8)
            session.selection = [selected]
            try write("two", to: "selected/nested/file", in: right)
            session.compareContents(ids: session.selection)
            XCTAssertTrue(session.scanning)
            let other = Data("other".utf8)
            session.selection = [other]
            try await waitUntil { session.complete }
            XCTAssertEqual(session.allEntries.first { $0.path == "selected/nested/file" }?.state, .different)
            XCTAssertEqual(session.entries.first { $0.id == selected }?.state, .different)
            XCTAssertEqual(session.selection, [other])
            XCTAssertTrue(session.expanded.isEmpty)
            session.compareContents(ids: [selected])
            session.stop()
            await session.close()
            await Task.yield()
            XCTAssertFalse(session.complete)
            XCTAssertFalse(session.scanning)
        }
    }

    func testRootReplacementRequiresNewSelection() async throws {
        try await fixture { root, left, right in
            try Data("one".utf8).write(to: left.appendingPathComponent("old"))
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            XCTAssertEqual(session.entries.first?.path, "old")
            let detached = root.appendingPathComponent("detached", isDirectory: true)
            try FileManager.default.moveItem(at: left, to: detached)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: left.appendingPathComponent("new"))
            session.refresh()
            try await waitUntil { !session.scanning }
            XCTAssertFalse(session.complete, "the substitute directory must await explicit selection")
            XCTAssertNotEqual(session.entries.first?.path, "new")
        }
    }

    func testCopyReservationRejectsDirectTypingInExistingEditor() async throws {
        try await fixture { _, left, _ in
            let source = left.appendingPathComponent("text")
            try Data("one".utf8).write(to: source)
            let registry = EditRegistry()
            let editor = TextSessionModel(left: source, right: nil, writer: registry.writer)
            registry.register(editor, id: UUID()) { true }
            try await waitUntil { !editor.pane(.left).busy && editor.pane(.left).baseline != nil }
            XCTAssertTrue(editor.editable(.left))
            registry.copyStarted([source])
            XCTAssertFalse(editor.edit(.left, raw: NSRange(location: 0, length: 0), replacement: "!"))
            registry.copyFinished([source])
            XCTAssertTrue(editor.edit(.left, raw: NSRange(location: 0, length: 0), replacement: "!"))
        }
    }
    func testOpeningSelectedChecksRootBeforeWatchEvent() async throws {
        try await fixture { root, left, right in
            for folder in [left, right] { try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt")) }
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            session.selection = [Data("one.txt".utf8)]
            let detached = root.appendingPathComponent("before", isDirectory: true)
            try FileManager.default.moveItem(at: left, to: detached)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: left.appendingPathComponent("one.txt"))
            var didOpen = false
            session.onOpen = { _ in didOpen = true }
            session.openSelected()
            XCTAssertFalse(didOpen)
            XCTAssertFalse(session.complete)
        }
    }

    func testVirtualPaneCannotWriteIntoSubstitutedRootEvenAfterParentClose() async throws {
        try await fixture { root, left, right in
            let target = right.appendingPathComponent("new.txt")
            let source = left.appendingPathComponent("new.txt")
            try Data("text".utf8).write(to: source)
            let registry = EditRegistry()
            let library = SessionLibrary(storageURL: root.appendingPathComponent("sessions.json"))
            let workspace = Workspace(registry: registry, library: library)
            workspace.makeFolders(left: left, right: right)
            let parent = try XCTUnwrap(workspace.current)
            guard case .folders(let folder) = parent.payload else { return XCTFail("Expected folder session") }
            try await waitUntil { folder.complete }
            folder.selection = [Data("new.txt".utf8)]
            folder.openSelected()
            let child = try XCTUnwrap(workspace.current)
            guard case .text(let editor) = child.payload else { return XCTFail("Expected text session") }
            try await waitUntil { editor.pane(.left).baseline != nil }
            XCTAssertTrue(editor.mayWrite(target))
            XCTAssertTrue(editor.edit(.right, raw: NSRange(location: 0, length: 0), replacement: "draft"))
            await workspace.close(parent.id)
            try FileManager.default.moveItem(at: right, to: root.appendingPathComponent("former", isDirectory: true))
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            XCTAssertFalse(editor.mayWrite(target))
            let saved = await editor.save(.right)
            XCTAssertFalse(saved)
            XCTAssertTrue(editor.pane(.right).buffer.isDirty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testNewExclusionProtectsExistingAndInspectionChild() async throws {
        try await fixture { root, left, right in
            let target = right.appendingPathComponent("two.txt")
            for folder in [left, right] { try Data("text".utf8).write(to: folder.appendingPathComponent("two.txt")) }
            let registry = EditRegistry()
            let workspace = Workspace(registry: registry, library: SessionLibrary(storageURL: root.appendingPathComponent("sessions.json")))
            workspace.makeFolders(left: left, right: right)
            let parent = try XCTUnwrap(workspace.current)
            guard case .folders(let folder) = parent.payload else { return XCTFail("Expected folder session") }
            try await waitUntil { folder.complete }
            folder.selection = [Data("two.txt".utf8)]
            folder.openSelected()
            let child = try XCTUnwrap(workspace.current)
            guard case .text(let editor) = child.payload else { return XCTFail("Expected text session") }
            XCTAssertTrue(editor.mayWrite(target))
            folder.rules.excludeFiles = "two.txt"
            folder.showExcluded = true
            folder.refresh()
            try await waitUntil { folder.complete }
            XCTAssertFalse(editor.mayWrite(target))
            folder.selection = [Data("two.txt".utf8)]
            folder.openSelected()
            let inspection = try XCTUnwrap(workspace.current)
            guard case .text(let readOnly) = inspection.payload else { return XCTFail("Expected inspection session") }
            XCTAssertNotEqual(child.id, inspection.id)
            XCTAssertTrue(readOnly.locked(.right))
            XCTAssertFalse(readOnly.mayWrite(target))
        }
    }

    func testPriorInspectionDoesNotOwnTheWritableBindingWhenRuleIsRemoved() async throws {
        try await fixture { root, left, right in
            let filename = "hidden.txt"
            let id = Data(filename.utf8)
            let target = right.appendingPathComponent(filename)
            for folder in [left, right] { try Data("text".utf8).write(to: folder.appendingPathComponent(filename)) }
            let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: root.appendingPathComponent("sessions.json")))
            workspace.makeFolders(left: left, right: right)
            let parent = try XCTUnwrap(workspace.current)
            guard case .folders(let folder) = parent.payload else { return XCTFail("Expected folder session") }
            folder.rules.excludeFiles = filename
            folder.showExcluded = true
            folder.refresh()
            try await waitUntil { folder.complete }
            folder.selection = [id]
            folder.openSelected()
            guard let inspecting = workspace.current, case .text(let inspection) = inspecting.payload else { return XCTFail("Expected inspection tab") }
            XCTAssertTrue(inspection.locked(.right))
            XCTAssertFalse(inspection.hasWritableBinding(target))
            folder.rules = NameRules()
            folder.refresh()
            try await waitUntil { folder.complete }
            folder.selection = [id]
            folder.openSelected()
            guard let open = workspace.current, case .text(let editor) = open.payload else { return XCTFail("Expected editor tab") }
            XCTAssertNotEqual(open.id, inspecting.id)
            XCTAssertFalse(editor.locked(.right))
            XCTAssertTrue(editor.mayWrite(target))
        }
    }

    func testFolderExpansionAndTemporaryInspectionPreserveCopyScope() async throws {
        try await fixture { _, left, right in
            for path in ["src/live.txt", "src/agents/secret.txt", "other/nested/file.txt"] {
                let file = left.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("content".utf8).write(to: file)
            }
            let folder = FolderSession(left: left, right: right, registry: EditRegistry(), observesFileChanges: false)
            folder.applyRules(NameRules(quickExpression: "-agents/"))
            try await waitUntil { folder.complete }
            let src = Data("src".utf8)
            folder.selection = [src]
            folder.setDirectoriesExpanded(true, all: false)
            XCTAssertEqual(Set(folder.rows.map(\.entry.path)), ["other", "src", "src/live.txt"])

            folder.filter = .leftOnly
            folder.inspectExcluded(true)
            try await waitUntil { folder.complete }
            folder.setDirectoriesExpanded(true, all: false)
            XCTAssertEqual(Set(folder.rows.map(\.entry.path)), ["other", "src", "src/live.txt", "src/agents", "src/agents/secret.txt"])
            folder.prepare(.right)
            try await waitUntil { folder.showPreview }
            XCTAssertEqual(folder.preview.filter(\.action.executable).map(\.path), ["src/live.txt"])
            XCTAssertEqual(folder.preview.first { $0.path == "src/agents/secret.txt" }?.action, .skip)

            folder.inspectExcluded(false)
            try await waitUntil { folder.complete }
            XCTAssertFalse(folder.showPreview)
            XCTAssertEqual(folder.filter, .leftOnly)
            XCTAssertEqual(folder.rules.excludeDirectories, "agents/")
            XCTAssertFalse(folder.canPreview(ids: [Data("src/agents/secret.txt".utf8)]))

            folder.setDirectoriesExpanded(true, all: true)
            XCTAssertTrue(folder.rows.contains { $0.entry.path == "other/nested/file.txt" })
            folder.setDirectoriesExpanded(false, all: false)
            XCTAssertFalse(folder.rows.contains { $0.entry.path == "src/live.txt" })
            XCTAssertTrue(folder.rows.contains { $0.entry.path == "other/nested/file.txt" })
            folder.setDirectoriesExpanded(false, all: true)
            XCTAssertEqual(Set(folder.rows.map(\.entry.path)), ["src", "other"])
            await folder.close()
        }
    }

    func testFolderStructuresFilterDirectoriesAndKeepRelativePathPairs() async throws {
        try await fixture { _, left, right in
            for root in [left, right] {
                try write("same", to: "docs/index.txt", in: root)
                try write(root.lastPathComponent, to: "src/index.txt", in: root)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
            }
            try write("hidden", to: "cache/nested/index.txt", in: left)
            let folder = FolderSession(left: left, right: right, registry: EditRegistry(), observesFileChanges: false)
            folder.applyRules(NameRules(quickExpression: "-cache/"))
            try await waitUntil { folder.complete }
            folder.toggle(Data("docs".utf8))
            folder.filter = .identical
            XCTAssertEqual(folder.rows.map(\.entry.path), ["docs", "docs/index.txt", "empty"])

            folder.structure = .filesOnly
            XCTAssertEqual(folder.rows.map(\.entry.path), ["docs", "docs/index.txt"])
            folder.structure = .alwaysShowFolders
            XCTAssertEqual(folder.rows.map(\.entry.path), ["docs", "docs/index.txt", "empty", "src"])
            folder.filter = .all
            let srcFile = Data("src/index.txt".utf8)
            XCTAssertEqual(folder.projectedRows(expandAll: true).map(\.entry.path), ["docs", "docs/index.txt", "empty", "src", "src/index.txt"])
            folder.structure = .flatList
            XCTAssertEqual(folder.rows.map(\.entry.path), ["docs/index.txt", "src/index.txt"])
            XCTAssertEqual(folder.rows.map(\.level), [0, 0])
            let row = try XCTUnwrap(folder.rows.first { $0.id == srcFile })
            XCTAssertEqual(row.entry.state, .different)
            XCTAssertEqual(row.entry.left, left.appendingPathComponent("src/index.txt"))
            XCTAssertEqual(row.entry.right, right.appendingPathComponent("src/index.txt"))
            folder.selection = [srcFile]
            folder.prepare(.right)
            try await waitUntil { folder.showPreview }
            XCTAssertEqual(folder.preview.map(\.path), ["src/index.txt"])
            XCTAssertEqual(folder.preview.first?.action, .replace)
            folder.setDirectoriesExpanded(true, all: true)
            folder.structure = .compareFolders
            XCTAssertFalse(folder.showPreview)
            XCTAssertTrue(folder.selection.isEmpty)
            XCTAssertEqual(folder.rows.map(\.entry.path), ["docs", "docs/index.txt", "empty", "src"])
            await folder.close()
        }
    }

    func testSavedRelativePathListRestoresSelectionAndTreeExpansion() async throws {
        try await fixture { root, left, right in
            try write("one", to: "docs/index.txt", in: left)
            try write("two", to: "src/index.txt", in: left)
            let url = root.appendingPathComponent("sessions.json")
            let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: url))
            workspace.open(SessionRecord(id: UUID(), kind: .folders, left: SavedPath(left), right: SavedPath(right)))
            guard let tab = workspace.current, case .folders(let folder) = tab.payload else { return XCTFail("Expected folder session") }
            try await waitUntil { folder.complete }
            XCTAssertEqual(folder.structure, .compareFolders)
            folder.toggle(Data("docs".utf8))
            folder.structure = .flatList
            folder.selection = [Data("src/index.txt".utf8)]
            folder.selectionScope = .right
            workspace.saveSession(asNew: true) { _ in "Flat" }
            await workspace.close(tab.id)

            let library = SessionLibrary(storageURL: url)
            let saved = try XCTUnwrap(library.records.first { $0.name == "Flat" })
            let reopened = Workspace(registry: EditRegistry(), library: library)
            reopened.open(saved)
            guard let restoredTab = reopened.current, case .folders(let restored) = restoredTab.payload else { return XCTFail("Expected restored session") }
            try await waitUntil { restored.complete }
            XCTAssertEqual(restored.structure, .flatList)
            XCTAssertEqual(restored.selection, [Data("src/index.txt".utf8)])
            XCTAssertEqual(restored.selectionScope, .right)
            restored.structure = .compareFolders
            XCTAssertEqual(restored.rows.map(\.entry.path), ["docs", "docs/index.txt", "src"])
            XCTAssertTrue(restored.selection.isEmpty)
            await reopened.close(restoredTab.id)
        }
    }

    func testSelectionCommandsUseVisibleRowsAndKeepExcludedFilesOutOfCopy() async throws {
        try await fixture { _, left, right in
            try write("copy", to: "src/live.txt", in: left)
            try write("secret", to: "src/private/key.txt", in: left)
            try write("other", to: "other/inner.txt", in: right)
            let folder = FolderSession(left: left, right: right, registry: EditRegistry(), observesFileChanges: false)
            folder.applyRules(NameRules(quickExpression: "-private/"))
            try await waitUntil { folder.complete }
            let src = Data("src".utf8)
            let live = Data("src/live.txt".utf8)
            let secret = Data("src/private/key.txt".utf8)
            folder.toggle(src)
            folder.selectVisibleFiles()
            XCTAssertEqual(folder.selection, [live])
            folder.invertVisibleSelection()
            XCTAssertEqual(folder.selection, [src, Data("other".utf8)])

            folder.structure = .flatList
            XCTAssertTrue(folder.selection.isEmpty)
            folder.filter = .leftOnly
            folder.inspectExcluded(true)
            try await waitUntil { folder.complete }
            folder.selectVisibleFiles()
            XCTAssertEqual(folder.selection, [live, secret])
            folder.prepare(.right)
            try await waitUntil { folder.showPreview }
            XCTAssertEqual(folder.preview.filter(\.action.executable).map(\.path), ["src/live.txt"])
            XCTAssertEqual(folder.preview.first { $0.id == secret }?.action, .skip)
            folder.inspectExcluded(false)
            try await waitUntil { folder.complete }
            XCTAssertEqual(folder.selection, [live])
            XCTAssertFalse(folder.showPreview)
            folder.filter = .rightOnly
            XCTAssertTrue(folder.selection.isEmpty)
            folder.invertVisibleSelection()
            XCTAssertEqual(folder.selection, [Data("other/inner.txt".utf8)])
            await folder.close()
        }
    }

    func testSortingUsesTheChosenSideAndKeepsTreeRowsTogether() async throws {
        try await fixture { _, left, right in
            for root in [left, right] {
                let onLeft = root == left
                try write(onLeft ? "long" : "x", to: "a", in: root)
                try write(onLeft ? "x" : "long", to: "b", in: root)
                for path in ["nested/file2", "nested/file10"] {
                    try write("xx", to: path, in: root)
                }
                for (name, time) in [("a", onLeft ? 200.0 : 100.0), ("b", onLeft ? 100.0 : 200.0)] {
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: root.appendingPathComponent(name).path)
                }
            }
            try write("side", to: "right-only", in: right)
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            XCTAssertEqual(folder.rows.map(\.entry.path), ["a", "b", "nested", "right-only"])
            folder.selection = [Data("a".utf8)]
            folder.toggle(Data("nested".utf8))
            folder.sortOrder = [FolderRowSort(column: .leftSize)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["nested", "nested/file10", "nested/file2", "b", "a", "right-only"])
            folder.sortOrder = [FolderRowSort(column: .rightName, order: .reverse)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["nested", "nested/file10", "nested/file2", "right-only", "b", "a"])
            folder.sortOrder = [FolderRowSort(column: .leftName)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["nested", "nested/file2", "nested/file10", "a", "b", "right-only"])
            folder.toggle(Data("nested".utf8))
            folder.sortOrder = [FolderRowSort(column: .leftModified)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["nested", "b", "a", "right-only"])
            folder.sortOrder = [FolderRowSort(column: .rightModified)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["nested", "a", "b", "right-only"])
            folder.structure = .flatList
            folder.sortOrder = [FolderRowSort(column: .rightSize)]
            XCTAssertEqual(folder.rows.map(\.entry.path), ["a", "nested/file10", "nested/file2", "b", "right-only"])
            XCTAssertEqual(folder.selection, [Data("a".utf8)])
            await folder.close()
        }
    }

    func testDifferenceNavigationStartsAtSelectedEqualRowAndWraps() async throws {
        try await fixture { _, left, right in
            for name in ["a", "b", "c", "d", "e"] {
                try write("left", to: name, in: left)
                try write(["b", "d"].contains(name) ? "left" : "right", to: name, in: right)
            }
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            folder.selection = [Data("b".utf8)]
            folder.nextDifference(backward: false)
            XCTAssertEqual(folder.selection, [Data("c".utf8)])
            folder.selection = [Data("d".utf8)]
            folder.nextDifference(backward: true)
            XCTAssertEqual(folder.selection, [Data("c".utf8)])
            folder.selection = [Data("a".utf8)]
            folder.nextDifference(backward: true)
            XCTAssertEqual(folder.selection, [Data("e".utf8)])
            folder.nextDifference(backward: false)
            XCTAssertEqual(folder.selection, [Data("a".utf8)])
            await folder.close()
        }
    }

    func testSingleSidedBaseFoldersKeepIndependentHistoryAndRejectReplacements() async throws {
        try await fixture { _, left, right in
            try write("source", to: "baseline/common", in: left)
            try write("target", to: "release/common", in: right)
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            let baseline = try XCTUnwrap(session.entries.first { $0.path == "baseline" })
            XCTAssertFalse(baseline.canBeBaseFolder(on: .right))
            session.useAsRoots(baseline, side: .left)
            XCTAssertEqual(session.left, baseline.left)
            XCTAssertEqual(session.right, right)
            try await waitUntil { session.complete }
            let release = try XCTUnwrap(session.entries.first { $0.path == "release" })
            session.useAsRoots(release, side: .right)
            XCTAssertEqual(session.left, baseline.left)
            XCTAssertEqual(session.right, release.right)
            try await waitUntil { session.complete }
            XCTAssertEqual(session.rows.map(\.entry.path), ["common"])
            session.visitLocation(backward: true)
            XCTAssertEqual(session.right, right)
            XCTAssertEqual(session.left, baseline.left)
            try await waitUntil { session.complete }
            let original = try XCTUnwrap(release.right)
            try FileManager.default.moveItem(at: original, to: right.appendingPathComponent("old"))
            try write("replacement", to: "release/common", in: right)
            session.useAsRoots(release, side: .right)
            XCTAssertEqual(session.right, right)
            XCTAssertEqual(session.left, baseline.left)
            await session.close()
        }
    }

    func testNativeTableMenusFollowColumnsPreserveMultiselectionAndScopeSelectAll() async throws {
        _ = NSApplication.shared
        try await fixture { temp, left, right in
            try write("source", to: "baseline/a", in: left)
            try write("target", to: "release/a", in: right)
            try write("only left", to: "one.txt", in: left)
            try write("only right", to: "two.txt", in: right)
            for root in [left, right] { try write("shared", to: "both/a", in: root) }
            let registry = EditRegistry()
            let session = FolderSession(left: left, right: right, registry: registry)
            session.refresh()
            try await waitUntil { session.complete }
            let workspace = Workspace(registry: registry, library: SessionLibrary(storageURL: temp.appendingPathComponent("sessions.json")))
            let host = NSHostingView(rootView: FolderView(session: session, workspace: workspace))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            @MainActor func descendant<T: NSView>(_ view: NSView, of type: T.Type) -> T? {
                if let found = view as? T { return found }
                return view.subviews.lazy.compactMap { descendant($0, of: type) }.first
            }
            let table = try XCTUnwrap(descendant(host, of: NSTableView.self))
            let anchor = try XCTUnwrap(descendant(host, of: FolderTableInput.Anchor.self))
            XCTAssertFalse(table.allowsColumnReordering)
            table.tableColumns[0].width = 260
            table.layoutSubtreeIfNeeded()
            @MainActor func menu(_ path: String, column: Int) throws -> NSMenu {
                let row = try XCTUnwrap(session.rows.firstIndex { $0.entry.path == path })
                let cell = table.frameOfCell(atColumn: column, row: row)
                let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                return try XCTUnwrap(anchor.pointerMenu(for: event)?.1)
            }
            let base = L("Set as Base Folder", "设为基点文件夹")
            XCTAssertNil(try menu("baseline", column: 6).item(withTitle: base))
            XCTAssertNotNil(try menu("baseline", column: 1).item(withTitle: base))
            XCTAssertNil(try menu("release", column: 2).item(withTitle: base))
            XCTAssertNotNil(try menu("release", column: 4).item(withTitle: base))

            table.selectAll(nil)
            var compared: Set<Data>?
            anchor.input = FolderTableInput(session: session) { compared = $0 }
            let multi = try menu("baseline", column: 0)
            XCTAssertEqual(session.selection, Set(session.rows.map(\.id)))
            XCTAssertNil(multi.item(withTitle: base))
            let compare = try XCTUnwrap(multi.item(withTitle: L("Compare Contents", "比较内容")))
            multi.performActionForItem(at: multi.index(of: compare))
            XCTAssertEqual(compared, session.selection)
            let expand = try XCTUnwrap(multi.item(withTitle: L("Expand Subtrees", "展开子目录树")))
            multi.performActionForItem(at: multi.index(of: expand))
            XCTAssertTrue(session.rows.contains { $0.entry.path == "release/a" })
            let collapse = try XCTUnwrap(multi.item(withTitle: L("Collapse Subtrees", "收起子目录树")))
            multi.performActionForItem(at: multi.index(of: collapse))
            XCTAssertFalse(session.rows.contains { $0.entry.path == "release/a" })
            XCTAssertEqual(multi.items.map(\.title), [compare.title, expand.title, collapse.title])
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            let partial = try menu(session.rows[0].entry.path, column: 0)
            XCTAssertNotNil(partial.item(withTitle: L("Copy Paths", "复制路径")))
            XCTAssertNotNil(partial.item(withTitle: L("Reveal in Finder", "在访达中显示")))
            XCTAssertNotNil(partial.item(withTitle: CopyDirection.right.label))
            for modifiers: NSEvent.ModifierFlags in [.control, .command] {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
                XCTAssertFalse(anchor.handleSelectionKey(key, responder: window.fieldEditor(true, for: nil)))
                XCTAssertEqual(table.numberOfSelectedRows, 1)
                XCTAssertTrue(anchor.handleSelectionKey(key, responder: table))
                XCTAssertEqual(table.numberOfSelectedRows, 5)
                XCTAssertEqual(session.selection, Set(session.rows.map(\.id)))
            }
            table.deselectAll(nil)
            let source = try menu("baseline", column: 0)
            let choose = try XCTUnwrap(source.item(withTitle: base))
            source.performActionForItem(at: source.index(of: choose))
            XCTAssertEqual(session.left?.lastPathComponent, "baseline")
            XCTAssertEqual(session.right, right)
            await session.close()
        }
    }

    func testCommandClickComparesSelectedTextAndSetsSelectedFolderPair() async throws {
        _ = NSApplication.shared
        try await fixture { temp, left, right in
            let leftText = left.appendingPathComponent("poteto-agent.md")
            let rightText = right.appendingPathComponent("my-agent.md")
            try write("left file", to: leftText.lastPathComponent, in: left)
            try write("right file", to: rightText.lastPathComponent, in: right)
            try write("left decoy", to: rightText.lastPathComponent, in: left)
            try write("right decoy", to: leftText.lastPathComponent, in: right)
            try write("before", to: "baseline/common.txt", in: left)
            try write("after", to: "release/common.txt", in: right)

            let library = SessionLibrary(storageURL: temp.appendingPathComponent("sessions.json"))
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "TandemDiffTest.\(UUID())"))
            let workspace = Workspace(registry: EditRegistry(), library: library, sessionDefaults: SessionDefaults(store: defaults))
            workspace.makeFolders(left: left, right: right)
            let parent = try XCTUnwrap(workspace.current)
            guard case .folders(let session) = parent.payload else { return XCTFail("Expected Folder Compare") }
            try await waitUntil { session.complete }
            let host = NSHostingView(rootView: FolderView(session: session, workspace: workspace))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            @MainActor func descendant<T: NSView>(_ view: NSView, of type: T.Type) -> T? {
                if let found = view as? T { return found }
                return view.subviews.lazy.compactMap { descendant($0, of: type) }.first
            }
            let table = try XCTUnwrap(descendant(host, of: NSTableView.self))
            let anchor = try XCTUnwrap(descendant(host, of: FolderTableInput.Anchor.self))
            table.tableColumns[0].width = 260
            table.layoutSubtreeIfNeeded()

            @MainActor func event(_ type: NSEvent.EventType, _ path: String, _ column: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                let row = try XCTUnwrap(session.rows.firstIndex { $0.entry.path == path })
                let cell = table.frameOfCell(atColumn: column, row: row)
                let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            @MainActor func menu(_ path: String, _ column: Int) throws -> NSMenu {
                try XCTUnwrap(anchor.pointerMenu(for: event(.rightMouseDown, path, column))?.1)
            }
            @MainActor func select(_ path: String, _ column: Int) throws {
                let click = try event(.leftMouseDown, path, column)
                if !anchor.handle(click) {
                    let row = try XCTUnwrap(session.rows.firstIndex { $0.entry.path == path })
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                _ = try menu(path, column)
            }
            @MainActor func extendSelection(_ path: String, _ column: Int) throws {
                XCTAssertTrue(try anchor.handle(event(.leftMouseDown, path, column, modifiers: .command)))
            }
            @MainActor func perform(_ title: String, in menu: NSMenu) throws {
                let item = try XCTUnwrap(menu.item(withTitle: title))
                XCTAssertTrue(item.isEnabled)
                menu.performActionForItem(at: menu.index(of: item))
            }

            let compare = L("Compare Selected Files", "比较所选文件")
            let roots = L("Set as Base Folders on Both Sides", "将两侧目录设为基点文件夹")
            let leftName = leftText.lastPathComponent
            let rightName = rightText.lastPathComponent
            for (first, firstColumn, second, secondColumn) in [(leftName, 0, rightName, 4), (rightName, 4, leftName, 0)] {
                try select(first, firstColumn)
                try extendSelection(second, secondColumn)
                try perform(compare, in: menu(second, secondColumn))
                let child = try XCTUnwrap(workspace.current)
                guard case .text(let editor) = child.payload else { return XCTFail("Expected one Text Compare tab") }
                XCTAssertEqual(workspace.tabs.count, 2)
                XCTAssertEqual(child.parent, parent.id)
                XCTAssertEqual(editor.leftURL, leftText)
                XCTAssertEqual(editor.rightURL, rightText)
                try await waitUntil { TextSide.allCases.allSatisfy { !editor.pane($0).busy } }
                XCTAssertEqual(editor.pane(.left).buffer.content.string, "left file")
                XCTAssertEqual(editor.pane(.right).buffer.content.string, "right file")
                await workspace.close(child.id)
                XCTAssertEqual(workspace.active, parent.id)
                XCTAssertNotNil(try menu(first, firstColumn).item(withTitle: compare))
            }

            try select(leftName, 0)
            try extendSelection("release", 4)
            let mixed = try menu("release", 4)
            XCTAssertNil(mixed.item(withTitle: compare))
            XCTAssertNil(mixed.item(withTitle: roots))

            try select("release", 4)
            try extendSelection("baseline", 0)
            try perform(roots, in: menu("baseline", 0))
            XCTAssertEqual(session.left?.path, left.appendingPathComponent("baseline").path)
            XCTAssertEqual(session.right?.path, right.appendingPathComponent("release").path)
            try await waitUntil { session.complete }
            XCTAssertEqual(session.rows.map(\.entry.path), ["common.txt"])
            session.visitLocation(backward: true)
            XCTAssertEqual(session.left, left)
            XCTAssertEqual(session.right, right)
            await workspace.close(parent.id)
        }
    }

    func testCopyPreviewUsesOnlySelectedSourcesInItsDirection() async throws {
        try await fixture { _, left, right in
            try write("chosen left", to: "left.md", in: left)
            try write("unselected left", to: "right.md", in: left)
            try write("chosen right", to: "right.md", in: right)
            try write("unselected right", to: "left.md", in: right)
            let session = FolderSession(left: left, right: right, registry: EditRegistry(), observesFileChanges: false)
            session.refresh()
            try await waitUntil { session.complete }
            let leftFile = try XCTUnwrap(session.entries.first { $0.path == "left.md" })
            let rightFile = try XCTUnwrap(session.entries.first { $0.path == "right.md" })
            session.toggleSelectedSide(.left, of: leftFile, extending: [])
            session.toggleSelectedSide(.right, of: rightFile, extending: [leftFile.id])
            for (direction, source, destination) in [(CopyDirection.right, leftFile.left, leftFile.right), (.left, rightFile.right, rightFile.left)] {
                let menu = FolderContextMenu(session: session, ids: session.selection, side: nil, compare: { _ in }).nativeMenu()
                let item = try XCTUnwrap(menu.item(withTitle: direction.label))
                XCTAssertTrue(item.isEnabled)
                menu.performActionForItem(at: menu.index(of: item))
                try await waitUntil { session.showPreview }
                let planned = session.preview.filter(\.action.executable)
                XCTAssertEqual(planned.map(\.source), [source])
                XCTAssertEqual(planned.map(\.destination), [try XCTUnwrap(destination)])
                session.invalidatePreview()
            }
            await session.close()
        }
    }

    func testReturningFromSelectedTextPairRestoresFolderViewport() async throws {
        _ = NSApplication.shared
        try await fixture { temp, left, right in
            try write("left", to: "z-left.md", in: left)
            try write("right", to: "z-right.md", in: right)
            for index in 0..<50 { try write("filler", to: "row-\(index).txt", in: left) }
            let library = SessionLibrary(storageURL: temp.appendingPathComponent("sessions.json"))
            let workspace = Workspace(registry: EditRegistry(), library: library)
            workspace.makeFolders(left: left, right: right)
            guard case .folders(let session)? = workspace.current?.payload else { return XCTFail("Expected Folder Compare") }
            try await waitUntil { session.complete }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            @MainActor func nativeTable(in view: NSView) -> NSTableView? {
                (view as? NSTableView) ?? view.subviews.lazy.compactMap { nativeTable(in: $0) }.first
            }
            @MainActor func showFolder() throws -> NSTableView {
                let host = NSHostingView(rootView: FolderView(session: session, workspace: workspace))
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                return try XCTUnwrap(nativeTable(in: host))
            }
            let originalTable = try showFolder()
            try await waitUntil { session.readTableScrollOrigin?() != nil }
            let leftFile = try XCTUnwrap(session.entries.first { $0.path == "z-left.md" })
            let rightFile = try XCTUnwrap(session.entries.first { $0.path == "z-right.md" })
            session.toggleSelectedSide(.left, of: leftFile, extending: [])
            session.toggleSelectedSide(.right, of: rightFile, extending: [leftFile.id])
            originalTable.scrollRowToVisible(originalTable.numberOfRows - 1)
            let scrollView = try XCTUnwrap(originalTable.enclosingScrollView)
            let before = scrollView.contentView.bounds.origin.y
            XCTAssertGreaterThan(before, 100)
            session.openSelectedPair()
            let child = try XCTUnwrap(workspace.current)
            guard case .text(let editor) = child.payload else { return XCTFail("Expected Text Compare") }
            window.contentView = NSHostingView(rootView: TextSessionView(model: editor, workspace: workspace))
            try await waitUntil { TextSide.allCases.allSatisfy { !editor.pane($0).busy } }
            await workspace.close(child.id)
            let returnedTable = try showFolder()
            let restored = try XCTUnwrap(returnedTable.enclosingScrollView)
            try await waitUntil { abs(restored.contentView.bounds.origin.y - before) < 1 }
            XCTAssertEqual(returnedTable.selectedRowIndexes.count, 2)
        }
    }

    func testAllVisibleTextFilesOfferOnlyContentComparison() async throws {
        try await fixture { _, left, right in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try write(name, to: name, in: left)
            }
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            let all = Set(session.rows.map(\.id))
            let partial = Set(session.rows.prefix(2).map(\.id))
            let compare = L("Compare Contents", "比较内容")
            let open = L("Open in Text Compare", "在文本比较中打开")
            for side: TextSide? in [nil, .left, .right] {
                let allMenu = FolderContextMenu(session: session, ids: all, side: side) { _ in }
                XCTAssertEqual(allMenu.nativeMenu().items.map(\.title), [compare])
                let partialMenu = FolderContextMenu(session: session, ids: partial, side: side) { _ in }
                XCTAssertNotNil(partialMenu.nativeMenu().item(withTitle: open))
            }
            await session.close()
        }
    }

    func testOpenCommandsFollowTextEligibilityAndExpandableFolders() async throws {
        try await fixture { _, left, right in
            for path in ["single.txt", "mixed.txt", "image.png", "folder/child.txt"] {
                try write("text", to: path, in: left)
            }
            try Data([0, 1]).write(to: right.appendingPathComponent("mixed.txt"))
            let session = FolderSession(left: left, right: right, registry: EditRegistry())
            session.refresh()
            try await waitUntil { session.complete }
            let open = L("Open in Text Compare", "在文本比较中打开")
            for (path, opensText, opensItem) in [("single.txt", true, true), ("mixed.txt", false, false),
                                                  ("image.png", false, false), ("folder", false, true)] {
                session.selection = [Data(path.utf8)]
                XCTAssertEqual(session.canOpenSelected(includingFolders: false), opensText, path)
                XCTAssertEqual(session.canOpenSelected(includingFolders: true), opensItem, path)
                let menu = FolderContextMenu(session: session, ids: session.selection, side: .left) { _ in }
                XCTAssertEqual(menu.nativeMenu().item(withTitle: open) != nil, opensText, path)
            }
            await session.close()
        }
    }

    func testBaseFolderNavigationChecksIdentityAndRestoresBothSidesTogether() async throws {
        try await fixture { _, left, right in
            for root in [left, right] { try write("one", to: "src/one.txt", in: root) }
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            let row = try XCTUnwrap(folder.entries.first)
            folder.useAsRoots(row)
            XCTAssertEqual(folder.left?.lastPathComponent, "src")
            XCTAssertEqual(folder.right?.lastPathComponent, "src")
            folder.visitLocation(backward: true)
            XCTAssertEqual(folder.left, left)
            XCTAssertEqual(folder.right, right)
            folder.visitLocation(backward: false)
            XCTAssertEqual(folder.left, row.left)
            XCTAssertEqual(folder.right, row.right)
            folder.visitLocation(backward: true)
            try await waitUntil { folder.complete }
            let directory = left.appendingPathComponent("src")
            try FileManager.default.moveItem(at: directory, to: left.appendingPathComponent("old"))
            try write("replacement", to: "src/one.txt", in: left)
            folder.useAsRoots(row)
            XCTAssertEqual(folder.left, left)
            folder.visitLocation(backward: false)
            XCTAssertEqual(folder.left, left)
            XCTAssertEqual(folder.right, right)
            await folder.close()
        }
    }

    func testFolderSelectionTintsOnlyTheClickedPane() async throws {
        _ = NSApplication.shared
        try await fixture { temp, left, right in
            for root in [left, right] {
                try write("shared", to: "a.txt", in: root)
                try write(root.lastPathComponent, to: "b.txt", in: root)
            }
            for index in 0..<40 { try write("one-sided", to: "z-\(index).txt", in: left) }
            let registry = EditRegistry()
            let session = FolderSession(left: left, right: right, registry: registry)
            session.refresh()
            try await waitUntil { session.complete }
            let workspace = Workspace(registry: registry, library: SessionLibrary(storageURL: temp.appendingPathComponent("sessions.json")))
            let host = NSHostingView(rootView: FolderView(session: session, workspace: workspace))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            @MainActor func descendant<T: NSView>(_ view: NSView, of type: T.Type) -> T? {
                if let found = view as? T { return found }
                return view.subviews.lazy.compactMap { descendant($0, of: type) }.first
            }
            let table = try XCTUnwrap(descendant(host, of: NSTableView.self))
            let anchor = try XCTUnwrap(descendant(host, of: FolderTableInput.Anchor.self))
            table.tableColumns[0].width = 260

            @MainActor func event(_ type: NSEvent.EventType, column: Int, row: Int = 0, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                let rect = table.frameOfCell(atColumn: column, row: row)
                let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            @MainActor func checkTint(_ expected: Set<Int>, row: Int = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
                for column in 0..<7 {
                    let cell = table.frameOfCell(atColumn: column, row: row)
                    let crop = NSRect(x: floor(cell.midX), y: floor(cell.minY + 2), width: 2, height: 2)
                    let bitmap = try XCTUnwrap(table.bitmapImageRepForCachingDisplay(in: crop))
                    table.cacheDisplay(in: crop, to: bitmap)
                    let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(color.blueComponent - color.redComponent > 0.08, expected.contains(column), "Column \(column) sampled \(color)", file: file, line: line)
                }
            }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                XCTAssertNotNil(try anchor.pointerMenu(for: event(.rightMouseDown, column: 1)))
                try await checkTint([0, 1, 2])
                XCTAssertFalse(try anchor.handle(event(.leftMouseDown, column: 6)))
                try await checkTint([4, 5, 6])
                XCTAssertFalse(try anchor.handle(event(.leftMouseDown, column: 3)))
                try await checkTint(Set(0..<7))
                XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
            }
            XCTAssertNotNil(try anchor.pointerMenu(for: event(.rightMouseDown, column: 1)))
            XCTAssertTrue(try anchor.handle(event(.leftMouseDown, column: 5, row: 1, modifiers: .command)))
            try await checkTint([0, 1, 2])
            try await checkTint([4, 5, 6], row: 1)
            XCTAssertNotNil(try anchor.pointerMenu(for: event(.rightMouseDown, column: 5)))
            try await checkTint([4, 5, 6])
            try await checkTint([], row: 1)
            session.sortOrder = [FolderRowSort(column: .leftName, order: .reverse)]
            let last = session.rows.count - 1
            table.scrollRowToVisible(0)
            try await checkTint([])
            table.scrollRowToVisible(last)
            try await checkTint([4, 5, 6], row: last)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: last))
            XCTAssertTrue(window.makeFirstResponder(table))
            let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, characters: up, charactersIgnoringModifiers: up, isARepeat: false, keyCode: 126))
            table.keyDown(with: arrow)
            try await checkTint([4, 5, 6], row: last - 1)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: last - 1))

            session.filter = .identical
            try await waitUntil { table.numberOfRows == 1 }
            XCTAssertNotNil(try anchor.pointerMenu(for: event(.rightMouseDown, column: 1)))
            let edit = NSMenu()
            let selectAll = edit.addItem(withTitle: "Select All", action: #selector(NSTableView.selectAll(_:)), keyEquivalent: "a")
            selectAll.target = table
            edit.performActionForItem(at: 0)
            let batch = try XCTUnwrap(anchor.pointerMenu(for: event(.rightMouseDown, column: 0))?.1)
            XCTAssertEqual(batch.items.map(\.title), [L("Compare Contents", "比较内容")])
            try await checkTint(Set(0..<7))
            XCTAssertFalse(try anchor.handle(event(.leftMouseDown, column: 0)))
            let single = try XCTUnwrap(anchor.pointerMenu(for: event(.rightMouseDown, column: 0))?.1)
            XCTAssertNotNil(single.item(withTitle: L("Open in Text Compare", "在文本比较中打开")))
            try await checkTint([0, 1, 2])
            await session.close()
        }
    }

    func testCountsIncludeEmptyFoldersAndFileDirectoryConflicts() async throws {
        try await fixture { _, left, right in
            for name in ["empty", "conflict"] {
                try FileManager.default.createDirectory(at: left.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            try write("file", to: "conflict", in: right)
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            XCTAssertEqual(folder.counts[.leftOnly], 1)
            XCTAssertEqual(folder.counts[.conflict], 1)
            await folder.close()
        }
    }

    func testSelectByPresenceAndModificationDateUsesTheVisibleSide() async throws {
        try await fixture { _, left, right in
            for root in [left, right] {
                try write("same content", to: "shared.txt", in: root)
                try write("one-sided", to: root.lastPathComponent, in: root)
            }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                                  ofItemAtPath: right.appendingPathComponent("shared.txt").path)
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            folder.selectVisibleFiles(matching: .newer(.left))
            XCTAssertEqual(folder.selection, [Data("shared.txt".utf8)])
            folder.selectVisibleFiles(matching: .newer(.right))
            XCTAssertTrue(folder.selection.isEmpty)
            folder.selectVisibleFiles(matching: .orphans(.right))
            XCTAssertEqual(folder.selection, [Data("right".utf8)])
            folder.filter = .identical
            folder.selectVisibleFiles(matching: .orphans(.left))
            XCTAssertTrue(folder.selection.isEmpty)
            await folder.close()
        }
    }

    func testFindRevealsMatchingAncestorsAndRefreshRespectsClearedSelection() async throws {
        try await fixture { _, left, right in
            for path in ["a/Readme.md", "b/README.md", "c/Other"] { try write("text", to: path, in: left) }
            let folder = FolderSession(left: left, right: right, registry: EditRegistry())
            folder.refresh()
            try await waitUntil { folder.complete }
            folder.findQuery = "readme"
            folder.findFilename(backward: true)
            XCTAssertEqual(folder.selection, [Data("b/README.md".utf8)])
            XCTAssertTrue(folder.rows.contains { $0.entry.path == "b/README.md" })
            folder.findFilename(backward: false)
            XCTAssertEqual(folder.selection, [Data("a/Readme.md".utf8)])
            folder.refresh()
            folder.selection.removeAll()
            try await waitUntil { folder.complete }
            XCTAssertTrue(folder.selection.isEmpty)
            folder.filter = .identical
            folder.findFilename(backward: false)
            XCTAssertTrue(folder.findMiss)
            XCTAssertTrue(folder.selection.isEmpty)
            await folder.close()
        }
    }

    func testFileColorsUseModificationTimesOnlyForDifferentContents() {
        var left = FileVersion(stat()), right = left
        left.modified = Date(timeIntervalSince1970: 1)
        right.modified = Date(timeIntervalSince1970: 2)
        var entry = FolderEntry(path: "source.txt", leftVersion: left, rightVersion: right, isDirectory: false, state: .identical)
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: true), .normal)
        entry.state = .different
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: true), .older)
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: false), .newer)
        entry.rightVersion = left
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: false), .different)
        entry.state = .leftOnly
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: true), .oneSided)
        entry.state = .notCompared
        XCTAssertEqual(FolderComparisonColor(entry, onLeft: true), .normal)
    }

    func testCompactFolderMetadataUsesTheAppLanguage() {
        XCTAssertEqual(FolderMetadata.size(8), L("8 bytes", "8 字节"))
        let today = Calendar.current.date(bySettingHour: 9, minute: 4, second: 0, of: .now)!
        XCTAssertEqual(FolderMetadata.modified(today), L("Today 09:04", "今天 09:04"))
    }
}

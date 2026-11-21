import Foundation
import SwiftUI
import XCTest
@testable import TandemDiff

@MainActor
final class HomeLibraryTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("sessions.json"))
    }

    func testSessionMenuOffersSaveOnlyWithAnActiveComparison() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("NSHostingMenu requires macOS 14.4") }
        _ = NSApplication.shared
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: url))
        let menu = NSHostingMenu(rootView: SessionMenuItems(workspace: workspace))
        let save = L("Save Session", "保存会话")
        let saveAs = L("Save Session As…", "会话另存为…")
        menu.update()
        XCTAssertNotNil(menu.item(withTitle: L("New ", "新建") + HomeTool.folderCompare.title))
        XCTAssertNil(menu.item(withTitle: save))
        XCTAssertNil(menu.item(withTitle: saveAs))
        workspace.makeFolders()
        for _ in 0..<50 where menu.item(withTitle: save) == nil {
            try await Task.sleep(for: .milliseconds(10))
            menu.update()
        }
        XCTAssertNotNil(menu.item(withTitle: save))
        XCTAssertNotNil(menu.item(withTitle: saveAs))
    }

    func testOldLibraryCanOrganizeAndRemoveFoldersWithoutLosingSessionsOrFiles() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("left.txt")
        try Data("keep".utf8).write(to: file)
        let recent = SessionRecord(id: UUID(), kind: .text, left: SavedPath(file))
        let oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recent))
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [oldRecord]]).write(to: url)
        let library = SessionLibrary(storageURL: url)
        XCTAssertEqual(library.records.first?.id, recent.id)
        XCTAssertEqual(library.recentTextPaths, [file.path])
        let folder = SessionFolder(id: UUID(), name: "Reports")
        let child = SessionFolder(id: UUID(), name: "April", parent: folder.id)
        XCTAssertTrue(library.saveFolder(folder))
        XCTAssertTrue(library.saveFolder(child))
        var saved = recent
        saved.id = UUID()
        saved.name = "Review"
        saved.folderID = child.id
        saved.notes = "Working draft"
        XCTAssertTrue(library.saveDefinition(saved, replacing: nil))
        XCTAssertTrue(library.removeFolder(folder.id))
        let loaded = SessionLibrary(storageURL: url)
        XCTAssertEqual(loaded.folderPath(child.id), "April")
        XCTAssertEqual(loaded.records.first { $0.id == saved.id }?.folderID, child.id)
        XCTAssertTrue(loaded.removeFolder(child.id))
        XCTAssertNil(loaded.records.first { $0.id == saved.id }?.folderID)
        XCTAssertTrue(loaded.removeSessions([recent.id]))
        let remaining = try XCTUnwrap(SessionLibrary(storageURL: url).records.first)
        XCTAssertEqual(remaining.id, saved.id)
        XCTAssertEqual(remaining.notes, "Working draft")
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testRecentFilesTrackSuccessfulPaneOpensAcrossRelaunch() async throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.txt")
        let second = dir.appendingPathComponent("second.txt")
        for file in [first, second] { try Data(file.lastPathComponent.utf8).write(to: file) }
        let library = SessionLibrary(storageURL: url)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        workspace.makeText(left: first)
        guard case let .text(session) = workspace.tabs.first?.payload else { return XCTFail("Missing text session") }
        for _ in 0..<200 where !session.canChangeFiles { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(library.recentTextPaths, [first.path])
        await session.openPath(second.path, on: .left)
        XCTAssertEqual(library.recentTextPaths, [second.path, first.path])
        await session.openPath(first.path, on: .left)
        await session.openPath(dir.appendingPathComponent("missing.txt").path, on: .right)
        XCTAssertEqual(SessionLibrary(storageURL: url).recentTextPaths, [first.path, second.path])
    }

    func testEditingOpenDefinitionPreservesOldTabAndReusesItsNewVersion() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.txt")
        let second = dir.appendingPathComponent("second.txt")
        for file in [first, second] { try Data("sample".utf8).write(to: file) }
        let library = SessionLibrary(storageURL: url)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        let original = SessionRecord(id: UUID(), name: "Draft", kind: .text, left: SavedPath(first))
        XCTAssertTrue(library.store(original))
        workspace.open(original)
        var edited = original
        edited.left = SavedPath(second)
        edited.name = "Revised"
        XCTAssertTrue(library.saveDefinition(edited, replacing: original))
        XCTAssertFalse(library.saveDefinition(original, replacing: original))
        workspace.saveSession(asNew: false)
        XCTAssertNotNil(workspace.notice)
        let revised = try XCTUnwrap(library.records.first)
        XCTAssertEqual(revised.left?.path, second.path)
        workspace.open(revised)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertNotEqual(workspace.active, original.id)
        XCTAssertEqual(workspace.current?.definitionID, revised.id)
        workspace.open(revised)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(library.removeSessions([revised.id]))
        workspace.saveSession(asNew: false)
        XCTAssertTrue(library.records.isEmpty)
    }

    func testLockedRecordStillOpensAndCanBeCopiedButRejectsOverwriteAndRemoval() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SessionLibrary(storageURL: url)
        let original = SessionRecord(id: UUID(), name: "Protected", kind: .folders, left: SavedPath(dir))
        XCTAssertTrue(library.store(original))
        library.setLocked(true, id: original.id)
        let protected = try XCTUnwrap(library.records.first)
        library.markOpened(protected)
        XCTAssertFalse(library.removeSessions([protected.id]))
        XCTAssertFalse(library.saveDefinition(original, replacing: original))
        XCTAssertFalse(library.store(original))
        var duplicate = protected
        duplicate.id = UUID()
        duplicate.name = "Independent copy"
        duplicate.locked = nil
        XCTAssertTrue(library.saveDefinition(duplicate, replacing: nil))
        let loaded = SessionLibrary(storageURL: url)
        XCTAssertEqual(loaded.records.count, 2)
        loaded.setLocked(false, id: original.id)
        XCTAssertTrue(loaded.removeSessions([original.id]))
        XCTAssertEqual(loaded.records.map(\.id), [duplicate.id])
    }

    func testSaveAsFromOpenLockedSessionKeepsFolderAndNotesOnIndependentCopy() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SessionLibrary(storageURL: url)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        let folder = SessionFolder(id: UUID(), name: "Team")
        XCTAssertTrue(library.saveFolder(folder))
        let record = SessionRecord(id: UUID(), name: "Reference", kind: .text, folderID: folder.id, locked: true, notes: "Retain this")
        XCTAssertTrue(library.store(record))
        workspace.open(record)
        workspace.saveSession(asNew: true) { _ in "New copy" }
        let restored = SessionLibrary(storageURL: url)
        let copy = try XCTUnwrap(restored.records.first { $0.name == "New copy" })
        XCTAssertEqual(copy.folderID, folder.id)
        XCTAssertEqual(copy.notes, record.notes)
        XCTAssertNotEqual(copy.id, record.id)
        XCTAssertNotEqual(copy.locked, true)
        XCTAssertEqual(restored.records.first { $0.id == record.id }?.locked, true)
        XCTAssertEqual(workspace.current?.definitionID, record.id)
    }

    func testSaveEmptyAndSingleSidedFolderSettings() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SessionLibrary(storageURL: url)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        for path in [nil, SavedPath(dir)] {
            let record = SessionRecord(id: UUID(), name: "Setup", kind: .folders, left: path)
            XCTAssertTrue(library.store(record))
            workspace.open(record)
            guard case .folders(let folder)? = workspace.current?.payload else { return XCTFail("Missing folder tab") }
            folder.filter = .changes
            workspace.saveSession(asNew: false)
            let loaded = try XCTUnwrap(SessionLibrary(storageURL: url).records.first { $0.id == record.id })
            XCTAssertEqual(loaded.folderFilter, FolderFilter.changes.rawValue)
            XCTAssertEqual(loaded.left?.path, path?.path)
            XCTAssertNil(loaded.right)
        }
        XCTAssertFalse(library.records.contains { $0.name == nil })
    }

    func testMultiOpenFollowsSidebarOrderAndMultiRemoveValidatesEveryRecord() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SessionLibrary(storageURL: url)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        let group = SessionFolder(id: UUID(), name: "Reports")
        XCTAssertTrue(library.saveFolder(group))
        let folderSession = SessionRecord(id: UUID(), name: "Report", kind: .folders, folderID: group.id)
        let rootSession = SessionRecord(id: UUID(), name: "Root", kind: .text)
        let file = dir.appendingPathComponent("test.txt")
        try Data("source".utf8).write(to: file)
        let recent = SessionRecord(id: UUID(), kind: .text, left: SavedPath(file))
        for item in [folderSession, recent, rootSession] { XCTAssertTrue(library.store(item)) }
        let ids: Set<UUID> = [rootSession.id, recent.id, folderSession.id]
        workspace.openSessions(ids)
        XCTAssertEqual(workspace.tabs.map(\.id), [recent.id, folderSession.id, rootSession.id])
        library.setLocked(true, id: rootSession.id)
        XCTAssertFalse(library.removeSessions(ids))
        XCTAssertEqual(Set(SessionLibrary(storageURL: url).records.map(\.id)), ids)
        XCTAssertTrue(library.removeSessions([recent.id, folderSession.id]))
        XCTAssertEqual(SessionLibrary(storageURL: url).records.map(\.id), [rootSession.id])
    }

    func testFailedWriteDoesNotMutateLibraryInMemory() throws {
        let (dir, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SessionLibrary(storageURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertFalse(library.saveFolder(SessionFolder(id: UUID(), name: "Folder")))
        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertNotNil(library.notice)
    }
}

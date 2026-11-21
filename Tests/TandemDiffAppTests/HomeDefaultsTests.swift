import Foundation
import TandemDiffCore
import XCTest
@testable import TandemDiff

@MainActor
final class HomeDefaultsTests: XCTestCase {
    func testStaleDefaultsCannotReplaceAnotherWindowsEditsUntilReloaded() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let first = SessionDefaults(store: store)
        let second = SessionDefaults(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let originalText = second.text
        XCTAssertEqual(originalText.context, 6)
        let originalFolders = second.folders
        var firstText = originalText
        firstText.ignoreCase = true
        try first.save(firstText, replacing: originalText)
        var secondText = originalText
        secondText.context = 7
        XCTAssertThrowsError(try second.save(secondText, replacing: originalText))
        XCTAssertEqual(second.text, firstText)
        let reloaded = second.text
        secondText = reloaded
        secondText.context = 7
        try second.save(secondText, replacing: reloaded)
        XCTAssertEqual(first.text, secondText)

        var firstFolders = originalFolders
        firstFolders.writeProtected = true
        try first.save(firstFolders, replacing: originalFolders)
        XCTAssertThrowsError(try second.save(FolderSessionDefaults(filter: .changes), replacing: originalFolders))
        XCTAssertEqual(second.folders, firstFolders)
    }

    func testNewSessionsReadCurrentDefaultsAndRestoredSessionsKeepTheirSettings() async throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let defaults = SessionDefaults(store: store)
        let library = SessionLibrary(storageURL: URL.temporaryDirectory.appendingPathComponent(suite))
        let workspace = Workspace(registry: EditRegistry(), library: library, sessionDefaults: defaults)

        workspace.makeFolders()
        guard case .folders(let first)? = workspace.current?.payload else { return XCTFail("Missing first folder session") }
        let rules = NameRules(quickExpression: "*.txt;-cache/")
        try defaults.save(FolderSessionDefaults(rules: rules, filter: .changes, showExcluded: true, writeProtected: true), replacing: defaults.folders)
        var text = TextSessionSettings()
        text.mode = .context
        text.context = 7
        text.ignoreWhitespace = true
        text.rightLocked = true
        try defaults.save(text, replacing: defaults.text)

        let reopenedStore = SessionDefaults(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopenedStore.folders.rules, rules)
        XCTAssertEqual(reopenedStore.text, text)
        workspace.makeFolders()
        guard case .folders(let folder)? = workspace.current?.payload else { return XCTFail("Missing new folder session") }
        XCTAssertEqual(folder.rules, rules)
        XCTAssertEqual(folder.filter, .changes)
        XCTAssertTrue(folder.showExcluded)
        XCTAssertTrue(folder.writeProtected)
        XCTAssertFalse(first.writeProtected)
        workspace.makeText()
        guard case .text(let editor)? = workspace.current?.payload else { return XCTFail("Missing new text session") }
        XCTAssertEqual(editor.settings, text)

        workspace.open(SessionRecord(id: UUID(), name: "Review", kind: .folders, folderFilter: FolderFilter.leftOnly.rawValue))
        guard case .folders(let savedFolder)? = workspace.current?.payload else { return XCTFail("Missing restored folder session") }
        XCTAssertEqual(savedFolder.filter, .leftOnly)
        XCTAssertEqual(savedFolder.rules, NameRules())
        XCTAssertFalse(savedFolder.writeProtected)

        workspace.open(SessionRecord(id: UUID(), name: "Legacy", kind: .text))
        guard case .text(let legacy)? = workspace.current?.payload else { return XCTFail("Missing restored legacy session") }
        XCTAssertEqual(legacy.settings, .legacyDefaults)
        XCTAssertEqual(legacy.settings.context, 3)
        let snapshot = TextSessionSettings(mode: .equal, leftLocked: true)
        workspace.open(SessionRecord(id: UUID(), name: "Saved", kind: .text, textSettings: snapshot))
        guard case .text(let savedText)? = workspace.current?.payload else { return XCTFail("Missing saved text session") }
        XCTAssertEqual(savedText.settings, snapshot)
    }

    func testChildTextPreferencesPreserveInheritedProtection() async throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let defaults = SessionDefaults(store: store)
        try defaults.save(FolderSessionDefaults(writeProtected: true), replacing: defaults.folders)
        try defaults.save(TextSessionSettings(ignoreCase: true), replacing: defaults.text)
        let library = SessionLibrary(storageURL: URL.temporaryDirectory.appendingPathComponent(suite))
        let workspace = Workspace(registry: EditRegistry(), library: library, sessionDefaults: defaults)
        workspace.makeFolders()
        guard let parent = workspace.current, case .folders(let folder) = parent.payload else { return XCTFail("Missing parent") }
        workspace.makeText(parent: parent.id, folder: folder)
        guard case .text(let child)? = workspace.current?.payload else { return XCTFail("Missing child") }
        XCTAssertTrue(child.settings.ignoreCase)
        XCTAssertTrue(child.locked(.left))
        XCTAssertTrue(child.locked(.right))
        XCTAssertFalse(child.editable(.left))
        XCTAssertFalse(child.editable(.right))
        XCTAssertFalse(defaults.text.inheritedGuard)
    }
}

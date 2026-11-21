import Foundation
import XCTest
@testable import TandemDiff

@MainActor
final class FolderPathTests: XCTestCase {
    func testBothSidesShareSuccessfulFolderPathsAcrossRelaunch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second folder")
        let child = second.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = base.appendingPathComponent("sessions.json")
        let library = SessionLibrary(storageURL: store)
        let workspace = Workspace(registry: EditRegistry(), library: library)
        workspace.makeFolders(left: first)
        guard case let .folders(session) = workspace.current?.payload else { return XCTFail("Missing folder session") }
        XCTAssertEqual(library.recentFolderPaths, [first.path])

        session.openPath("../second folder", onLeft: true)
        XCTAssertEqual(session.left?.path, second.path)
        session.openPath("child", onLeft: false)
        XCTAssertEqual(session.right?.path, child.path)
        session.openPath(first.absoluteString, onLeft: false)
        XCTAssertEqual(session.right?.path, first.path)
        for invalid in [store.path, "missing", "file://example.com" + first.path, "https://example.com"] {
            session.openPath(invalid, onLeft: false)
            XCTAssertEqual(session.right?.path, first.path)
            XCTAssertNotNil(session.notice)
        }
        let reloaded = SessionLibrary(storageURL: store)
        XCTAssertEqual(reloaded.recentFolderPaths, [first.path, child.path, second.path])
        XCTAssertEqual(reloaded.recentTextPaths, [])
        await session.close()
    }

    func testOlderFolderSessionsSeedHistoryWithExistingFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("sessions.json")
        let missing = base.appendingPathComponent("missing")
        let session = SessionRecord(id: UUID(), kind: .folders, left: SavedPath(base), right: SavedPath(missing))
        let oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [oldRecord]]).write(to: store)

        let library = SessionLibrary(storageURL: store)
        XCTAssertEqual(library.recentFolderPaths, [base.path])
        XCTAssertEqual(library.records.first?.id, session.id)
    }

    func testHomeInputResolvesForAnEmptySide() async {
        let session = FolderSession(left: nil, right: nil, registry: EditRegistry())
        session.openPath("~", onLeft: true)
        XCTAssertEqual(session.left?.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNil(session.right)
        await session.close()
    }
}

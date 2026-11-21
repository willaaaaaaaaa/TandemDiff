import Foundation
import XCTest
@testable import TandemDiff

@MainActor
final class HomeDropTests: XCTestCase {
    func testLauncherChecksTypeAndHonorsConfirmedOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        for file in [a, b] { try Data("sample".utf8).write(to: file) }
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: root.appendingPathComponent("sessions.json")))
        workspace.accept([a, b], for: .folders)
        XCTAssertNotNil(workspace.notice)
        XCTAssertNil(workspace.incoming)
        XCTAssertTrue(workspace.tabs.isEmpty)
        workspace.notice = nil
        workspace.accept([b, a], for: .text)
        XCTAssertNil(workspace.notice)
        XCTAssertEqual(workspace.incoming?.left, b)
        XCTAssertTrue(workspace.tabs.isEmpty)
        workspace.startIncoming()
        guard case .text(let editor)? = workspace.current?.payload else { return XCTFail("Expected a text comparison") }
        XCTAssertEqual(editor.leftURL, b)
        XCTAssertEqual(editor.rightURL, a)
    }

    func testConfirmationRechecksBothInputsBeforeOpening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(registry: EditRegistry(), library: SessionLibrary(storageURL: root.appendingPathComponent("sessions.json")))
        workspace.accept([a, b], for: .folders)
        XCTAssertNotNil(workspace.incoming)
        try FileManager.default.removeItem(at: b)
        try Data("replacement".utf8).write(to: b)
        workspace.startIncoming()
        XCTAssertNil(workspace.incoming)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNotNil(workspace.notice)
    }
}

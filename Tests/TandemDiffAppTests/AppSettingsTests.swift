import AppKit
import TandemDiffCore
import SwiftUI
import XCTest
@testable import TandemDiff

@MainActor
final class AppSettingsTests: XCTestCase {
    func testEnglishDefaultAndPersistedLanguage() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(["zh-Hans"], forKey: "AppleLanguages")
        let preferences = AppLocalization(store: store)
        XCTAssertEqual(preferences.language, .english)
        preferences.language = .simplifiedChinese
        XCTAssertEqual(AppLocalization(store: store).language, .simplifiedChinese)
        store.set("unexpected", forKey: "appLanguage")
        XCTAssertEqual(preferences.language, .english)
    }

    func testNewTabsUseTheConfiguredPosition() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let library = SessionLibrary(storageURL: URL.temporaryDirectory.appendingPathComponent(suite))
        let workspace = Workspace(registry: EditRegistry(), library: library, sessionDefaults: SessionDefaults(store: store))
        workspace.makeFolders()
        let first = try XCTUnwrap(workspace.active)
        workspace.makeText()
        let second = try XCTUnwrap(workspace.active)
        workspace.active = first
        workspace.makeFolders()
        let third = try XCTUnwrap(workspace.active)
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third])
        store.set(true, forKey: "newTabsBesideActive")
        workspace.active = first
        workspace.makeText()
        XCTAssertEqual(workspace.tabs.map(\.id), [first, try XCTUnwrap(workspace.active), second, third])
    }

    func testLiveLanguageChangeRetainsNativeEditorSelectionAndDirtyText() async throws {
        _ = NSApplication.shared
        let preferences = AppLocalization.shared
        let original = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            preferences.language = (original as? String).flatMap(AppLanguage.init(rawValue:)) ?? .english
            if original == nil { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        preferences.language = .english
        let model = TextSessionModel(left: nil, right: nil, writer: FileWriter())
        XCTAssertTrue(model.edit(.left, raw: NSRange(), replacement: "Working draft"))
        for _ in 0..<50 where model.alignment == nil || model.aligning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.alignment)
        XCTAssertFalse(model.aligning)
        let selection = NSRange(location: 0, length: 7)
        model.pane(.left).selection = selection
        model.statusMessage = TextFailure.decode.comparisonDiagnostic
        let host = NSHostingView(rootView: LiveEditor(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findEditor(in: host))
        XCTAssertEqual(editor.accessibilityLabel(), "Left text editor")

        preferences.language = .simplifiedChinese
        for _ in 0..<50 where editor.accessibilityLabel() != "左侧文本编辑器" {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(findEditor(in: host) === editor)
        XCTAssertEqual(editor.accessibilityLabel(), "左侧文本编辑器")
        XCTAssertEqual(model.status, "文件字节与支持的文本编码不匹配。")
        XCTAssertEqual(model.pane(.left).selection, selection)
        XCTAssertEqual(editor.string, "Working draft")
        XCTAssertTrue(model.isDirty)
    }

    private func findEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap(self.findEditor).first
    }

    private struct LiveEditor: View {
        let model: TextSessionModel

        var body: some View {
            TextNativeView(model: model, side: .left)
                .environment(\.locale, AppLocalization.shared.language.locale)
        }
    }
}

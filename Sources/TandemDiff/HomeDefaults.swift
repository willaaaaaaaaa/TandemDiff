import TandemDiffCore
import SwiftUI

struct FolderSessionDefaults: Codable, Equatable {
    var rules = NameRules()
    var filter: FolderFilter = .all
    var structure: FolderStructure?
    var showExcluded = false
    var writeProtected = false
}

struct SessionDefaults {
    struct Changed: LocalizedError {
        var errorDescription: String? {
            L("These defaults changed in another window. Reload to edit the current settings.", "默认设置已在其他窗口更改。请重新载入后编辑。")
        }
    }

    private let store: UserDefaults
    private let folderKey = "sessionDefaults.folders"
    static let textKey = "sessionDefaults.text"

    init(store: UserDefaults = .standard) { self.store = store }

    var newTabsBesideActive: Bool { store.bool(forKey: "newTabsBesideActive") }

    var folders: FolderSessionDefaults {
        guard let data = store.data(forKey: folderKey),
              let value = try? JSONDecoder().decode(FolderSessionDefaults.self, from: data)
        else { return FolderSessionDefaults() }
        return value
    }

    var text: TextSessionSettings { Self.decodeText(store.data(forKey: Self.textKey)) }

    static func decodeText(_ data: Data?) -> TextSessionSettings {
        guard let data,
              var value = try? JSONDecoder().decode(TextSessionSettings.self, from: data)
        else { return TextSessionSettings() }
        value.inheritedGuard = false
        value.context = min(100, max(0, value.context))
        return value
    }

    @MainActor func save(_ value: FolderSessionDefaults, replacing original: FolderSessionDefaults) throws {
        guard folders == original else { throw Changed() }
        store.set(try JSONEncoder().encode(value), forKey: folderKey)
    }

    @MainActor func save(_ value: TextSessionSettings, replacing original: TextSessionSettings) throws {
        guard text == original else { throw Changed() }
        var value = value
        value.inheritedGuard = false
        store.set(try JSONEncoder().encode(value), forKey: Self.textKey)
    }
}

struct HomeDefaultsEditor: View {
    let kind: SessionRecord.Kind
    let defaults: SessionDefaults
    @Environment(\.dismiss) private var dismiss
    @State private var folders: FolderSessionDefaults
    @State private var text: TextSessionSettings
    @State private var originalFolders: FolderSessionDefaults
    @State private var originalText: TextSessionSettings
    @State private var error: Error?

    init(kind: SessionRecord.Kind, defaults: SessionDefaults) {
        self.kind = kind
        self.defaults = defaults
        let folders = defaults.folders
        let text = defaults.text
        _originalFolders = State(initialValue: folders)
        _originalText = State(initialValue: text)
        _folders = State(initialValue: folders)
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .folders ? L("Folder comparison defaults", "文件夹比较默认设置") : L("Text comparison defaults", "文本比较默认设置"))
                .font(.title3.weight(.semibold))
            Form {
                switch kind {
                case .folders:
                    HomeFolderOptions(rules: $folders.rules, filter: $folders.filter, structure: Binding(get: { folders.structure ?? .compareFolders }, set: { folders.structure = $0 }), showExcluded: $folders.showExcluded, writeProtected: $folders.writeProtected)
                case .text:
                    HomeTextOptions(settings: $text)
                }
            }
            if let error {
                HStack {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.callout)
                    if error is SessionDefaults.Changed {
                        Button(L("Reload", "重新载入")) { reload() }
                    }
                }
            }
            Divider()
            HStack {
                Button(L("Restore Defaults", "恢复初始设置")) {
                    folders = FolderSessionDefaults()
                    text = TextSessionSettings()
                }
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private func reload() {
        originalFolders = defaults.folders
        originalText = defaults.text
        folders = originalFolders
        text = originalText
        error = nil
    }

    private func save() {
        do {
            switch kind {
            case .folders:
                try defaults.save(folders, replacing: originalFolders)
            case .text:
                try defaults.save(text, replacing: originalText)
            }
            dismiss()
        } catch { self.error = error }
    }
}

struct HomeFolderOptions: View {
    @Binding var rules: NameRules
    @Binding var filter: FolderFilter
    @Binding var structure: FolderStructure
    @Binding var showExcluded: Bool
    @Binding var writeProtected: Bool
    @State private var editingNameFilters = false

    var body: some View {
        LabeledContent(L("Name Filters", "名称筛选")) {
            Text(rules.quickExpression.isEmpty ? L("None", "无") : L("Active", "已启用")).foregroundStyle(.secondary)
            Button(L("Edit…", "编辑…")) { editingNameFilters = true }
                .accessibilityLabel(L("Name Filters", "名称筛选"))
        }
        .sheet(isPresented: $editingNameFilters) {
            NameFilterEditor(rules: rules) { rules = $0 }
        }
        Picker(L("Show", "显示"), selection: $filter) {
            ForEach(FolderFilter.allCases) { item in Text(item.label).tag(item) }
        }
        Picker(L("Folder structure", "目录结构"), selection: $structure) {
            ForEach(FolderStructure.allCases) { Text($0.label).tag($0) }
        }
        Toggle(L("Show excluded items", "显示排除项"), isOn: $showExcluded)
        Toggle(L("Protect writes", "保护写入"), isOn: $writeProtected)
    }
}

struct HomeTextOptions: View {
    @Binding var settings: TextSessionSettings

    var body: some View {
        Picker(L("Show", "显示"), selection: $settings.mode) {
            Text(ComparisonDisplay.all.title).tag(TextViewMode.all)
            Text(ComparisonDisplay.differences.title).tag(TextViewMode.changes)
            Text(ComparisonDisplay.same.title).tag(TextViewMode.equal)
            Text(L("Differences with context", "带上下文的差异")).tag(TextViewMode.context)
        }
        Stepper(value: $settings.context, in: 0...100) {
            Text(L("Context lines", "上下文行数") + "  \(settings.context)")
        }
        Toggle(L("Ignore case", "忽略大小写"), isOn: $settings.ignoreCase)
        Toggle(L("Ignore spaces and tabs", "忽略空格与制表符"), isOn: $settings.ignoreWhitespace)
        Toggle(L("Hide minor changes", "隐藏细微差异"), isOn: $settings.hideMinor)
        if settings.inheritedGuard {
            Label(L("Both sides are protected by the parent session", "父会话已保护两侧"), systemImage: "lock")
        } else {
            Toggle(L("Protect left side", "保护左侧"), isOn: $settings.leftLocked)
            Toggle(L("Protect right side", "保护右侧"), isOn: $settings.rightLocked)
        }
    }
}

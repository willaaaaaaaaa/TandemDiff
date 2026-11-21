import AppKit
import TandemDiffCore
import SwiftUI

struct HomeSessionEditor: View {
    let record: SessionRecord
    @ObservedObject var library: SessionLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var original: SessionRecord?
    @State private var name: String
    @State private var left: String
    @State private var right: String
    @State private var leftChosen = false
    @State private var rightChosen = false
    @State private var notes: String
    @State private var folderID: UUID?
    @State private var filter: FolderFilter
    @State private var structure: FolderStructure
    @State private var rules: NameRules
    @State private var showExcluded: Bool
    @State private var protected: Bool
    @State private var textSettings: TextSessionSettings
    @State private var error: String?

    init(record: SessionRecord, library: SessionLibrary) {
        self.record = record
        self.library = library
        let saved = record.name != nil && library.records.contains { $0.id == record.id }
        _original = State(initialValue: saved ? record : nil)
        _name = State(initialValue: record.name ?? SessionTitles(records: [record]).title(record))
        _left = State(initialValue: record.left?.path ?? "")
        _right = State(initialValue: record.right?.path ?? "")
        _notes = State(initialValue: record.notes ?? "")
        _folderID = State(initialValue: record.folderID)
        _filter = State(initialValue: FolderFilter(rawValue: record.folderFilter ?? "") ?? .all)
        _structure = State(initialValue: FolderStructure(rawValue: record.folderStructure ?? "") ?? .compareFolders)
        _rules = State(initialValue: record.rules ?? NameRules())
        _showExcluded = State(initialValue: record.showExcluded == true)
        _protected = State(initialValue: record.folderWriteProtected == true)
        var settings = record.textSettings ?? .legacyDefaults
        if record.inheritedTextProtection == true { settings.inheritedGuard = true }
        _textSettings = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? L("Save Session As", "会话另存为") : L("Edit Session", "编辑会话"))
                .font(.title3.weight(.semibold))
            Form {
                TextField(L("Name", "名称"), text: $name)
                TextField(L("Description", "说明"), text: $notes, axis: .vertical).lineLimit(1...3)
                if !library.folders.isEmpty || folderID != nil {
                    Picker(L("Session folder", "会话文件夹"), selection: $folderID) {
                        Text(L("Saved Sessions", "已保存的会话")).tag(nil as UUID?)
                        ForEach(library.folders.sorted { library.folderPath($0.id) < library.folderPath($1.id) }) { folder in
                            Text(library.folderPath(folder.id)).tag(Optional(folder.id))
                        }
                    }
                }
                pathRow(L("Left", "左侧"), text: $left, chosen: $leftChosen)
                pathRow(L("Right", "右侧"), text: $right, chosen: $rightChosen)
                Divider()
                if record.kind == .folders {
                    HomeFolderOptions(rules: $rules, filter: $filter, structure: $structure, showExcluded: $showExcluded, writeProtected: $protected)
                } else {
                    HomeTextOptions(settings: $textSettings)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.primary) }
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func pathRow(_ title: String, text: Binding<String>, chosen: Binding<Bool>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text).labelsHidden().textFieldStyle(.roundedBorder)
            Button(L("Browse…", "浏览…")) {
                let panel = NSOpenPanel()
                panel.prompt = L("Open", "打开")
                panel.canChooseDirectories = record.kind == .folders
                panel.canChooseFiles = record.kind == .text
                if !text.wrappedValue.isEmpty { panel.directoryURL = LocalAccess.exactURL(text.wrappedValue).deletingLastPathComponent() }
                if panel.runModal() == .OK, let url = panel.url {
                    text.wrappedValue = url.path
                    chosen.wrappedValue = true
                }
            }
            .accessibilityLabel(title + " " + L("Browse", "浏览"))
        }
    }

    private func path(_ text: String, original: SavedPath?, wasMissing: Bool, chosen: Bool) throws -> (SavedPath?, Bool) {
        guard !text.isEmpty else { return (nil, false) }
        if !chosen, let original, original.path.utf8.elementsEqual(text.utf8) { return (original, wasMissing) }
        guard text.hasPrefix("/") else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSLocalizedDescriptionKey: L("Enter an absolute path or choose Browse.", "请输入绝对路径，或选择“浏览”。")])
        }
        let url = try LocalAccess.canonicalURL(LocalAccess.exactURL(text))
        try LocalAccess.validate(url)
        let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard directory == (record.kind == .folders) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: directory ? L("Choose a file instead of a folder.", "请选择文件。") : L("Choose a folder instead of a file.", "请选择文件夹。")])
        }
        return (SavedPath(url), false)
    }

    private func save() {
        var updated = record
        do {
            (updated.left, updated.leftWasMissing) = try path(left, original: record.left, wasMissing: record.leftWasMissing, chosen: leftChosen)
            (updated.right, updated.rightWasMissing) = try path(right, original: record.right, wasMissing: record.rightWasMissing, chosen: rightChosen)
        } catch {
            self.error = error.comparisonDiagnostic.localized
            return
        }
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.folderID = folderID
        updated.notes = notes.isEmpty ? nil : notes
        if original == nil { updated.id = UUID(); updated.locked = nil }
        if updated.kind == .folders {
            updated.rules = rules
            updated.folderFilter = filter.rawValue
            updated.folderStructure = structure.rawValue
            updated.showExcluded = showExcluded
            updated.folderWriteProtected = protected
            if leftChosen || rightChosen || left != (record.left?.path ?? "") || right != (record.right?.path ?? "") {
                updated.selection = nil
                updated.expansion = nil
            }
        } else {
            updated.textSettings = textSettings
        }
        if library.saveDefinition(updated, replacing: original) {
            dismiss()
        } else {
            error = library.notice
        }
    }
}

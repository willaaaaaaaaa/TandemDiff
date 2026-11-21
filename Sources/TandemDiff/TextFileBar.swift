import SwiftUI
import TandemDiffCore

struct TextFileBar: View {
    @ObservedObject var model: TextSessionModel
    let side: TextSide
    @ObservedObject var library: SessionLibrary
    private var pane: TextPane { model.pane(side) }
    private var sideName: String { side == .left ? L("Left", "左侧") : L("Right", "右侧") }
    private var canOpen: Bool { model.canChangeFiles && !model.locked(side) }

    var body: some View {
        HStack(spacing: 4) {
            RecentPathField(path: pane.url?.path ?? "", paths: library.recentTextPaths,
                            label: sideName + L(" file path", "文件路径"), enabled: canOpen,
                            focus: { model.focus(side) }, open: { value in
                model.focus(side)
                await model.openPath(value, on: side)
                return model.pane(side).url?.path ?? ""
            })
            .id(ObjectIdentifier(pane))
            .controlSize(.regular)
            .frame(maxWidth: .infinity, minHeight: 24)
            if model.locked(side) {
                Image(systemName: "lock.fill").foregroundStyle(TandemDiffStyle.accent)
                    .help(L("Editing locked", "编辑已锁定")).accessibilityLabel(L("Editing locked", "编辑已锁定"))
            }
            if pane.buffer.isDirty {
                Circle().fill(TandemDiffStyle.marker).frame(width: 6, height: 6)
                    .help(L("Unsaved", "未保存")).accessibilityLabel(L("Unsaved", "未保存"))
            }
            Button { model.focus(side); Task { await model.chooseFile(side) } } label: {
                BrowsePathIcon()
            }
            .accessibilityLabel(sideName + L(" browse files", "浏览文件")).help(L("Browse files", "浏览文件") + " (⌘O)")
            .disabled(!canOpen)
            Button { model.focus(side); Task { await model.save(side) } } label: {
                TextSaveIcon().frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L("Save ", "保存") + model.label(side))
            .help((pane.url == nil ? L("Choose where to save this text", "选择位置并保存文本") : L("Save changes to this file", "将更改保存到原文件")) + " (⌘S)")
            .disabled(!model.editable(side) || !model.composing.isEmpty)
        }
        .font(.system(size: 14, weight: .medium)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 7).frame(height: 35)
    }
}

struct BrowsePathIcon: View {
    var body: some View {
        ZStack {
            TextCommandIcon(symbol: "folder.fill", ink: TandemDiffStyle.accent.opacity(0.35))
            TextCommandIcon(symbol: "folder", ink: TandemDiffStyle.accent)
        }.frame(width: 24, height: 24)
    }
}

struct RecentPathField: NSViewRepresentable {
    let path: String
    let paths: [String]
    let label: String
    let enabled: Bool
    var kind: SessionRecord.Kind = .text
    var focus: () -> Void = {}
    let open: (String) async -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class ComboBox: NSComboBox {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }
    }

    func makeNSView(context: Context) -> ComboBox {
        let combo = ComboBox()
        combo.font = .systemFont(ofSize: 12)
        combo.numberOfVisibleItems = 10
        combo.completes = false
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        combo.delegate = context.coordinator
        combo.target = context.coordinator
        combo.action = #selector(Coordinator.submit(_:))
        (combo.cell as? NSComboBoxCell)?.sendsActionOnEndEditing = false
        combo.stringValue = path
        return combo
    }

    func updateNSView(_ combo: ComboBox, context: Context) {
        let previous = context.coordinator.field
        context.coordinator.field = self
        combo.onFocus = focus
        combo.placeholderString = kind == .folders ? label : L("Enter file name or path", "输入文件名或路径")
        combo.toolTip = kind == .folders
            ? L("Enter a path or choose a recent folder", "输入路径或从下拉列表选择最近文件夹")
            : L("Enter a path or choose a recent text file", "输入路径或从下拉列表选择最近文件")
        combo.setAccessibilityLabel(label)
        if combo.numberOfItems != paths.count || !previous.paths.elementsEqual(paths, by: { $0.utf8.elementsEqual($1.utf8) }) {
            let draft = combo.stringValue
            combo.removeAllItems()
            combo.addItems(withObjectValues: paths)
            combo.stringValue = draft
        }
        if !previous.path.utf8.elementsEqual(path.utf8) { combo.stringValue = path }
        combo.isEnabled = enabled
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var field: RecentPathField
        private var opening = false
        init(_ field: RecentPathField) { self.field = field }

        func comboBoxWillPopUp(_ notification: Notification) { field.focus() }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox,
                  let selected = combo.objectValueOfSelectedItem as? String else { return }
            open(selected, from: combo, picked: true)
        }

        @objc func submit(_ combo: NSComboBox) {
            open(combo.stringValue, from: combo, picked: false)
        }

        private func open(_ value: String, from combo: NSComboBox, picked: Bool) {
            guard !opening, !value.utf8.elementsEqual(field.path.utf8) else { return }
            guard !value.isEmpty else {
                if field.kind == .folders { combo.stringValue = field.path }
                return
            }
            opening = true
            Task {
                defer { opening = false }
                let actual = await field.open(value)
                if (picked || field.kind == .folders) && !actual.utf8.elementsEqual(value.utf8) && combo.stringValue.utf8.elementsEqual(value.utf8) {
                    if combo.indexOfSelectedItem >= 0 { combo.deselectItem(at: combo.indexOfSelectedItem) }
                    combo.stringValue = actual
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let combo = control as? NSComboBox else { return false }
            combo.abortEditing()
            combo.stringValue = field.path
            return true
        }
    }
}

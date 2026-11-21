import SwiftUI
import TandemDiffCore

struct NameFilterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NameRules
    let apply: (NameRules) -> Void

    init(rules: NameRules, apply: @escaping (NameRules) -> Void) {
        _draft = State(initialValue: rules)
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Name Filters", "名称筛选")).font(.title2.weight(.semibold))
                Text(L("Enter one pattern per line. Empty include fields match all names of that type. Exclusions take precedence.", "每行一条规则。包含条件留空时，匹配该类型的全部名称。排除规则优先。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                field(L("Exclude files", "排除文件"), example: "*.log", text: $draft.excludeFiles)
                field(L("Exclude folders", "排除文件夹"), example: "build", text: $draft.excludeDirectories)
                Divider()
                field(L("Include files", "包含文件"), example: "*.swift", text: $draft.includeFiles)
                field(L("Include folders", "包含文件夹"), example: "Sources", text: $draft.includeDirectories)
            }
            Divider()
            HStack {
                Button(L("Clear All", "全部清除")) { draft = NameRules() }
                    .disabled(draft == NameRules())
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Apply", "应用")) {
                    apply(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help(L("Apply name filters", "应用名称筛选") + " (⌘↩)")
            }
        }
        .padding(24)
        .frame(width: 510)
        .tint(TandemDiffStyle.accent)
    }

    private func field(_ label: String, example: String, text: Binding<String>) -> some View {
        let hint = L("e.g. " + example, "例如 " + example)
        return GridRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.callout.weight(.medium))
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 50)
                .background(TandemDiffStyle.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(TandemDiffStyle.border).allowsHitTesting(false) }
                .accessibilityLabel(label)
                .accessibilityHint(hint)
        }
    }
}

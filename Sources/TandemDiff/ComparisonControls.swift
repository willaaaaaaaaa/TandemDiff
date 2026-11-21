import AppKit
import SwiftUI
import TandemDiffCore

enum ComparisonDisplay: CaseIterable {
    case all, differences, same

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .differences: L("Differences", "差异")
        case .same: L("Same", "相同")
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .all: "1"
        case .differences: "2"
        case .same: "3"
        }
    }
}

extension FolderSession {
    var comparisonDisplay: ComparisonDisplay? {
        get {
            switch filter {
            case .all: .all
            case .changes: .differences
            case .identical: .same
            case .leftOnly, .rightOnly, .skipped: nil
            }
        }
        set {
            switch newValue {
            case .all: filter = .all
            case .differences: filter = .changes
            case .same: filter = .identical
            case nil: break
            }
        }
    }

    var canNavigateDifferences: Bool { !copying && rows.contains { $0.entry.state.isDifference } }
    var canRefreshComparison: Bool { left != nil && right != nil && !scanning && !preparing && !copying }
}

extension TextSessionModel {
    var comparisonDisplay: ComparisonDisplay? {
        get {
            switch settings.mode {
            case .all: .all
            case .changes: .differences
            case .equal: .same
            case .context: nil
            }
        }
        set {
            guard let newValue else { return }
            updateSettings {
                switch newValue {
                case .all: $0.mode = .all
                case .differences: $0.mode = .changes
                case .same: $0.mode = .equal
                }
            }
        }
    }

    var canNavigateDifferences: Bool { !hunks.isEmpty && composing.isEmpty }
    var canRefreshComparison: Bool {
        !aligning && composing.isEmpty && TextSide.allCases.allSatisfy { !pane($0).busy && pane($0).error == nil }
    }
    func canApplyChange(from side: TextSide) -> Bool {
        canTransfer && currentHunk != nil && editable(side.other)
    }
}

struct ComparisonToolDivider: View {
    var body: some View { Divider().frame(height: 25).padding(.horizontal, 2) }
}

struct ComparisonToolLabel: View {
    let title: String
    let symbol: String
    let ink: Color
    var selected = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(spacing: 3) {
            TextCommandIcon(symbol: symbol, ink: ink).font(.system(size: 15, weight: .semibold)).frame(height: 18)
            Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(enabled ? (selected ? TandemDiffStyle.accent : Color.primary) : Color(nsColor: .disabledControlTextColor))
        }
        .padding(.horizontal, 5).frame(minWidth: 41, minHeight: 39)
        .background(selected ? TandemDiffStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct ComparisonToolButton: View {
    let title: String
    let symbol: String
    let ink: Color
    let selected: Bool
    let help: String
    let action: () -> Void

    init(_ title: String, _ symbol: String, ink: Color, selected: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.ink = ink
        self.selected = selected
        self.help = help ?? title
        self.action = action
    }

    var body: some View {
        Button(action: action) { ComparisonToolLabel(title: title, symbol: symbol, ink: ink, selected: selected) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ComparisonToolMenu<Content: View>: View {
    let title: String
    let symbol: String
    let ink: Color
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            ComparisonToolLabel(title: title, symbol: symbol, ink: ink)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title).help(help)
    }
}

struct ComparisonSessionControls<Commands: View>: View {
    let workspace: Workspace
    @ViewBuilder let commands: () -> Commands

    var body: some View {
        ComparisonToolButton(L("Home", "主页"), "house.fill", ink: TandemDiffStyle.accent, help: L("Return to Home", "返回主页")) { workspace.active = nil }
        ComparisonToolMenu(title: L("Session", "会话"), symbol: "briefcase.fill", ink: TandemDiffStyle.accent, help: L("Session commands", "会话命令")) {
            SessionMenuItems(workspace: workspace)
            Divider()
            commands()
        }
    }
}

struct ComparisonViewControls<More: View>: View {
    @Binding var mode: ComparisonDisplay?
    @ViewBuilder let more: () -> More

    var body: some View {
        ForEach(ComparisonDisplay.allCases, id: \.self) { choice in
            let symbol = choice == .all ? "asterisk" : choice == .differences ? "notequal" : "equal"
            ComparisonToolButton(choice.title, symbol, ink: choice == .differences ? TextCommandInk.red : .primary,
                                 selected: mode == choice, help: choice.title + " (⌘" + String(choice.shortcut.character) + ")") {
                mode = choice
            }
            if choice == .differences { more() }
        }
    }
}

struct ComparisonNavigationControls: View {
    let previous: () -> Void
    let next: () -> Void
    let disabled: Bool

    var body: some View {
        Group {
            ComparisonToolButton(L("Previous", "上一处"), "arrowshape.up.fill", ink: TandemDiffStyle.accent, help: L("Previous difference", "上一处差异") + " (⌘⌥↑)", action: previous)
            ComparisonToolButton(L("Next", "下一处"), "arrowshape.down.fill", ink: TandemDiffStyle.accent, help: L("Next difference", "下一处差异") + " (⌘⌥↓)", action: next)
        }
        .disabled(disabled)
    }
}

// Handle the alternate keys only in the comparison window that received them.
struct ComparisonNavigationKeys: NSViewRepresentable {
    let disabled: Bool
    let previous: () -> Void
    let next: () -> Void

    var handlesFieldClipboard = false
    var escape: ((_ editingField: Bool) -> Bool)?

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        var monitor: Any?
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let view, let window = view.window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil, !view.isHiddenOrHasHiddenAncestor,
                  view.handle?(event) == true else { return event }
            return nil
        }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = { event in
            handle(event, responder: event.window?.firstResponder, voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
        }
    }

    func handle(_ event: NSEvent, responder: NSResponder?, voiceOver: @autoclosure () -> Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if event.keyCode == 53, modifiers.isEmpty, !event.isARepeat, let escape {
            let editor = responder as? NSTextView
            guard editor?.hasMarkedText() != true else { return false }
            return escape(editor?.isFieldEditor == true)
        }
        if handlesFieldClipboard, modifiers == .control, let field = responder as? NSTextView, field.isFieldEditor, !field.hasMarkedText() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": field.copy(nil); return true
            case "v": if field.isEditable { field.pasteAsPlainText(nil) }; return true
            default: break
            }
        }
        guard !disabled, modifiers == [.control, .option],
              !voiceOver() else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor || editor.hasMarkedText() {
            return false
        }
        switch event.specialKey {
        case .upArrow: previous()
        case .downArrow: next()
        default: return false
        }
        return true
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
    }
}

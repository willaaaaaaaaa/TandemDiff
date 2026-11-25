import AppKit
import TandemDiffCore
import SwiftUI

/// Both the pointer menu and the accessibility menu use the same commands.
@MainActor
struct FolderContextMenu {
    struct Item {
        let title: String
        let enabled: Bool
        let perform: () -> Void

        init(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) {
            self.title = title
            self.enabled = enabled
            self.perform = perform
        }
    }

    let groups: [[Item]]

    init(session: FolderSession, ids: Set<Data>, side: TextSide?, compare: @escaping (Set<Data>) -> Void) {
        let entries = session.rows.compactMap { ids.contains($0.id) ? $0.entry : nil }
        guard !entries.isEmpty, entries.count == ids.count else { groups = []; return }
        let allVisible = session.isAllVisibleSelection(count: entries.count)
        let ready = session.complete && !session.copying
        let individualSides = session.selectedSides
        let pair = ids == session.selection ? session.selectedPair : nil
        var open: [Item] = []
        if pair?.canCompareText == true {
            open.append(Item(L("Compare Selected Files", "比较所选文件"), enabled: session.openableTextPair != nil) { session.openSelectedPair() })
        }
        open.append(Item(L("Compare Contents", "比较内容"), enabled: ready && !session.preparing) { compare(ids) })
        if individualSides.isEmpty && !allVisible && entries.allSatisfy(\.canOpenAsText) {
            open.append(Item(L("Open in Text Compare", "在文本比较中打开"), enabled: ready) { session.openItems(ids: ids) })
        }
        if session.structure != .flatList, entries.contains(where: { !$0.children.isEmpty }) {
            open.append(Item(L("Expand Subtrees", "展开子目录树"), enabled: !session.copying) {
                session.setDirectoriesExpanded(true, all: false, selectedIDs: ids)
            })
            open.append(Item(L("Collapse Subtrees", "收起子目录树"), enabled: !session.copying) {
                session.setDirectoriesExpanded(false, all: false, selectedIDs: ids)
            })
        }
        if allVisible { groups = [open]; return }

        var roots: [Item] = []
        var paths: [Item] = []
        if pair?.canUseAsRoots == true {
            roots.append(Item(L("Set as Base Folders on Both Sides", "将两侧目录设为基点文件夹"), enabled: ready) { session.useSelectedFoldersAsRoots() })
        }
        let menuSide = individualSides.isEmpty ? side : nil
        for target in menuSide.map({ [$0] }) ?? TextSide.allCases {
            let selected = individualSides.isEmpty ? entries : entries.filter { individualSides[$0.id]?.includes(target) == true }
            if selected.count == 1, let entry = selected.first, entry.canBeBaseFolder(on: target) {
                let title = menuSide != nil ? L("Set as Base Folder", "设为基点文件夹") :
                    (target == .left ? L("Set as Left Base Folder", "设为左侧基点文件夹") : L("Set as Right Base Folder", "设为右侧基点文件夹"))
                roots.append(Item(title, enabled: ready) { session.useAsRoots(entry, side: target) })
            }

            let urls = selected.compactMap { $0.url(on: target) }
            guard !urls.isEmpty else { continue }
            let reveal = menuSide != nil ? L("Reveal in Finder", "在访达中显示") :
                (target == .left ? L("Reveal Left in Finder", "在访达中显示左侧项目") : L("Reveal Right in Finder", "在访达中显示右侧项目"))
            paths.append(Item(reveal) { NSWorkspace.shared.activateFileViewerSelecting(urls) })
            let copyPaths = menuSide != nil ? L("Copy Paths", "复制路径") :
                (target == .left ? L("Copy Left Paths", "复制左侧路径") : L("Copy Right Paths", "复制右侧路径"))
            paths.append(Item(copyPaths) { Self.copy(urls.map(\.path)) })
        }
        if individualSides.isEmpty, entries.count == 1, let entry = entries.first, entry.canBeBaseFolder(on: nil) {
            roots.append(Item(L("Set as Base Folders on Both Sides", "将两侧目录设为基点文件夹"), enabled: ready) { session.useAsRoots(entry) })
        }
        paths.append(Item(L("Copy Names", "复制名称")) {
            Self.copy(entries.map { ($0.path as NSString).lastPathComponent })
        })

        var copies: [Item] = []
        if entries.contains(where: { $0.left != nil && (individualSides.isEmpty || individualSides[$0.id]?.includes(.left) == true) }) {
            copies.append(Item(CopyDirection.right.label, enabled: session.canPreview(.right, ids: ids)) { session.prepare(.right, selectedIDs: ids) })
        }
        if entries.contains(where: { $0.right != nil && (individualSides.isEmpty || individualSides[$0.id]?.includes(.right) == true) }) {
            copies.append(Item(CopyDirection.left.label, enabled: session.canPreview(.left, ids: ids)) { session.prepare(.left, selectedIDs: ids) })
        }
        groups = [open, roots, paths, copies].filter { !$0.isEmpty }
    }

    private static func copy(_ values: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    @ViewBuilder var buttons: some View {
        ForEach(groups.indices, id: \.self) { group in
            if group > 0 { Divider() }
            ForEach(groups[group], id: \.title) { item in
                Button(item.title, action: item.perform).disabled(!item.enabled)
            }
        }
    }

    func nativeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in group { menu.addItem(ActionMenuItem(item)) }
        }
        return menu
    }

    private final class ActionMenuItem: NSMenuItem {
        let performAction: () -> Void

        init(_ item: Item) {
            performAction = item.perform
            super.init(title: item.title, action: #selector(invoke), keyEquivalent: "")
            target = self
            isEnabled = item.enabled
        }

        required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        @objc private func invoke() { performAction() }
    }
}

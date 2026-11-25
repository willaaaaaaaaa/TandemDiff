import Foundation
import TandemDiffCore

extension FolderEntry {
    func url(on side: TextSide) -> URL? { side == .left ? left : right }

    func canBeBaseFolder(on side: TextSide?) -> Bool {
        guard isDirectory, state != .excluded, state != .conflict else { return false }
        switch side {
        case .left: return left != nil && leftVersion?.isFolder == true
        case .right: return right != nil && rightVersion?.isFolder == true
        case nil: return canBeBaseFolder(on: .left) && canBeBaseFolder(on: .right)
        }
    }

    var canOpenAsText: Bool {
        !isDirectory && state != .error && state != .pending && state != .conflict &&
            (leftText != nil || rightText != nil) && (left == nil || leftText != nil) && (right == nil || rightText != nil)
    }
}

struct FolderSelectionPair {
    let left: FolderEntry
    let right: FolderEntry

    var canCompareText: Bool {
        left.leftText != nil && right.rightText != nil
    }

    var canUseAsRoots: Bool { left.canBeBaseFolder(on: .left) && right.canBeBaseFolder(on: .right) }
}

struct FolderActivity: Identifiable {
    let id = UUID()
    let time = Date()
    let diagnostic: DiagnosticText
    var message: String { diagnostic.localized }
}

extension FolderSession {
    func isAllVisibleSelection(count: Int) -> Bool {
        selectedSides.isEmpty && count > 0 && count == rows.count && (count > 1 || explicitSelectAll)
    }

    var openableTextPair: FolderSelectionPair? {
        guard !copying, complete || scanning, let pair = selectedPair, pair.canCompareText else { return nil }
        return pair
    }

    func canOpenSelected(includingFolders: Bool) -> Bool {
        if openableTextPair != nil { return true }
        guard complete, !copying else { return false }
        guard selection.count == 1, let id = selection.first,
              let entry = rows.first(where: { $0.id == id })?.entry else { return false }
        return entry.canOpenAsText || (includingFolders && !entry.children.isEmpty)
    }

    enum FileSelection {
        case orphans(TextSide)
        case newer(TextSide)

        func matches(_ row: FolderRow) -> Bool {
            let entry = row.entry
            guard !entry.isDirectory else { return false }
            switch self {
            case .orphans(let side):
                return side == .left ? entry.left != nil && entry.right == nil : entry.right != nil && entry.left == nil
            case .newer(let side):
                guard let left = entry.leftVersion?.modified, let right = entry.rightVersion?.modified else { return false }
                return side == .left ? left > right : right > left
            }
        }
    }

    func selectVisibleFiles(matching criterion: FileSelection) {
        guard !copying else { return }
        switch criterion {
        case .orphans(let side), .newer(let side): selectionScope = FolderSelectionScope(side: side)
        }
        selection = Set(rows.lazy.filter(criterion.matches).map(\.id))
    }

    func findFilename(backward: Bool) {
        guard !copying, !findQuery.isEmpty else { return }
        let candidates = projectedRows(expandAll: true)
        let step = backward ? -1 : 1
        let start = candidates.firstIndex { selection.contains($0.id) } ?? (backward ? candidates.count : -1)
        for offset in candidates.indices {
            let index = (start + step * (offset + 1) + candidates.count) % candidates.count
            let row = candidates[index]
            let name = row.entry.path.split(separator: "/").last.map(String.init) ?? ""
            guard name.localizedCaseInsensitiveContains(findQuery) else { continue }
            if structure != .flatList {
                var ancestors = Set<Data>()
                var path = row.entry.path[...]
                while let slash = path.lastIndex(of: "/") {
                    path = path[..<slash]
                    ancestors.insert(Data(path.utf8))
                }
                expanded.formUnion(ancestors)
            }
            selection = [row.id]
            findMiss = false
            return
        }
        findMiss = true
    }
}

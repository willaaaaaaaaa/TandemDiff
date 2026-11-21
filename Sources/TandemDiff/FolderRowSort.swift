import Foundation
import TandemDiffCore

extension FileVersion {
    var isFolder: Bool { mode & S_IFMT == S_IFDIR }
    var fileSize: Int64? { isFolder ? nil : size }
}

struct FolderRowSort: SortComparator {
    enum Column { case leftName, leftSize, leftModified, rightName, rightSize, rightModified }

    let column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: FolderRow, _ rhs: FolderRow) -> ComparisonResult {
        compareEntries(lhs.entry, rhs.entry)
    }

    func compareEntries(_ lhs: FolderEntry, _ rhs: FolderEntry) -> ComparisonResult {
        let onLeft = column == .leftName || column == .leftSize || column == .leftModified
        let a = onLeft ? lhs.leftVersion : lhs.rightVersion
        let b = onLeft ? rhs.leftVersion : rhs.rightVersion
        switch column {
        case .leftName, .rightName:
            let aName = (onLeft ? lhs.left : lhs.right) == nil ? nil : lhs.path
            let bName = (onLeft ? rhs.left : rhs.right) == nil ? nil : rhs.path
            return compare(aName, bName, using: String.StandardComparator.localizedStandard)
        case .leftSize, .rightSize:
            return compare(a?.fileSize, b?.fileSize, using: ComparableComparator<Int64>())
        case .leftModified, .rightModified:
            return compare(a?.modified, b?.modified, using: ComparableComparator<Date>())
        }
    }

    private func compare<C: SortComparator>(_ lhs: C.Compared?, _ rhs: C.Compared?, using comparator: C) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (a?, b?): order == .forward ? comparator.compare(a, b) : comparator.compare(b, a)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        }
    }
}

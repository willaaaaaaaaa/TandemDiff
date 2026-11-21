import SwiftUI
import TandemDiffCore

enum FolderComparisonColor {
    case normal, different, newer, older, oneSided
    private static let defaultInk = TandemDiffStyle.adaptive(light: 0x000000, dark: 0xF2F2F2)
    private static let differenceInk = TandemDiffStyle.adaptive(light: 0xFF0000, dark: 0xFF8585)
    private static let olderInk = TandemDiffStyle.adaptive(light: 0x808080, dark: 0xB2B5BB)

    init(_ entry: FolderEntry, onLeft: Bool) {
        switch entry.state {
        case .leftOnly, .rightOnly: self = .oneSided
        case .conflict: self = .different
        case .different:
            guard !entry.isDirectory, let left = entry.leftVersion?.modified,
                  let right = entry.rightVersion?.modified, left != right else {
                self = .different
                return
            }
            self = (left > right) == onLeft ? .newer : .older
        default: self = .normal
        }
    }

    var ink: Color {
        switch self {
        case .normal, .oneSided: Self.defaultInk
        case .different, .newer: Self.differenceInk
        case .older: Self.olderInk
        }
    }
}

import SwiftUI

enum HomeSelection: Hashable {
    case tool(HomeTool)
    case record(UUID)
    case folder(UUID)
}

enum HomeTool: CaseIterable, Identifiable {
    case folderCompare, textCompare

    var id: Self { self }
    static let sidebarTools = allCases

    init(_ kind: SessionRecord.Kind) {
        self = kind == .folders ? .folderCompare : .textCompare
    }

    var kind: SessionRecord.Kind {
        switch self {
        case .folderCompare: .folders
        case .textCompare: .text
        }
    }

    var title: String {
        switch self {
        case .folderCompare: L("Folder Compare", "文件夹比较")
        case .textCompare: L("Text Compare", "文本比较")
        }
    }

    var detail: String {
        switch self {
        case .folderCompare: L("Compare two directory trees and copy selected changes.", "并排查看两棵目录树，按需复制有差异的文件。")
        case .textCompare: L("Compare two texts line by line and edit either side.", "逐行对照两份文本，在任意一侧编辑差异。")
        }
    }
}

extension Workspace {
    func launch(_ tool: HomeTool) {
        switch tool {
        case .folderCompare: makeFolders()
        case .textCompare: makeText()
        }
    }
}

enum HomePanel: String {
    case automatic, pinned, expanded, hidden
}

private struct HomePanelKey: FocusedValueKey {
    typealias Value = Binding<HomePanel>
}

extension FocusedValues {
    var homePanel: Binding<HomePanel>? {
        get { self[HomePanelKey.self] }
        set { self[HomePanelKey.self] = newValue }
    }
}

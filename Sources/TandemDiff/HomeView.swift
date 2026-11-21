import SwiftUI

/// Session names acquire parent components only when two comparison titles coincide.
struct SessionTitles {
    private let titles: [UUID: String]

    private struct Comparison {
        let id: UUID
        let paths: [[String]]

        init(_ record: SessionRecord) {
            id = record.id
            paths = [record.left, record.right].compactMap { $0 }.map { ($0.path as NSString).pathComponents }
        }

        func title(depth: Int) -> String {
            let labels = paths.map { NSString.path(withComponents: Array($0.suffix(depth))) }
            if labels.count == 2 && labels[0] == labels[1] { return labels[0] }
            return labels.joined(separator: " <--> ")
        }
    }

    init(records: [SessionRecord]) {
        var titles: [UUID: String] = [:]
        func assign(_ comparisons: [Comparison], name: String?, depth: Int) {
            for (pair, matches) in Dictionary(grouping: comparisons, by: { $0.title(depth: depth) }) {
                if matches.count > 1 && Set(matches.map { $0.title(depth: .max) }).count > 1 {
                    assign(matches, name: name, depth: depth + 1)
                    continue
                }
                let title = [name, pair.isEmpty ? nil : pair].compactMap { $0 }.joined(separator: " · ")
                if matches.count == 1 {
                    titles[matches[0].id] = title
                } else {
                    let ids = matches.map(\.id).sorted { $0.uuidString < $1.uuidString }
                    for (index, id) in ids.enumerated() {
                        titles[id] = "\(title) (\(index + 1))"
                    }
                }
            }
        }
        for (name, group) in Dictionary(grouping: records, by: \.name) {
            if let name, group.count == 1 {
                titles[group[0].id] = name
            } else {
                assign(group.map(Comparison.init), name: name, depth: 1)
            }
        }
        self.titles = titles
    }

    func title(_ record: SessionRecord) -> String {
        titles[record.id] ?? record.name ?? ""
    }
}

enum RecentDay: CaseIterable {
    case today, yesterday, earlier

    var title: String {
        switch self {
        case .today: L("Today", "今天")
        case .yesterday: L("Yesterday", "昨天")
        case .earlier: L("Earlier", "更早")
        }
    }

    init(_ timestamp: Date, now: Date, calendar: Calendar = .current) {
        if calendar.isDate(timestamp, inSameDayAs: now) {
            self = .today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(timestamp, inSameDayAs: yesterday) {
            self = .yesterday
        } else {
            self = .earlier
        }
    }
}

struct HomeView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var library: SessionLibrary
    @Binding var selection: Set<HomeSelection>
    @SceneStorage("home.managementPanel") private var panel = HomePanel.automatic
    @Binding var collapsedDays: Set<RecentDay>
    @State private var dropTarget = false
    @State private var sheet: HomeSheet?

    private enum HomeSheet: Identifiable {
        case edit(SessionRecord), defaults(HomeTool)
        var id: HomeSelection {
            switch self {
            case .edit(let record): .record(record.id)
            case .defaults(let tool): .tool(tool)
            }
        }
    }

    var body: some View {
        HSplitView {
            HomeSidebar(workspace: workspace, library: library, selection: $selection, collapsedDays: $collapsedDays, launch: workspace.launch, edit: { sheet = .edit($0) }, editDefaults: { sheet = .defaults(HomeTool($0)) })
                .frame(minWidth: 210, idealWidth: 254, maxWidth: 330)
            GeometryReader { area in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if panel != .hidden { selectionDetail }
                        if panel != .expanded { launchers }
                    }
                    .frame(maxWidth: 670)
                    .padding(.horizontal, area.size.width < 630 ? 24 : 42)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: panel == .expanded ? .top : .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(TandemDiffStyle.canvas)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                workspace.accept(urls)
                return true
            } isTargeted: { dropTarget = $0 }
            .overlay {
                if dropTarget {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(TandemDiffStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
        .focusedSceneValue(\.homePanel, $panel)
        .sheet(item: $sheet) { item in
            switch item {
            case .edit(let record): HomeSessionEditor(record: record, library: library)
            case .defaults(let tool): HomeDefaultsEditor(kind: tool.kind, defaults: workspace.sessionDefaults)
            }
        }
    }

    @ViewBuilder private var launchers: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("New comparison", "新建比较"))
                .font(.system(size: 30, weight: .semibold))
            Text(L("Drop files or folders onto a tool, or choose one to begin.", "将文件或文件夹拖到对应图标上，也可以点击开始。"))
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 14) {
            ForEach(HomeTool.allCases) { tool in
                HomeLauncher(tool: tool, launch: { workspace.launch(tool) }, accept: { workspace.accept($0, for: tool.kind) })
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var selectionDetail: some View {
        switch selection.count == 1 ? selection.first : nil {
        case .tool(let tool):
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(tool.title).font(.headline)
                } icon: {
                    SessionArtwork(tool: tool, compact: true).frame(width: 22, height: 22)
                }
                HStack {
                    Button(L("Open", "打开")) { workspace.launch(tool) }
                    Button(L("Edit defaults…", "编辑默认设置…")) { sheet = .defaults(tool) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        case .record(let id):
            if let record = library.records.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SessionArtwork(tool: HomeTool(record.kind), compact: true).frame(width: 22, height: 22)
                        Text(SessionTitles(records: library.records).title(record)).font(.headline)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        pathRow(L("Left", "左侧"), path: record.left?.path)
                        pathRow(L("Right", "右侧"), path: record.right?.path)
                    }
                    if let notes = record.notes, !notes.isEmpty {
                        Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack {
                        Button(L("Open", "打开")) { workspace.open(record) }
                        Button(record.name == nil ? L("Save Session As…", "会话另存为…") : L("Edit…", "编辑…")) {
                            sheet = .edit(record)
                        }
                        .disabled(record.locked == true)
                        if record.locked == true {
                            Label(L("Locked", "已锁定"), systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }
        case .folder(let id):
            if let folder = library.folders.first(where: { $0.id == id }) {
                Label(folder.name, systemImage: "folder").font(.headline)
                Text(library.folderPath(id)).font(.callout).foregroundStyle(.secondary)
                Divider()
            }
        case nil:
            if selection.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("\(selection.count) items selected", "已选择 \(selection.count) 项")).font(.headline)
                    let records = Set(selection.compactMap { item -> UUID? in
                        if case .record(let id) = item { return id }
                        return nil
                    })
                    if records.count == selection.count {
                        Button(L("Open selected sessions", "打开所选会话")) { workspace.openSessions(records) }
                    }
                }
                Divider()
            } else if panel == .pinned || panel == .expanded {
                Text(L("Select a session to inspect its settings.", "选择左栏中的会话即可查看设置。"))
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
            }
        }
    }

    private func pathRow(_ title: String, path: String?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(path ?? L("No path", "未设置路径")).font(.callout)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HomeLauncher: View {
    let tool: HomeTool
    let launch: () -> Void
    let accept: ([URL]) -> Void
    @State private var hovered = false
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: launch) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    SessionArtwork(tool: tool).frame(width: 108, height: 96)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovered || targeted ? TandemDiffStyle.accent : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(TandemDiffStyle.canvas, in: Circle())
                }
                .padding(.bottom, 16)
                Text(tool.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.primary)
                Text(tool.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 204, alignment: .leading)
            .background(TandemDiffStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(hovered || targeted ? TandemDiffStyle.accent : TandemDiffStyle.border, lineWidth: targeted ? 2 : 1)
            }
            .shadow(color: .black.opacity(hovered ? 0.10 : 0.045), radius: hovered ? 7 : 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            accept(urls)
            return true
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.detail)
    }
}

import SwiftUI

struct HomeSidebar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var library: SessionLibrary
    @Binding var selection: Set<HomeSelection>
    @Binding var collapsedDays: Set<RecentDay>
    let launch: (HomeTool) -> Void
    let edit: (SessionRecord) -> Void
    let editDefaults: (SessionRecord.Kind) -> Void

    @SceneStorage("home.expandedNew") private var newExpanded = true
    @SceneStorage("home.expandedSaved") private var savedExpanded = true
    @SceneStorage("home.expandedRecent") private var recentExpanded = true
    @State private var collapsedFolders: Set<UUID> = []
    @SceneStorage("home.sessionSearch") private var search = ""
    @State private var folderDraft: SessionFolder?
    @State private var removal: Removal?
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private enum Removal {
        case records(Set<UUID>, locked: Int), folder(UUID)
    }

    private var singleSelection: HomeSelection? { selection.count == 1 ? selection.first : nil }

    private var selectedFolder: UUID? {
        switch singleSelection {
        case .folder(let id): id
        case .record(let id): library.records.first { $0.id == id }?.folderID
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Sessions", "会话")).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 8)
            TimelineView(.everyMinute) { time in
                tree(now: time.date)
            }
            Divider()
            controls
        }
        .sheet(item: $folderDraft) { folder in
            FolderNameEditor(folder: folder, library: library) { id in
                savedExpanded = true
                if let parent = folder.parent { collapsedFolders.remove(parent) }
                search = ""
                selection = [.folder(id)]
            }
        }
        .alert(L("Remove from Sessions?", "从会话列表中移除？"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { item in
            Button(L("Remove", "移除"), role: .destructive) { remove(item) }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: { item in
            switch item {
            case .folder:
                Text(L("The sessions and folders inside will move up one level.", "其中的会话和文件夹将移至上一级。"))
            case .records(let ids, let locked):
                let message = ids.count == 1
                    ? L("One session entry will be removed. Its files stay on disk.", "将移除 1 条会话记录，磁盘上的文件会保留。")
                    : L("Remove these \(ids.count) sessions? Their files stay on disk.", "将移除 \(ids.count) 条会话记录，磁盘上的文件会保留。")
                Text(locked > 0 ? message + " " + L("Locked entries retained: \(locked).", "已锁定的 \(locked) 条会话将保留。") : message)
            }
        }
    }

    private func tree(now: Date) -> some View {
        let titles = SessionTitles(records: library.records)
        let tools = HomeTool.sidebarTools.filter { self.matches($0.title) }
        let matches = library.recordsInSidebarOrder.filter { record in
            [titles.title(record), record.name, record.notes, record.left?.path, record.right?.path, record.folderID.map(library.folderPath)].compactMap { $0 }.contains(where: self.matches)
        }
        let saved = matches.filter { $0.name != nil }
        let recents = matches.filter { $0.name == nil }
        let byDay = Dictionary(grouping: recents) { RecentDay($0.timestamp, now: now) }
        let folderIDs = visibleFolders(for: saved)
        return List(selection: $selection) {
            if query.isEmpty || !tools.isEmpty {
                Section(isExpanded: expanded($newExpanded)) {
                    ForEach(tools) { tool in
                        item(tool.title, tool: tool).tag(HomeSelection.tool(tool))
                            .accessibilityAction { launch(tool) }
                    }
                } header: { Text(L("New", "新建")) }
            }
            if query.isEmpty || !recents.isEmpty {
                Section(isExpanded: expanded($recentExpanded)) {
                    if recents.isEmpty { empty(L("No recent comparisons", "暂无最近比较")) }
                    ForEach(RecentDay.allCases, id: \.self) { day in
                        if let records = byDay[day] {
                            DisclosureGroup(isExpanded: expanded(Binding(
                                get: { !collapsedDays.contains(day) },
                                set: { value in if value { collapsedDays.remove(day) } else { collapsedDays.insert(day) } }
                            ))) {
                                ForEach(records) { row($0, titles: titles) }
                            } label: { Text(day.title).font(.callout) }
                        }
                    }
                } header: { Text(L("Auto-saved", "自动保存")) }
            }
            if query.isEmpty || !saved.isEmpty || !folderIDs.isEmpty {
                Section(isExpanded: expanded($savedExpanded)) {
                    if saved.isEmpty && folderIDs.isEmpty { empty(L("No saved sessions", "暂无已保存的会话")) }
                    branch(parent: nil, saved: saved, titles: titles, folderIDs: folderIDs)
                } header: { Text(L("Saved Sessions", "已保存的会话")) }
            }
            if !query.isEmpty && tools.isEmpty && matches.isEmpty && folderIDs.isEmpty {
                empty(L("No matching sessions", "没有匹配的会话"))
            }
            if let notice = library.notice { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).selectionDisabled() }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 23)
        .contextMenu(forSelectionType: HomeSelection.self) { values in
            if values.count == 1, let only = values.first { contextActions(only) }
            else if let ids = recordIDs(values) {
                Button(L("Open Selected Sessions", "打开所选会话")) { workspace.openSessions(ids) }
                Button(L("Remove Selected Sessions…", "移除所选会话…")) { removal = removalTarget(values) }
                    .disabled(removalTarget(values) == nil)
            }
        } primaryAction: { values in
            activate(values)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            activate(selection)
            return .handled
        }
        .onDeleteCommand { removal = removalTarget(selection) }
        .onChange(of: search) { _, _ in
            let visible = Set(tools.map(HomeSelection.tool) + matches.map { .record($0.id) } + folderIDs.map(HomeSelection.folder))
            selection.formIntersection(visible)
        }
    }

    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedStandardContains(query) }

    private func expanded(_ binding: Binding<Bool>) -> Binding<Bool> {
        query.isEmpty ? binding : .constant(true)
    }

    private func visibleFolders(for records: [SessionRecord]) -> Set<UUID> {
        guard !query.isEmpty else { return Set(library.folders.map(\.id)) }
        let folders = library.folders
        let matching = folders.filter { matches(library.folderPath($0.id)) }.map(\.id)
        var result: Set<UUID> = []
        for id in matching + records.compactMap(\.folderID) {
            var current: UUID? = id
            while let id = current, result.insert(id).inserted { current = folders.first { $0.id == id }?.parent }
        }
        return result
    }

    private func branch(parent: UUID?, saved: [SessionRecord], titles: SessionTitles, folderIDs: Set<UUID>) -> AnyView {
        let folders = library.childFolders(of: parent).filter { folderIDs.contains($0.id) }
        return AnyView(Group {
            ForEach(folders) { folder in
                DisclosureGroup(isExpanded: expanded(Binding(
                    get: { !collapsedFolders.contains(folder.id) },
                    set: { value in if value { collapsedFolders.remove(folder.id) } else { collapsedFolders.insert(folder.id) } }
                ))) {
                    branch(parent: folder.id, saved: saved, titles: titles, folderIDs: folderIDs)
                } label: {
                    Label(folder.name, systemImage: "folder").font(.callout)
                }
                .tag(HomeSelection.folder(folder.id))
            }
            ForEach(saved.filter { $0.folderID == parent }) { row($0, titles: titles) }
        })
    }

    private func row(_ record: SessionRecord, titles: SessionTitles) -> some View {
        HStack(spacing: 4) {
            item(titles.title(record), tool: HomeTool(record.kind))
            if record.locked == true {
                Image(systemName: "lock.fill").font(.caption2)
                    .accessibilityLabel(L("Locked session", "会话已锁定"))
            }
        }
        .contentShape(Rectangle()).tag(HomeSelection.record(record.id))
        .help([record.name, record.left?.path, record.right?.path].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityAction { workspace.open(record) }
    }

    private func item(_ title: String, tool: HomeTool) -> some View {
        Label {
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
        } icon: {
            SessionArtwork(tool: tool, compact: true).frame(width: 17, height: 17)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).selectionDisabled()
    }

    private var controls: some View {
        HStack(spacing: 7) {
            Menu {
                Menu(L("New Saved Session", "新建已命名会话")) {
                    ForEach(HomeTool.sidebarTools) { tool in
                        Button(tool.title) { newDefinition(tool) }
                    }
                }
                Divider()
                Button(L("New Session Folder…", "新建会话文件夹…")) { newFolder(parent: selectedFolder) }
                if case .record(let id) = singleSelection, let record = library.records.first(where: { $0.id == id }) {
                    Button(L("Save Session As…", "会话另存为…")) { copy(record) }
                }
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 23)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("Add session or folder", "添加会话或文件夹"))
            Button { removal = removalTarget(selection) } label: { Image(systemName: "minus").frame(width: 21, height: 23) }
                .buttonStyle(.borderless).disabled(removalTarget(selection) == nil)
                .accessibilityLabel(L("Remove selected entry", "移除选中条目"))
            HStack(spacing: 5) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut("f", modifiers: .command).accessibilityLabel(L("Find a session", "查找会话"))
                TextField(L("Search sessions", "搜索会话"), text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onExitCommand { search = ""; searchFocused = false }
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(L("Clear search", "清除搜索"))
                }
            }
            .font(.callout).padding(.horizontal, 7).frame(height: 25)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder private func contextActions(_ selection: HomeSelection) -> some View {
        switch selection {
        case .tool(let tool):
            Button(L("Open", "打开")) { launch(tool) }
            Button(L("Edit Defaults…", "编辑默认设置…")) { editDefaults(tool.kind) }
        case .record(let id):
            if let record = library.records.first(where: { $0.id == id }) {
                Button(L("Open", "打开")) { workspace.open(record) }
                if record.name != nil {
                    Button(L("Edit Session…", "编辑会话…")) { edit(record) }.disabled(record.locked == true)
                    Button(record.locked == true ? L("Unlock Session", "解锁会话") : L("Lock Session", "锁定会话")) {
                        library.setLocked(record.locked != true, id: id)
                    }
                }
                Button(L("Save Session As…", "会话另存为…")) { copy(record) }
                Divider()
                Button(L("Remove…", "移除…")) { removal = removalTarget([selection]) }.disabled(record.locked == true)
            }
        case .folder(let id):
            if let folder = library.folders.first(where: { $0.id == id }) {
                Button(L("New Session Folder…", "新建会话文件夹…")) { newFolder(parent: id) }
                Button(L("Rename Folder…", "重命名文件夹…")) { folderDraft = folder }
                Button(L("Remove Folder…", "移除文件夹…")) { removal = .folder(id) }
            }
        }
    }

    private func newDefinition(_ tool: HomeTool) {
        var record = SessionRecord(id: UUID(), name: tool.title, kind: tool.kind, folderID: selectedFolder)
        switch tool.kind {
        case .folders:
            let defaults = workspace.sessionDefaults.folders
            record.rules = defaults.rules
            record.folderFilter = defaults.filter.rawValue
            record.folderStructure = defaults.structure?.rawValue
            record.showExcluded = defaults.showExcluded
            record.folderWriteProtected = defaults.writeProtected
        case .text:
            record.textSettings = workspace.sessionDefaults.text
        }
        edit(record)
    }

    private func newFolder(parent: UUID?) { folderDraft = SessionFolder(id: UUID(), name: "", parent: parent) }
    private func copy(_ record: SessionRecord) {
        if let name = record.name {
            var copy = record
            copy.id = UUID()
            copy.name = name + L(" copy", " 副本")
            copy.locked = nil
            edit(copy)
        } else { edit(record) }
    }

    private func recordIDs(_ items: Set<HomeSelection>) -> Set<UUID>? {
        let ids = Set(items.compactMap { item -> UUID? in
            if case .record(let id) = item { return id }
            return nil
        })
        return !ids.isEmpty && ids.count == items.count ? ids : nil
    }

    private func activate(_ items: Set<HomeSelection>) {
        if let ids = recordIDs(items) {
            workspace.openSessions(ids)
        } else if items.count == 1, let item = items.first {
            switch item {
            case .tool(let tool): launch(tool)
            case .folder(let id):
                if !collapsedFolders.insert(id).inserted { collapsedFolders.remove(id) }
            case .record: break
            }
        }
    }

    private func removalTarget(_ items: Set<HomeSelection>) -> Removal? {
        if items.count == 1, case .folder(let id) = items.first { return .folder(id) }
        guard let ids = recordIDs(items) else { return nil }
        let records = library.records.filter { ids.contains($0.id) }
        guard records.count == ids.count else { return nil }
        let unlocked = Set(records.filter { $0.locked != true }.map(\.id))
        return unlocked.isEmpty ? nil : .records(unlocked, locked: ids.count - unlocked.count)
    }

    private func remove(_ target: Removal) {
        switch target {
        case .folder(let id):
            if library.removeFolder(id) { selection.remove(.folder(id)) }
        case .records(let ids, _):
            if library.removeSessions(ids) { selection.subtract(ids.map(HomeSelection.record)) }
        }
    }
}

private struct FolderNameEditor: View {
    let folder: SessionFolder
    @ObservedObject var library: SessionLibrary
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?

    init(folder: SessionFolder, library: SessionLibrary, saved: @escaping (UUID) -> Void) {
        self.folder = folder
        self.library = library
        self.saved = saved
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(folder.name.isEmpty ? L("New Session Folder", "新建会话文件夹") : L("Rename Session Folder", "重命名会话文件夹")).font(.headline)
            TextField(L("Folder name", "文件夹名称"), text: $name)
            if let error { Text(error).font(.caption) }
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存")) {
                    var edited = folder
                    edited.name = name
                    if library.saveFolder(edited, replacing: folder.name.isEmpty ? nil : folder) {
                        saved(edited.id)
                        dismiss()
                    } else { error = library.notice }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 340)
    }
}

import AppKit
import TandemDiffCore
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct TandemDiffApp: App {
    @NSApplicationDelegateAdaptor(TandemDiffDelegate.self) private var delegate
    @StateObject private var library = SessionLibrary()
    private let registry = EditRegistry()
    @AppStorage("appAppearance") private var appearance = AppAppearance.system

    var body: some Scene {
        let language = AppLocalization.shared.language
        WindowGroup("TandemDiff") {
            WorkspaceWindow(registry: registry, library: library)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { WorkspaceCommands() }

        Settings {
            AppSettingsView()
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

@MainActor
final class TandemDiffDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = sender.windows.compactMap { $0.delegate as? WindowGuard }
        guard !windows.isEmpty else { return .terminateNow }
        Task {
            var commits: [() async -> Void] = []
            for window in windows {
                guard let commit = await window.prepareToClose() else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                commits.append(commit)
            }
            for commit in commits { await commit() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct WorkspaceWindow: View {
    @StateObject private var workspace: Workspace
    @ObservedObject private var library: SessionLibrary
    @State private var selectedSessions: Set<HomeSelection> = []
    @State private var collapsedRecentDays: Set<RecentDay> = []

    init(registry: EditRegistry, library: SessionLibrary) {
        _workspace = StateObject(wrappedValue: Workspace(registry: registry, library: library))
        _library = ObservedObject(wrappedValue: library)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let tab = workspace.current {
                detail(tab).id(tab.id)
            } else {
                home
            }
        }
        .frame(minWidth: 900, minHeight: 535)
        .tint(TandemDiffStyle.accent)
        .symbolRenderingMode(.hierarchical)
        .focusedSceneValue(\.workspace, workspace)
        .background(WindowHook(workspace: workspace).frame(width: 0, height: 0))
        .onOpenURL { workspace.accept([$0]) }
        .onChange(of: AppLocalization.shared.language) {
            for tab in workspace.tabs {
                if case .text(let model) = tab.payload { model.refreshFoldLabels() }
            }
        }
        .onReceive(workspace.registry.changes()) { event in
            guard let url = event.object as? URL else { return }
            for tab in workspace.tabs {
                if case .folders(let folder) = tab.payload { folder.diskChanged(url) }
            }
        }
        .sheet(isPresented: Binding(get: { workspace.incoming != nil }, set: {
            if !$0 { workspace.incoming = nil }
        })) {
            incomingPair
        }
        .alert(L("TandemDiff", "TandemDiff"), isPresented: Binding(get: { workspace.notice != nil }, set: {
            if !$0 { workspace.notice = nil }
        })) {
            Button(L("OK", "好")) { workspace.notice = nil }
        } message: {
            Text(workspace.notice ?? "")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 9) {
            Button { workspace.active = nil } label: {
                Label(L("Home", "主页"), systemImage: workspace.active == nil ? "house.fill" : "house")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(workspace.active == nil ? TandemDiffStyle.accent : Color.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(workspace.active == nil ? TandemDiffStyle.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(workspace.active == nil ? .isSelected : [])
            .help(L("Home", "主页"))
            .accessibilityLabel(L("Home", "主页"))
            .padding(.leading, 12)
            Divider().frame(height: 22)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        HStack(spacing: 6) {
                            Button { workspace.active = tab.id } label: {
                                Label {
                                    Text(tab.title).lineLimit(1).truncationMode(.middle)
                                } icon: {
                                    SessionArtwork(tool: tab.tool, compact: true).frame(width: 18, height: 18)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(workspace.active == tab.id ? .isSelected : [])
                            Button {
                                Task { await workspace.close(tab.id) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.bold())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L("Close \(tab.title)", "关闭 \(tab.title)"))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(workspace.active == tab.id ? TandemDiffStyle.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 250)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let parent = workspace.current?.parent, workspace.tabs.contains(where: { $0.id == parent }) {
                Button(L("Back to Folder", "返回文件夹"), systemImage: "arrow.uturn.backward") {
                    workspace.active = parent
                }
                .buttonStyle(.borderless)
            }
            Menu {
                SessionMenuItems(workspace: workspace)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("Session commands", "会话命令"))
            .padding(.trailing, 13)
        }
        .frame(height: 38)
        .background(.bar)
    }

    @ViewBuilder private func detail(_ tab: Workspace.Tab) -> some View {
        switch tab.payload {
        case .folders(let model): FolderView(session: model, workspace: workspace)
        case .text(let model): TextSessionView(model: model, workspace: workspace)
        }
    }

    private var home: some View {
        HomeView(workspace: workspace, library: library, selection: $selectedSessions, collapsedDays: $collapsedRecentDays)
    }

    private var incomingPair: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Open comparison", "打开比较")).font(.title2.bold())
            ForEach(Array([workspace.incoming?.left, workspace.incoming?.right].compactMap { $0 }.enumerated()), id: \.offset) { index, url in
                VStack(alignment: .leading, spacing: 3) {
                    Text(index == 0 ? L("Left", "左侧") : L("Right", "右侧")).font(.caption.bold())
                    Text(url.path).textSelection(.enabled)
                }
            }
            HStack {
                Button(L("Swap Sides", "交换两侧")) { if let pair = workspace.incoming {
                        workspace.incoming = Workspace.IncomingPair(kind: pair.kind, left: pair.right, right: pair.left)
                    } }
                Spacer()
                Button(L("Cancel", "取消")) { workspace.incoming = nil }.keyboardShortcut(.cancelAction)
                Button(L("Compare", "比较")) { workspace.startIncoming() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 550)
    }
}

struct SessionMenuItems: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ForEach(HomeTool.allCases) { tool in
            Button(L("New ", "新建") + tool.title) { workspace.launch(tool) }
        }
        if workspace.current != nil {
            Divider()
            Button(L("Save Session", "保存会话")) { workspace.saveSession(asNew: false) }
            Button(L("Save Session As…", "会话另存为…")) { workspace.saveSession(asNew: true) }
        }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedBinding(\.homePanel) private var homePanel
    @FocusedObject private var folder: FolderSession?
    @FocusedObject private var text: TextSessionModel?

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text(L("Settings…", "设置…")) }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .newItem) {
            Button(L("New Folder Comparison", "新建文件夹比较")) { workspace?.makeFolders() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button(L("New Text Comparison", "新建文本比较")) { workspace?.makeText() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(workspace == nil)
            if let text {
                Button(L("Open File in Active Pane…", "在当前窗格打开文件…")) { Task { await text.chooseFile(text.focused) } }
                    .keyboardShortcut("o").disabled(!text.canChangeFiles || text.locked(text.focused))
                Button(L("Save Active File", "保存当前文件")) { Task { await text.save(text.focused) } }
                    .keyboardShortcut("s").disabled(!text.editable(text.focused) || !text.composing.isEmpty)
                Button(L("Save Active File As…", "当前文件另存为…")) { Task { await text.save(text.focused, asNew: true) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!text.editable(text.focused) || !text.composing.isEmpty)
                Button(L("Reload Active File", "重新载入当前文件")) { Task { await text.reload(text.focused) } }
                    .disabled(text.pane(text.focused).url == nil || !text.canChangeFiles)
            }
            Button(L("Browse Folder Pair…", "选择文件夹对…")) { workspace?.selectFiles(folders: true) }
                .disabled(workspace == nil)
            Button(L("Browse Text Pair…", "选择文本文件对…")) { workspace?.selectFiles(folders: false) }
                .disabled(workspace == nil)
            Divider()
            if folder != nil || text != nil {
                Button(L("Save Session", "保存会话")) { workspace?.saveSession(asNew: false) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button(L("Save Session As…", "会话另存为…")) { workspace?.saveSession(asNew: true) }
            }
            Button(L("Close Comparison Tab", "关闭比较标签页")) {
                if let id = workspace?.active { Task { await workspace?.close(id) } }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.active == nil)
        }
        CommandGroup(after: .sidebar) {
            if homePanel != nil {
                Menu(L("Session Details", "会话详情")) {
                    panelChoice(.automatic, title: L("Show on Selection", "选中时显示"))
                    panelChoice(.pinned, title: L("Always Show", "始终显示"))
                    panelChoice(.expanded, title: L("Expand Details", "放大详情"))
                    panelChoice(.hidden, title: L("Hide Details", "隐藏详情"))
                }
            }
        }
        CommandMenu(L("Comparison", "比较")) {
            let canNavigate = folder?.canNavigateDifferences ?? text?.canNavigateDifferences ?? false
            ForEach(ComparisonDisplay.allCases, id: \.self) { mode in
                Button(mode.title) {
                    folder?.comparisonDisplay = mode
                    text?.comparisonDisplay = mode
                }
                .keyboardShortcut(mode.shortcut, modifiers: .command)
                .disabled(folder.map { $0.copying } ?? (text?.composing.isEmpty != true))
            }
            Divider()
            Button(L("Previous difference", "上一处差异")) {
                folder?.nextDifference(backward: true)
                text?.next(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!canNavigate)
            Button(L("Next difference", "下一处差异")) {
                folder?.nextDifference(backward: false)
                text?.next(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!canNavigate)
            Divider()
            Button(L("Swap Sides", "交换两侧")) {
                folder?.swap()
                text?.swap()
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(folder.map { $0.copying || ($0.left == nil && $0.right == nil) } ?? (text?.canChangeFiles != true))
            Button(text == nil ? L("Refresh Folders", "刷新文件夹") : L("Recompare Buffers", "重新比较文本")) {
                folder?.refresh()
                text?.compare()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(folder?.canRefreshComparison ?? text?.canRefreshComparison ?? false))
            if let folder {
                Button(L("Find Filename…", "查找文件名…")) { folder.showFind = true }
                    .keyboardShortcut("f")
                Button(L("Find Next Filename", "查找下一个文件名")) { folder.findFilename(backward: false) }
                    .keyboardShortcut("g").disabled(folder.findQuery.isEmpty)
                Button(L("Find Previous Filename", "查找上一个文件名")) { folder.findFilename(backward: true) }
                    .keyboardShortcut("g", modifiers: [.shift, .command]).disabled(folder.findQuery.isEmpty)
                Button(L("Open Selected Item", "打开所选项目")) { folder.openSelected() }
                    .disabled(!folder.canOpenSelected(includingFolders: true))
                Button(L("Clear Folder Paths", "清空文件夹路径")) { folder.clear() }
                    .disabled(folder.copying || (folder.left == nil && folder.right == nil))
            }
            Divider()
            transfer(.left)
            transfer(.right)
            if let text {
                let side = text.focused
                let source = text.pane(side), target = text.pane(side.other)
                Button(L("Insert selected characters into ", "插入选中字符到") + text.label(side.other)) { text.insertSelection(from: side) }
                    .disabled(!text.canTransfer || !text.editable(side.other) || source.multipleSelection || target.multipleSelection || (source.selection?.length ?? 0) == 0 || target.selection == nil)
                Divider()
                Button(text.locked(side) ? L("Unlock active pane", "解除当前窗格的编辑锁定") : L("Lock active pane", "锁定当前窗格的编辑")) {
                    Task { await text.toggleLock(side) }
                }
                .disabled(source.inspectionOnly || text.settings.inheritedGuard || !text.canChangeFiles)
            }
        }
    }

    private func panelChoice(_ choice: HomePanel, title: String) -> some View {
        Button { homePanel = choice } label: {
            if homePanel == choice { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func transfer(_ direction: CopyDirection) -> some View {
        let from: TextSide = direction == .right ? .left : .right
        return Button(text?.describeTransfer(from) ?? direction.label) {
            folder?.prepare(direction)
            text?.apply(from: from)
        }
        .keyboardShortcut(direction == .right ? .rightArrow : .leftArrow, modifiers: [.command, .option])
        .disabled(!(folder?.canPreview(direction) ?? text?.canApplyChange(from: from) ?? false))
    }
}

@MainActor
final class WindowGuard: NSObject, NSWindowDelegate {
    weak var workspace: Workspace?
    weak var original: NSWindowDelegate?
    private var allow = false
    private var checking = false

    func prepareToClose() async -> (() async -> Void)? {
        guard let workspace else { return {} }
        return await workspace.prepareWindowClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allow { return original?.windowShouldClose?(sender) ?? true }
        if checking { return false }
        checking = true
        Task {
            if let commit = await prepareToClose() {
                await commit()
                allow = true
                sender.performClose(nil)
                allow = false
            }
            checking = false
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}

private struct WindowHook: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> WindowGuard { WindowGuard() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let guardDelegate = context.coordinator
        guardDelegate.workspace = workspace
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== guardDelegate else { return }
            guardDelegate.original = window.delegate
            window.delegate = guardDelegate
        }
    }
}

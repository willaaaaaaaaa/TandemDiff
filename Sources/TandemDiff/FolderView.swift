import AppKit
import TandemDiffCore
import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {
    @ObservedObject var session: FolderSession
    let workspace: Workspace
    @FocusState private var findFocused: Bool
    @FocusState private var tableFocused: Bool
    @AppStorage("folderShowsActivity") private var showsActivity = false
    @AppStorage("folderUseStripes") private var useStripes = true
    @AppStorage("folderColorIcons") private var colorFolders = true
    @AppStorage("confirmContentCompare") private var confirmContentCompare = false
    @State private var pendingContentCompare: Set<Data>?
    @State private var editingNameFilters = false
    @State private var quickFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.showFind { Divider(); finder }
            Divider()
            paths
            Divider()
            comparison.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = session.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if showsActivity {
                Divider()
                activityLog
            }
            Divider()
            statusBar
        }
        .background(TandemDiffStyle.canvas)
        .focusedSceneObject(session)
        .background(ComparisonNavigationKeys(disabled: !session.canNavigateDifferences, previous: { session.nextDifference(backward: true) }, next: { session.nextDifference(backward: false) }, handlesFieldClipboard: true).frame(width: 0, height: 0))
        .onAppear { quickFilter = session.rules.quickExpression }
        .onChange(of: session.rules) { _, rules in quickFilter = rules.quickExpression }
        .sheet(isPresented: $editingNameFilters) {
            NameFilterEditor(rules: session.rules) { rules in
                session.applyRules(rules)
                quickFilter = session.rules.quickExpression
            }
        }
        .alert(L("Compare Contents?", "比较所选项目的内容？"), isPresented: Binding(get: { pendingContentCompare != nil }, set: {
            if !$0 { pendingContentCompare = nil }
        }), presenting: pendingContentCompare) { ids in
            Button(L("Compare", "比较")) { session.compareContents(ids: ids) }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: { _ in
            Text(L("Recheck the selected items, including files inside selected folders.", "重新检查所选项目，包括所选目录中的文件。"))
        }
        .sheet(isPresented: $session.showPreview) {
            copyPreview
                .interactiveDismissDisabled(session.copying)
        }
    }

    private var paths: some View {
        HStack(spacing: 0) {
            FolderPath(session: session, library: workspace.library, onLeft: true)
            Divider()
            FolderPath(session: session, library: workspace.library, onLeft: false)
        }
        .frame(height: 35)
        .background(.bar)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                viewCommands
                ComparisonToolDivider()
                itemCommands
                ComparisonToolDivider()
                navigationCommands
                Spacer(minLength: 4)
                filterControls
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    viewCommands
                    Spacer(minLength: 4)
                    filterControls
                }
                HStack(spacing: 3) {
                    itemCommands
                    ComparisonToolDivider()
                    navigationCommands
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(TandemDiffStyle.canvas)
    }

    @ViewBuilder private var viewCommands: some View {
        ComparisonSessionControls(workspace: workspace) {
            Button(L("Back to previous folders", "返回上一组目录")) { session.visitLocation(backward: true) }
                .disabled(!session.canGoBack)
            Button(L("Forward to next folders", "前往下一组目录")) { session.visitLocation(backward: false) }
                .disabled(!session.canGoForward)
            Button(L("Go up both sides", "两侧均前往上级目录")) {
                if let left = session.left, let right = session.right {
                    session.setRootPair(left.deletingLastPathComponent(), right.deletingLastPathComponent())
                }
            }.disabled(session.copying || session.left == nil || session.right == nil || (session.left?.path == "/" && session.right?.path == "/"))
            Divider()
            Button(L("Refresh folders", "刷新文件夹")) { session.refresh() }
                .disabled(!session.canRefreshComparison)
            Toggle(L("Protect writes", "保护写入"), isOn: Binding(get: { session.writeProtected }, set: { value in
                Task { await session.setWriteProtection(value) }
            }))
            .disabled(session.copying)
        }
        ComparisonToolDivider()
        ComparisonViewControls(mode: $session.comparisonDisplay) {
            Menu {
                ForEach([FolderFilter.changes, .leftOnly, .rightOnly, .skipped]) { mode in
                    Button { session.filter = mode } label: {
                        if session.filter == mode { Label(mode.label, systemImage: "checkmark") }
                        else { Text(mode.label) }
                    }
                }
            } label: {
                if session.comparisonDisplay == nil {
                    ComparisonToolLabel(title: session.filter.label, symbol: "line.3.horizontal.decrease", ink: TextCommandInk.red, selected: true)
                } else {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 34).contentShape(Rectangle())
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("More status filters", "更多状态筛选")).accessibilityValue(session.filter.label)
            .help(L("Left only, right only, or unexamined", "仅左侧、仅右侧或未检查"))
        }
        .disabled(session.copying)
        ComparisonToolMenu(title: L("Structure", "结构"), symbol: session.structure == .flatList ? "list.bullet" : "list.bullet.indent", ink: TextCommandInk.secondary, help: L("Folder structure", "文件夹结构")) {
            Picker(L("Structure", "结构"), selection: $session.structure) {
                ForEach(FolderStructure.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.inline)
            Divider()
            Button(L("Expand all folders", "展开全部文件夹")) { session.setDirectoriesExpanded(true, all: true) }
                .disabled(!canExpand)
            Button(L("Collapse all folders", "收起全部文件夹")) { session.setDirectoriesExpanded(false, all: true) }
                .disabled(!canExpand)
        }.disabled(session.copying)
    }

    private var canExpand: Bool {
        session.structure != .flatList && !session.copying && session.entries.contains { !$0.children.isEmpty }
    }

    @ViewBuilder private var itemCommands: some View {
        ComparisonToolMenu(title: L("Copy", "复制"), symbol: "arrow.left.arrow.right.square", ink: TandemDiffStyle.accent, help: L("Preview a directional copy", "预览向左或向右复制")) {
            Button { session.prepare(.right) } label: { Label(CopyDirection.right.label, systemImage: "arrowshape.right.fill") }
                .disabled(!session.canPreview(.right))
            Button { session.prepare(.left) } label: { Label(CopyDirection.left.label, systemImage: "arrowshape.left.fill") }
                .disabled(!session.canPreview(.left))
        }.disabled(!session.canPreview(ids: session.selection))
        let allFolders = session.selectedDirectories.isEmpty
        ComparisonToolButton(L("Expand", "展开"), "arrow.up.left.and.arrow.down.right", ink: TextCommandInk.secondary, help: allFolders ? L("Expand all folders", "展开全部文件夹") : L("Expand selected folders", "展开所选文件夹")) {
            session.setDirectoriesExpanded(true, all: allFolders)
        }.disabled(!canExpand)
        ComparisonToolButton(L("Collapse", "收起"), "arrow.down.right.and.arrow.up.left", ink: TextCommandInk.secondary, help: allFolders ? L("Collapse all folders", "收起全部文件夹") : L("Collapse selected folders", "收起所选文件夹")) {
            session.setDirectoriesExpanded(false, all: allFolders)
        }.disabled(!canExpand)
        ComparisonToolMenu(title: L("Select", "选择"), symbol: "checklist", ink: TextCommandInk.secondary, help: L("File selection commands", "文件选择命令")) {
            Button(L("Select visible files", "选择可见文件")) { session.selectVisibleFiles() }
            Menu(L("Select one-sided files", "选择单侧文件")) {
                Button(L("Left only", "仅左侧")) { session.selectVisibleFiles(matching: .orphans(.left)) }
                Button(L("Right only", "仅右侧")) { session.selectVisibleFiles(matching: .orphans(.right)) }
            }
            Menu(L("Select newer files", "选择较新文件")) {
                Button(L("Newer on left", "左侧较新")) { session.selectVisibleFiles(matching: .newer(.left)) }
                Button(L("Newer on right", "右侧较新")) { session.selectVisibleFiles(matching: .newer(.right)) }
            }
            Button(L("Invert visible selection", "反选可见项目")) { session.invertVisibleSelection() }
            Button(L("Clear selection", "取消选择")) { session.selection.removeAll() }
                .disabled(session.selection.isEmpty)
        }.disabled(session.copying || session.rows.isEmpty)
        ComparisonToolButton(L("Open", "打开"), "doc.text.magnifyingglass", ink: TextCommandInk.secondary, help: L("Open selected file in Text Compare", "在文本比较中打开所选文件")) {
            session.openSelected()
        }
        .disabled(!session.canOpenSelected(includingFolders: false))
    }

    @ViewBuilder private var navigationCommands: some View {
        ComparisonNavigationControls(previous: { session.nextDifference(backward: true) }, next: { session.nextDifference(backward: false) }, disabled: !session.canNavigateDifferences)
        ComparisonToolButton(L("Swap", "交换"), "arrow.left.arrow.right", ink: TandemDiffStyle.accent, help: L("Swap sides", "交换两侧") + " (⇧⌘X)") {
            session.swap()
        }.disabled(session.copying || (session.left == nil && session.right == nil))
        ComparisonToolButton(L("Refresh", "刷新"), "arrow.clockwise", ink: TandemDiffStyle.accent, help: L("Refresh folders", "刷新文件夹") + " (⌘R)") {
            session.refresh()
        }.disabled(!session.canRefreshComparison)
        ComparisonToolButton(L("Stop", "停止"), "stop.fill", ink: TextCommandInk.red, help: L("Stop scanning or preparing a copy", "停止扫描或复制预览")) {
            session.stop()
        }.disabled(!session.scanning && !session.preparing)
        ComparisonToolButton(L("Find", "查找"), "magnifyingglass", ink: TextCommandInk.secondary, selected: session.showFind, help: L("Find an item", "查找项目") + " (⌘F)") {
            session.showFind.toggle()
        }
    }

    private var filterControls: some View {
        HStack(spacing: 5) {
            ComparisonToolButton(L("Name Filters", "名称筛选"), "line.3.horizontal.decrease.circle", ink: TandemDiffStyle.accent, help: L("Edit file and folder name filters", "编辑文件和文件夹的名称筛选")) {
                editingNameFilters = true
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Quick filter", "快速筛选")).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Quick filter", "快速筛选"), text: $quickFilter, prompt: Text(verbatim: "*.swift;-build/"))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L("Quick filter", "快速筛选"))
                    .onSubmit {
                        guard quickFilter != session.rules.quickExpression else { return }
                        session.applyRules(NameRules(quickExpression: quickFilter))
                        quickFilter = session.rules.quickExpression
                    }
                    .padding(.horizontal, 5).frame(height: 21)
                    .background(TandemDiffStyle.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator.opacity(0.7)).allowsHitTesting(false) }
            }
            .frame(minWidth: 90, idealWidth: 125, maxWidth: 185)
            .help(L("Separate patterns with semicolons. Use - to exclude and / for folders. Press Return to apply.", "用分号分隔规则，减号表示排除，末尾斜线表示文件夹。按回车应用。"))
            ComparisonToolButton(L("Show excluded items", "显示排除项"), session.showExcluded ? "eye.fill" : "eye.slash", ink: TextCommandInk.secondary, selected: session.showExcluded, help: L("Show or hide excluded items for read-only inspection", "显示或隐藏排除项，只读查看")) {
                session.inspectExcluded(!session.showExcluded)
            }.disabled(session.rules.quickExpression.isEmpty && !session.showExcluded)
        }
        .disabled(session.copying)
    }

    private var finder: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(TextCommandInk.secondary)
            TextField(L("Find file or folder name", "查找文件或目录名"), text: $session.findQuery)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 290).focused($findFocused)
                .onSubmit { session.findFilename(backward: false) }
            Button(L("Previous", "上一个")) { session.findFilename(backward: true) }
                .disabled(session.findQuery.isEmpty || session.copying)
            Button(L("Next", "下一个")) { session.findFilename(backward: false) }
                .disabled(session.findQuery.isEmpty || session.copying)
            if session.findMiss { Text(L("No matching name", "没有匹配的名称")).foregroundStyle(.secondary) }
            Spacer()
            Button(L("Done", "完成")) { session.showFind = false }
        }
        .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 5)
        .onAppear { findFocused = true }
        .onExitCommand { session.showFind = false }
    }

    private var activityLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(session.activity) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(event.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                            Text(event.message).textSelection(.enabled).lineLimit(2)
                        }.id(event.id)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.activity.last?.id, initial: true) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .font(.caption)
        .frame(height: 75)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel(L("Comparison log", "比较日志"))
    }

    private var comparison: some View {
        let rows = session.rows
        return ScrollViewReader { proxy in
            Table(rows, selection: $session.selection, sortOrder: $session.sortOrder) {
                TableColumn(L("Left · Name", "左 · 名称"), sortUsing: FolderRowSort(column: .leftName)) { row in
                    fileCell(row, onLeft: true)
                }
                .width(min: 100, ideal: 150)
                TableColumn(L("Size", "大小"), sortUsing: FolderRowSort(column: .leftSize)) { row in
                    size(row.entry.leftVersion).monospacedDigit().foregroundStyle(tone(row, onLeft: true).ink)
                }
                .width(min: 42, ideal: 52, max: 88)
                TableColumn(L("Modified", "修改时间"), sortUsing: FolderRowSort(column: .leftModified)) { row in
                    modified(row.entry.leftVersion).foregroundStyle(tone(row, onLeft: true).ink)
                }
                .width(min: 62, ideal: 112, max: 140)
                TableColumn(L("Status", "状态")) { row in
                    Label(row.entry.state.label, systemImage: row.entry.state.symbol)
                        .font(.callout)
                        .foregroundStyle(statusColor(row.entry.state))
                        .background(FolderRowBackground(striped: useStripes && row.striped, selection: session.selectionScope(for: row.id)))
                        .help(row.entry.diagnostic.localized)
                        .accessibilityHint(row.entry.diagnostic.localized)
                }
                .width(min: 79, ideal: 88, max: 126)
                TableColumn(L("Right · Name", "右 · 名称"), sortUsing: FolderRowSort(column: .rightName)) { row in
                    fileCell(row, onLeft: false)
                }
                .width(min: 100, ideal: 150)
                TableColumn(L("Size", "大小"), sortUsing: FolderRowSort(column: .rightSize)) { row in
                    size(row.entry.rightVersion).monospacedDigit().foregroundStyle(tone(row, onLeft: false).ink)
                }
                .width(min: 42, ideal: 52, max: 88)
                TableColumn(L("Modified", "修改时间"), sortUsing: FolderRowSort(column: .rightModified)) { row in
                    modified(row.entry.rightVersion).foregroundStyle(tone(row, onLeft: false).ink)
                }
                .width(min: 62, ideal: 112, max: 140)
            }
            .tableStyle(.inset)
            .focused($tableFocused)
            .onAppear {
                if !session.selection.isEmpty && !session.showFind { tableFocused = true }
            }
            .controlSize(.small)
            .alternatingRowBackgrounds(.disabled)
            .environment(\.defaultMinListRowHeight, 21)
            .contextMenu(forSelectionType: Data.self) { ids in
                FolderContextMenu(session: session, ids: ids, side: session.selectionScope.side, compare: requestContentCompare).buttons
            } primaryAction: { ids in
                session.selection = ids
                session.openSelected()
            }
            .background(FolderTableInput(session: session, compare: requestContentCompare))
            .onKeyPress(.return) {
                guard session.openableTextPair != nil ||
                        (session.complete && !session.copying && session.selection.count == 1) else { return .ignored }
                session.openSelected()
                return .handled
            }
            .accessibilityLabel(L("Paired folder entries", "配对的目录条目"))
            .onChange(of: session.selection, initial: true) { _, ids in
                if ids.count == 1, let id = ids.first { proxy.scrollTo(id) }
            }
            .overlay {
                if rows.isEmpty { emptyState.allowsHitTesting(false) }
            }
        }
    }

    private func requestContentCompare(_ ids: Set<Data>) {
        if confirmContentCompare { pendingContentCompare = ids }
        else { session.compareContents(ids: ids) }
    }

    @ViewBuilder private var emptyState: some View {
        if session.left == nil || session.right == nil {
            ContentUnavailableView {
                Label { Text(L("Choose two folders", "选择两个文件夹")) } icon: {
                    SessionArtwork(tool: .folderCompare).frame(width: 64, height: 54)
                }
            } description: {
                Text(L("Browse, enter a path, or drop a folder into either field.", "浏览、输入路径，或将文件夹拖到对应输入框。"))
            }
        } else if session.scanning {
            ProgressView(L("Comparing folders…", "正在比较文件夹…"))
        } else {
            ContentUnavailableView(L("No visible items", "没有可见项目"), systemImage: "list.bullet")
        }
    }

    private func statusColor(_ state: FolderState) -> Color {
        switch state {
        case .leftOnly, .rightOnly: FolderComparisonColor.oneSided.ink
        case .different, .conflict: FolderComparisonColor.different.ink
        default: .secondary
        }
    }

    private func tone(_ row: FolderRow, onLeft: Bool) -> FolderComparisonColor {
        row.entry.isDirectory && !colorFolders ? .normal : FolderComparisonColor(row.entry, onLeft: onLeft)
    }

    @ViewBuilder private func fileCell(_ row: FolderRow, onLeft: Bool) -> some View {
        if let url = onLeft ? row.entry.left : row.entry.right {
            let version = onLeft ? row.entry.leftVersion : row.entry.rightVersion
            let isDirectory = version?.isFolder ?? row.entry.isDirectory
            let tone = tone(row, onLeft: onLeft)
            HStack(spacing: 5) {
                if !row.entry.children.isEmpty {
                    Button {
                        session.toggle(row.id)
                    } label: {
                        Image(systemName: session.expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 11)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(session.expanded.contains(row.id) ? L("Collapse", "折叠") : L("Expand", "展开"))
                    .accessibilityHint(url.lastPathComponent)
                } else {
                    Spacer().frame(width: 11)
                }
                HStack(spacing: 4) {
                    Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                        .foregroundStyle(tone != .normal ? tone.ink : (isDirectory ? TandemDiffStyle.accent : .secondary))
                        .frame(width: 15)
                        .accessibilityHidden(true)
                    Text(session.structure == .flatList ? row.entry.path : url.lastPathComponent)
                        .foregroundStyle(tone.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityValue(tone == .newer ? L("Newer", "较新") : tone == .older ? L("Older", "较旧") : "")
                }
                .padding(.horizontal, 3)
            }
            .padding(.leading, CGFloat(row.level) * 12)
            .help(url.path)
            .accessibilityAddTraits(session.selectionScope(for: row.id)?.includes(onLeft ? .left : .right) == true ? .isSelected : [])
        }
    }

    private func size(_ version: FileVersion?) -> Text {
        guard let bytes = version?.fileSize else { return Text("") }
        return Text(verbatim: FolderMetadata.size(bytes))
    }

    private func modified(_ version: FileVersion?) -> Text {
        guard let version else { return Text("") }
        return Text(verbatim: FolderMetadata.modified(version.modified)).monospacedDigit()
    }

    private var statusBar: some View {
        let counts = session.counts
        let differences = [FolderState.different, .leftOnly, .rightOnly, .conflict].reduce(0) { $0 + counts[$1, default: 0] }
        let skipped = [FolderState.notCompared, .error, .excluded, .pending].reduce(0) { $0 + counts[$1, default: 0] }
        return HStack(spacing: 12) {
            Button { showsActivity.toggle() } label: {
                Label(L("Log", "日志"), systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsActivity ? TandemDiffStyle.accent : .secondary)
            .accessibilityAddTraits(showsActivity ? .isSelected : [])
            .help(L("Show or hide the comparison log", "显示或隐藏比较日志"))
            Divider().frame(height: 12)
            if session.scanning || session.preparing { ProgressView().controlSize(.mini) }
            if session.scanning {
                Text(L("Scanning", "扫描中"))
                    .help(L("Previous results remain visible while the new scan runs.", "扫描期间会暂时保留上一次结果。"))
            }
            Text(L("\(session.rows.count) visible", "可见 \(session.rows.count) 项"))
            Text(L("\(differences) differences", "\(differences) 处差异"))
            Text(L("\(counts[.identical, default: 0]) identical", "\(counts[.identical, default: 0]) 项相同"))
                .help(L("Text files are compared by their original bytes.", "按原始字节比较文本文件。"))
            Button(L("\(skipped) unexamined", "\(skipped) 项未检查")) {
                session.filter = .skipped
            }
            .buttonStyle(.link)
            .disabled(session.copying)
            .help(L("Show unexamined items. Each unexamined subtree counts once. Use Show excluded items to inspect excluded paths.", "查看未检查的项目。每个未检查的子树按一项计数。可用“显示排除项”查看被排除的路径。"))
            if !session.rules.quickExpression.isEmpty {
                Button {
                    editingNameFilters = true
                } label: {
                    Label(L("Name filters active", "名称筛选已启用"), systemImage: "line.3.horizontal.decrease.circle.fill")
                }
                .buttonStyle(.link)
                .disabled(session.copying)
                .help(L("Active name filters", "生效的名称筛选") + " · " + session.rules.quickExpression)
            }
            Spacer()
            if session.writeProtected {
                Label(L("Protected", "写入保护"), systemImage: "lock")
            }
            Text(L("\(session.selection.count) selected", "已选 \(session.selection.count) 项"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var copyPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.previewIsResult ? L("Copy results", "复制结果") : session.copyDirection.label)
                .font(.title2.bold())
            let counts = Dictionary(grouping: session.preview, by: \.action).mapValues(\.count)
            Text(counts.sorted { $0.key.label < $1.key.label }.map { "\($0.value) \($0.key.label)" }.joined(separator: "  ·  "))
                .foregroundStyle(.secondary)
            if session.directoryCount > 0 && !session.previewIsResult {
                Text(L("\(session.directoryCount) parent folders may be created.", "可能创建 \(session.directoryCount) 个上级文件夹。"))
                    .font(.callout)
            }
            Table(session.preview) {
                TableColumn(L("Destination", "目标文件")) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.path).lineLimit(1)
                        Text(item.destination.path).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(item.destination.path)
                }
                TableColumn(L("Action", "动作")) { item in Text(item.action.label) }
                    .width(min: 75, ideal: 110)
                TableColumn(L("Details", "详情")) { item in Text(item.reason).help(item.reason) }
                    .width(min: 150, ideal: 220)
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                if session.copying {
                    Button(L("Stop", "停止")) { session.stop() }
                } else {
                    Button(session.previewIsResult ? L("Done", "完成") : L("Cancel", "取消")) { session.showPreview = false }
                        .keyboardShortcut(.cancelAction)
                    if !session.previewIsResult {
                        Button(L("Apply Copy", "确认复制")) { session.executeCopy() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.preview.contains(where: { $0.action.executable }))
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 700, minHeight: 400)
    }
}

/// Anchor the tint to the native status cell so it follows column resizing and horizontal scrolling.
private struct FolderRowBackground: NSViewRepresentable {
    let striped: Bool
    let selection: FolderSelectionScope?

    final class Tint: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color = dark ? NSColor(srgbRed: 0.17, green: 0.29, blue: 0.41, alpha: 1) :
                NSColor(srgbRed: 168/255, green: 205/255, blue: 241/255, alpha: 1)
            color.setFill()
            bounds.fill()
        }
    }

    final class Anchor: NSView {
        var striped = false
        var selection: FolderSelectionScope?
        private let tint = Tint()
        private var constraintsForTint: [NSLayoutConstraint] = []
        private var appliedSelection: FolderSelectionScope?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            var cell: NSView? = self
            while let view = cell, !(view.superview is NSTableRowView) { cell = view.superview }
            guard let cell, let row = cell.superview as? NSTableRowView, window != nil else {
                tint.removeFromSuperview()
                return
            }
            row.selectionHighlightStyle = .none
            row.backgroundColor = striped ? NSColor.alternatingContentBackgroundColors.last ?? .clear : .clear
            guard let selection else {
                tint.removeFromSuperview()
                return
            }
            guard tint.superview !== row || selection != appliedSelection else { return }
            NSLayoutConstraint.deactivate(constraintsForTint)
            if tint.superview !== row {
                tint.removeFromSuperview()
                tint.translatesAutoresizingMaskIntoConstraints = false
                tint.setAccessibilityElement(false)
                row.addSubview(tint, positioned: .below, relativeTo: nil)
            }
            appliedSelection = selection
            constraintsForTint = [
                tint.topAnchor.constraint(equalTo: row.topAnchor),
                tint.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                tint.leadingAnchor.constraint(equalTo: selection == .right ? cell.trailingAnchor : row.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: selection == .left ? cell.leadingAnchor : row.trailingAnchor)
            ]
            NSLayoutConstraint.activate(constraintsForTint)
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.striped = striped
        view.selection = selection
        view.apply()
    }
}

enum FolderMetadata {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        if bytes < 1_000 {
            return L("\(bytes) " + (bytes == 1 ? "byte" : "bytes"), "\(bytes) 字节")
        }
        return bytes.formatted(.byteCount(style: .file).locale(AppLocalization.shared.language.locale))
    }

    static func modified(_ instant: Date) -> String {
        if Calendar.current.isDateInToday(instant) { return L("Today ", "今天 ") + clock.string(from: instant) }
        return instant.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(AppLocalization.shared.language.locale))
    }
}

private struct FolderPath: View {
    @ObservedObject var session: FolderSession
    @ObservedObject var library: SessionLibrary
    let onLeft: Bool
    private var url: URL? { onLeft ? session.left : session.right }
    private var title: String { onLeft ? L("Left folder", "左侧文件夹") : L("Right folder", "右侧文件夹") }

    var body: some View {
        HStack(spacing: 4) {
            RecentPathField(path: url?.path ?? "", paths: library.recentFolderPaths,
                            label: title + L(" path", "路径"), enabled: !session.copying, kind: .folders) { value in
                session.openPath(value, onLeft: onLeft)
                return url?.path ?? ""
            }
            .controlSize(.regular)
            .frame(maxWidth: .infinity, minHeight: 24)
            Button {
                let panel = NSOpenPanel()
                panel.prompt = L("Open", "打开")
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = url
                if panel.runModal() == .OK, let value = panel.url { session.setRoot(value, onLeft: onLeft) }
            } label: { BrowsePathIcon() }
            .accessibilityLabel(title + " · " + L("Browse", "浏览"))
            .help(title + " · " + L("Browse", "浏览"))
            Button {
                if let url { session.setRoot(url.deletingLastPathComponent(), onLeft: onLeft) }
            } label: {
                TextCommandIcon(symbol: "arrow.up", ink: TandemDiffStyle.accent).frame(width: 24, height: 24)
            }
            .accessibilityLabel(title + " · " + L("Go to parent folder", "前往上级目录"))
            .help(title + " · " + L("Go to parent folder", "前往上级目录"))
            .disabled(url == nil || url?.path == "/")
        }
        .font(.system(size: 14, weight: .medium)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 7)
        .disabled(session.copying)
        .dropDestination(for: URL.self) { urls, _ in
            guard !session.copying, urls.count == 1, let selected = urls.first, selected.isFileURL else { return false }
            session.setRoot(selected, onLeft: onLeft)
            return url?.path.utf8.elementsEqual(selected.path.utf8) == true
        }
    }
}

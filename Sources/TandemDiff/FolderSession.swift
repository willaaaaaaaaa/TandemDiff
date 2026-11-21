import AppKit
import TandemDiffCore
import SwiftUI

extension FolderState {
    var label: String {
        switch self {
        case .identical: L("Identical", "相同")
        case .different: L("Different", "有差异")
        case .leftOnly: L("Left only", "仅左侧")
        case .rightOnly: L("Right only", "仅右侧")
        case .notCompared: L("Not compared", "未比较")
        case .conflict: L("Type conflict", "类型冲突")
        case .error: L("Error", "错误")
        case .pending: L("Incomplete", "未完成")
        case .excluded: L("Excluded", "已排除")
        }
    }

    var symbol: String {
        switch self {
        case .identical: "equal"
        case .different: "notequal"
        case .leftOnly: "arrow.left"
        case .rightOnly: "arrow.right"
        case .notCompared: "minus.circle"
        case .conflict: "exclamationmark.diamond"
        case .error: "exclamationmark.triangle"
        case .pending: "ellipsis.circle"
        case .excluded: "line.3.horizontal.decrease.circle"
        }
    }

    var isDifference: Bool { self == .different || self == .leftOnly || self == .rightOnly || self == .conflict }
}

enum FolderFilter: String, Codable, CaseIterable, Identifiable {
    case all, changes, identical, leftOnly, rightOnly, skipped

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: L("All", "全部")
        case .changes: L("Differences", "差异")
        case .identical: FolderState.identical.label
        case .leftOnly: FolderState.leftOnly.label
        case .rightOnly: FolderState.rightOnly.label
        case .skipped: L("Unexamined", "未检查")
        }
    }

    func includes(_ state: FolderState) -> Bool {
        switch self {
        case .all: true
        case .changes: state.isDifference
        case .identical: state == .identical
        case .leftOnly: state == .leftOnly
        case .rightOnly: state == .rightOnly
        case .skipped: state == .notCompared || state == .error || state == .pending || state == .excluded
        }
    }
}

enum FolderStructure: String, Codable, CaseIterable, Identifiable {
    case compareFolders, filesOnly, alwaysShowFolders, flatList

    var id: String { rawValue }
    var label: String {
        switch self {
        case .compareFolders: L("Compare Folders", "比较文件夹")
        case .filesOnly: L("Only Compare Files", "仅比较文件")
        case .alwaysShowFolders: L("Always Show Folders", "始终显示文件夹")
        case .flatList: L("Relative Path List", "相对路径列表")
        }
    }
}

struct FolderRow: Identifiable {
    let entry: FolderEntry
    let level: Int
    let striped: Bool
    var id: Data { entry.id }
}

enum FolderSelectionScope: String, Codable {
    case left, right, both, all

    init(side: TextSide?) {
        switch side {
        case .left: self = .left
        case .right: self = .right
        case nil: self = .both
        }
    }

    var side: TextSide? {
        switch self {
        case .left: .left
        case .right: .right
        case .both, .all: nil
        }
    }
}

enum CopyDirection {
    case right, left

    var diagnostic: DiagnosticText {
        self == .right ? .init("Copy to Right", "复制到右侧") : .init("Copy to Left", "复制到左侧")
    }

    var label: String { diagnostic.localized }
}

struct FolderCopyItem: Identifiable, Sendable {
    enum Action: Hashable, Sendable {
        case create, replace, unchanged, skip, blocked, running, finished, failed, pending

        var label: String {
            switch self {
            case .create: L("Create", "新建")
            case .replace: L("Replace", "替换")
            case .unchanged: L("Unchanged", "无变化")
            case .skip: L("Skipped", "已跳过")
            case .blocked: L("Blocked", "已阻止")
            case .running: L("Copying", "正在复制")
            case .finished: L("Copied", "已复制")
            case .failed: L("Failed", "失败")
            case .pending: L("Pending", "等待执行")
            }
        }

        var executable: Bool { self == .create || self == .replace }
    }

    let id: Data
    let path: String
    let source: URL?
    let destination: URL
    let sourceVersion: FileVersion?
    let destinationVersion: FileVersion?
    var observation: WriteObservation?
    var action: Action
    var diagnostic: DiagnosticText
    var reason: String { diagnostic.localized }
}

@MainActor
final class FolderSession: ObservableObject {
    @Published private(set) var left: URL?
    @Published private(set) var right: URL?
    @Published var rules = NameRules()
    @Published var filter: FolderFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            updateVisibleSelection()
        }
    }
    @Published var structure: FolderStructure = .compareFolders {
        didSet {
            guard structure != oldValue else { return }
            updateVisibleSelection()
        }
    }
    @Published var showExcluded = false { didSet { cachedRows = nil } }
    @Published var sortOrder: [FolderRowSort] = [] { didSet { cachedRows = nil } }
    @Published var expanded = Set<Data>() { didSet { cachedRows = nil } }
    @Published var selection = Set<Data>() {
        didSet {
            guard selection != oldValue else { return }
            if explicitSelectAll { selectionScope = .both }
            invalidatePreview()
        }
    }
    @Published var selectionScope: FolderSelectionScope = .both
    var explicitSelectAll: Bool { selectionScope == .all }

    @Published private(set) var entries: [FolderEntry] = [] { didSet { cachedRows = nil; cachedCounts = nil } }
    @Published private(set) var writeProtected = false
    @Published private(set) var scanning = false
    @Published private(set) var complete = false
    @Published private(set) var preparing = false
    @Published private(set) var copying = false
    @Published var showFind = false
    @Published var findQuery = "" { didSet { findMiss = false } }
    @Published var findMiss = false
    @Published private(set) var activity: [FolderActivity] = []
    @Published private var noticeMessage: DiagnosticText? {
        didSet { if let noticeMessage { log(noticeMessage) } }
    }
    var notice: String? { noticeMessage?.localized }

    @Published var preview: [FolderCopyItem] = []
    @Published var showPreview = false
    @Published private(set) var previewIsResult = false
    @Published private(set) var copyDirection: CopyDirection = .right
    @Published private(set) var directoryCount = 0

    let registry: EditRegistry
    var onOpen: ((FolderEntry) -> Void)?
    var onChange: (() -> Void)?
    var onRecent: (([URL]) -> Void)?
    var onProtectChildren: ((Bool) async -> Bool)?

    private struct RootIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init?(_ url: URL?) {
            guard let url, let observed = try? FileVersion.read(url) else { return nil }
            device = observed.device
            inode = observed.inode
        }

        func matches(_ version: FileVersion?) -> Bool {
            device == version?.device && inode == version?.inode
        }
    }

    private struct Location {
        let left: URL?
        let right: URL?
        let leftIdentity: RootIdentity?
        let rightIdentity: RootIdentity?
    }

    private var location: Location {
        Location(left: left, right: right, leftIdentity: leftIdentity, rightIdentity: rightIdentity)
    }
    private var previousLocations: [Location] = []
    private var nextLocations: [Location] = []
    var canGoBack: Bool { !copying && !previousLocations.isEmpty }
    var canGoForward: Bool { !copying && !nextLocations.isEmpty }

    private func rememberLocation() {
        if left != nil || right != nil { previousLocations.append(location) }
        nextLocations.removeAll()
    }

    func visitLocation(backward: Bool) {
        guard !copying, let target = backward ? previousLocations.popLast() : nextLocations.popLast() else { return }
        guard target.leftIdentity == RootIdentity(target.left), target.rightIdentity == RootIdentity(target.right) else {
            noticeMessage = .init("A folder in the history moved or was replaced.", "历史记录中的文件夹已移动或被替换。")
            return
        }
        if backward { nextLocations.append(location) } else { previousLocations.append(location) }
        left = target.left
        right = target.right
        leftIdentity = target.leftIdentity
        rightIdentity = target.rightIdentity
        rootsChanged(recent: [])
    }

    func useAsRoots(_ entry: FolderEntry, side: TextSide? = nil) {
        guard complete, !copying, let left, let right, entry.canBeBaseFolder(on: side) else { return }
        guard rootsAreCurrent(left, right),
              let current = rows.first(where: { $0.id == entry.id })?.entry,
              current.canBeBaseFolder(on: side), current.left == entry.left, current.right == entry.right else {
            refresh()
            noticeMessage = .init("The selected folder changed. Review the refreshed comparison.", "所选目录已变化，请查看刷新后的比较结果。")
            return
        }
        if let side {
            setRoot(entry.url(on: side), onLeft: side == .left, expected: side == .left ? entry.leftVersion : entry.rightVersion)
        } else if let newLeft = entry.left, let newRight = entry.right {
            setRootPair(newLeft, newRight, expected: entry)
        }
    }

    func setRootPair(_ newLeft: URL, _ newRight: URL, expected: FolderEntry? = nil) {
        guard !copying else { return }
        do {
            try validateFolder(newLeft)
            try validateFolder(newRight)
        } catch {
            noticeMessage = error.comparisonDiagnostic
            return
        }
        guard let first = RootIdentity(newLeft), let second = RootIdentity(newRight),
              expected.map({ first.matches($0.leftVersion) && second.matches($0.rightVersion) }) ?? true else {
            refresh()
            noticeMessage = .init("The folder changed. Review the refreshed comparison.", "目录已变化，请查看刷新后的比较结果。")
            return
        }
        rememberLocation()
        left = newLeft
        right = newRight
        leftIdentity = first
        rightIdentity = second
        rootsChanged(recent: [newLeft, newRight])
    }

    private var leftIdentity: RootIdentity?
    private var rightIdentity: RootIdentity?
    private var folderEvents: FolderEvents?
    private var observedPaths = [String]()
    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var generation = UUID()
    private var cachedRows: [FolderRow]?
    private var cachedCounts: [FolderState: Int]?
    private var closed = false

    init(left: URL?, right: URL?, registry: EditRegistry, defaults: FolderSessionDefaults = FolderSessionDefaults()) {
        self.left = left
        self.right = right
        self.registry = registry
        rules = defaults.rules
        filter = defaults.filter
        structure = defaults.structure ?? .compareFolders
        showExcluded = defaults.showExcluded
        writeProtected = defaults.writeProtected
        leftIdentity = RootIdentity(left)
        rightIdentity = RootIdentity(right)
    }

    var title: String {
        let names = [left, right].compactMap { $0?.lastPathComponent }
        return names.isEmpty ? L("Folder comparison", "文件夹比较") : names.joined(separator: " <--> ")
    }

    var allEntries: [FolderEntry] { flatten(entries) }

    var counts: [FolderState: Int] {
        if let cachedCounts { return cachedCounts }
        var totals: [FolderState: Int] = [:]
        func count(_ rows: [FolderEntry]) {
            for row in rows {
                if row.children.isEmpty || row.state == .excluded || row.state == .error {
                    totals[row.state, default: 0] += 1
                }
                if row.isUnexamined && (row.state == .leftOnly || row.state == .rightOnly) {
                    totals[.notCompared, default: 0] += 1
                }
                if row.state != .excluded { count(row.children) }
            }
        }
        count(entries)
        cachedCounts = totals
        return totals
    }

    var rows: [FolderRow] {
        if let cachedRows { return cachedRows }
        let projected = projectedRows(expandAll: false)
        cachedRows = projected
        return projected
    }

    func projectedRows(expandAll: Bool) -> [FolderRow] {
        func visible(_ node: FolderEntry) -> Bool {
            if node.state == .excluded && !showExcluded { return false }
            if node.isDirectory {
                switch structure {
                case .alwaysShowFolders: return true
                case .filesOnly: return node.children.contains(where: visible)
                case .flatList: return false
                case .compareFolders: break
                }
            }
            if node.state == .excluded { return true }
            return (filter == .skipped && node.isUnexamined) || filter.includes(node.state) || node.children.contains(where: visible)
        }
        func append(_ nodes: [FolderEntry], level: Int, into rows: inout [FolderRow]) {
            var siblings = nodes.filter(visible)
            if !sortOrder.isEmpty {
                siblings.sort { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    for comparator in sortOrder {
                        let comparison = comparator.compareEntries(lhs, rhs)
                        if comparison != .orderedSame { return comparison == .orderedAscending }
                    }
                    return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
                }
            }
            for node in siblings {
                rows.append(FolderRow(entry: node, level: level, striped: !rows.count.isMultiple(of: 2)))
                if node.isDirectory && (expandAll || expanded.contains(node.id)) {
                    append(node.children, level: level + 1, into: &rows)
                }
            }
        }
        var result: [FolderRow] = []
        append(structure == .flatList ? allEntries : entries, level: 0, into: &result)
        return result
    }

    private func updateVisibleSelection() {
        cachedRows = nil
        invalidatePreview()
        selection.formIntersection(rows.map(\.id))
    }

    private func flatten(_ entries: [FolderEntry]) -> [FolderEntry] {
        var result: [FolderEntry] = []
        func collect(_ children: [FolderEntry]) {
            for child in children {
                result.append(child)
                collect(child.children)
            }
        }
        collect(entries)
        return result
    }

    func openPath(_ input: String, onLeft: Bool) {
        let base = (onLeft ? left ?? right : right ?? left) ?? FileManager.default.homeDirectoryForCurrentUser
        guard let url = comparisonPathURL(input, relativeTo: base) else {
            noticeMessage = .init("Choose a local folder path.", "请选择本地文件夹路径。")
            return
        }
        setRoot(url.standardized, onLeft: onLeft)
    }

    func setRoot(_ url: URL?, onLeft: Bool, expected: FileVersion? = nil) {
        guard !copying else { return }
        do {
            if let url { try validateFolder(url) }
        } catch {
            noticeMessage = error.comparisonDiagnostic
            return
        }
        let identity = RootIdentity(url)
        if let expected, identity?.matches(expected) != true {
            refresh()
            noticeMessage = .init("The folder changed. Review the refreshed comparison.", "目录已变化，请查看刷新后的比较结果。")
            return
        }
        if (onLeft ? left : right)?.path.utf8.elementsEqual(url?.path.utf8 ?? "".utf8) != true {
            rememberLocation()
        }
        if onLeft {
            left = url
            leftIdentity = identity
        } else {
            right = url
            rightIdentity = identity
        }
        rootsChanged(recent: [url].compactMap { $0 })
    }

    private func validateFolder(_ url: URL) throws {
        try LocalAccess.validate(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: L("Select a directory.", "请选择文件夹。")])
        }
    }

    private func rootsChanged(recent: [URL]) {
        expanded = []
        selection = []
        selectionScope = .both
        onChange?()
        refresh(preserveSelection: false)
        onRecent?(recent)
    }

    func restore(_ record: SessionRecord) {
        rules = record.rules ?? NameRules()
        filter = FolderFilter(rawValue: record.folderFilter ?? "") ?? .all
        structure = FolderStructure(rawValue: record.folderStructure ?? "") ?? .compareFolders
        showExcluded = record.showExcluded ?? false
        expanded = record.expansion ?? []
        selection = record.selection ?? []
        selectionScope = record.folderSelectionScope ?? .both
        writeProtected = record.folderWriteProtected ?? false
    }

    func swap() {
        guard !copying else { return }
        rememberLocation()
        (left, right) = (right, left)
        (leftIdentity, rightIdentity) = (rightIdentity, leftIdentity)
        onChange?()
        refresh(preserveSelection: false)
        onRecent?([])
    }

    func clear() {
        guard !copying else { return }
        rememberLocation()
        stop()
        left = nil
        right = nil
        leftIdentity = nil
        rightIdentity = nil
        watchRoots([])
        entries = []
        selection = []
        expanded = []
        onChange?()
    }

    func refresh(preserveSelection: Bool = true) {
        startScan(preserveSelection: preserveSelection)
    }

    func compareContents(ids: Set<Data>) {
        guard complete, !ids.isEmpty else { return }
        startScan(preserveSelection: true, selectedIDs: ids)
    }

    private func startScan(preserveSelection: Bool, selectedIDs: Set<Data>? = nil) {
        guard !copying, !closed else { return }
        let keepPreviousRows = preserveSelection && !entries.isEmpty
        let scope = selectedIDs.map { (ids: $0, entries: entries) }
        scanTask?.cancel()
        invalidatePreview()
        scanning = false
        complete = false
        if !keepPreviousRows { entries = [] }
        noticeMessage = nil
        generation = UUID()
        guard let left, let right else { entries = []; watchRoots([]); return }
        guard rootsAreCurrent(left, right) else {
            entries = []
            watchRoots([])
            noticeMessage = .init("A root moved or was replaced. Browse to select it again.", "根文件夹已移动或被替换，请使用浏览重新选择。")
            return
        }
        watchRoots([left, right])
        let generation = generation
        let rules = rules
        let showExcluded = showExcluded
        scanning = true
        if let selectedIDs {
            log(.init("Comparing contents of selected items (\(selectedIDs.count))", "正在比较所选项目的内容 (\(selectedIDs.count))"))
        } else {
            let paths = left.path + " ↔ " + right.path
            log(.init("Comparing " + paths, "正在比较 " + paths))
        }

        enum Event: Sendable {
            case row(FolderEntry)
            case end([FolderEntry])
            case failure(DiagnosticText)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            do {
                let result = try FolderScanner.scan(left: left, right: right, rules: rules, showExcluded: showExcluded, rechecking: scope) {
                    continuation.yield(.row($0))
                }
                continuation.yield(.end(result))
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.failure(error.comparisonDiagnostic))
            }
        }
        continuation.onTermination = { _ in worker.cancel() }
        scanTask = Task { [weak self] in
            defer { worker.cancel() }
            var lastFlush = ContinuousClock.now
            var pending: [FolderEntry] = []
            for await event in stream {
                guard let self, !Task.isCancelled, self.generation == generation else { break }
                switch event {
                case .row(let entry):
                    guard !keepPreviousRows else { continue }
                    pending.append(entry)
                    if pending.count >= 64 || lastFlush.duration(to: .now) >= .milliseconds(75) {
                        self.entries.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                        lastFlush = .now
                    }
                case .end(let result):
                    guard self.rootsAreCurrent(left, right) else {
                        self.entries = []
                        self.complete = false
                        self.noticeMessage = .init("A root changed during the scan. Browse to select it again.", "扫描期间根文件夹已变化，请使用浏览重新选择。")
                        continue
                    }
                    self.entries = result
                    self.complete = true
                    self.log(.init("Comparison complete", "比较完成"))
                    self.restoreVisibleSelection()
                case .failure(let message):
                    if keepPreviousRows { self.entries = [] } else { self.entries.append(contentsOf: pending) }
                    self.noticeMessage = message
                }
            }
            if let self, self.generation == generation { self.scanning = false }
        }
    }

    private func log(_ message: DiagnosticText) {
        activity.append(FolderActivity(diagnostic: message))
        if activity.count > 100 { activity.removeFirst() }
    }

    private func rootsAreCurrent(_ left: URL, _ right: URL) -> Bool {
        guard let leftIdentity, let rightIdentity else { return false }
        return RootIdentity(left) == leftIdentity && RootIdentity(right) == rightIdentity
    }

    private func watchRoots(_ urls: [URL]) {
        let paths = urls.compactMap { url -> String? in
            guard (try? LocalAccess.validate(url)) != nil else { return nil }
            return try? LocalAccess.canonicalURL(url).path
        }
        guard paths != observedPaths else { return }
        observedPaths = paths
        folderEvents = paths.isEmpty ? nil : FolderEvents(paths: paths) { [weak self] in
            guard let self, !self.copying, !self.closed else { return }
            self.refresh()
        }
    }

    private func restoreVisibleSelection() {
        let selectionAnchor = selection.first.flatMap { String(data: $0, encoding: .utf8) }
        let available = Set(rows.map(\.id))
        selection.formIntersection(available)
        guard selection.isEmpty, var ancestor = selectionAnchor else { return }
        while !ancestor.isEmpty {
            let key = Data(ancestor.utf8)
            if available.contains(key) {
                selection = [key]
                if ancestor != selectionAnchor {
                    noticeMessage = .init("Selection moved to the nearest visible folder.", "选中项已移到最近的可见文件夹。")
                }
                return
            }
            guard let slash = ancestor.lastIndex(of: "/") else { break }
            ancestor = String(ancestor[..<slash])
        }
    }

    func stop() {
        scanTask?.cancel()
        if scanning {
            generation = UUID()
            complete = false
            noticeMessage = .init("Scan stopped. The displayed rows cover part of the comparison.", "扫描已停止。当前列表只包含部分比较结果。")
        }
        scanning = false
        if copying { copyTask?.cancel() }
        if preparing { invalidatePreview() }
    }

    func close() async {
        closed = true
        stop()
        watchRoots([])
        await copyTask?.value
    }

    func nextDifference(backward: Bool) {
        let visible = rows
        let ordered = backward ? Array(visible.reversed()) : visible
        let start = ordered.lastIndex { selection.contains($0.id) }.map { $0 + 1 } ?? 0
        let next = ordered[start...].first { $0.entry.state.isDifference } ?? ordered.first { $0.entry.state.isDifference }
        if let next { selection = [next.id] }
    }

    func selectVisibleFiles() {
        selectionScope = .both
        selection = Set(rows.lazy.filter { !$0.entry.isDirectory }.map(\.id))
    }

    func invertVisibleSelection() {
        selectionScope = .both
        selection = Set(rows.map(\.id)).subtracting(selection)
    }

    func openSelected() {
        guard selection.count == 1 else { return }
        openItems(ids: selection)
    }

    func openItems(ids: Set<Data>) {
        guard !copying, !ids.isEmpty, let left, let right else { return }
        guard rootsAreCurrent(left, right) else { refresh(); return }
        guard complete else { return }
        let items = rows.filter { ids.contains($0.id) }
        guard items.count == ids.count else { return }
        if items.count == 1, let first = items.first, first.entry.isDirectory { toggle(first.id) }
        else if items.count == 1 || items.allSatisfy({ $0.entry.canOpenAsText }) {
            for row in items { onOpen?(row.entry) }
        }
    }

    func toggle(_ id: Data) {
        guard structure != .flatList else { return }
        if expanded.remove(id) == nil { expanded.insert(id) }
        else { selection.formIntersection(rows.map(\.id)) }
    }

    var selectedDirectories: [FolderEntry] {
        rows.compactMap { row in
            selection.contains(row.id) && !row.entry.children.isEmpty ? row.entry : nil
        }
    }

    func setDirectoriesExpanded(_ expand: Bool, all: Bool, selectedIDs: Set<Data>? = nil) {
        guard !copying, structure != .flatList else { return }
        let selected = selectedIDs ?? selection
        let roots = all ? entries : rows.compactMap { selected.contains($0.id) ? $0.entry : nil }
        var ids = Set<Data>()
        func collect(_ nodes: [FolderEntry]) {
            for node in nodes where !node.children.isEmpty && ids.insert(node.id).inserted {
                collect(node.children)
            }
        }
        collect(roots)
        if expand { expanded.formUnion(ids) }
        else {
            expanded.subtract(ids)
            selection.formIntersection(rows.map(\.id))
        }
    }

    func inspectExcluded(_ value: Bool) {
        guard !copying, showExcluded != value else { return }
        showExcluded = value
        refresh()
    }

    func applyRules(_ value: NameRules) {
        guard !copying, rules != value else { return }
        rules = value
        refresh()
    }

    func canPreview(ids: Set<Data>) -> Bool {
        complete && !writeProtected && !copying && !preparing && !ids.isEmpty &&
            rows.contains { ids.contains($0.id) }
    }

    func setWriteProtection(_ value: Bool) async {
        guard !copying, value != writeProtected else { return }
        guard await onProtectChildren?(value) ?? true else { return }
        invalidatePreview()
        writeProtected = value
    }

    func invalidatePreview() {
        guard !copying else { return }
        previewTask?.cancel()
        preparing = false
        if !previewIsResult {
            showPreview = false
            preview = []
        }
    }

    func prepare(_ direction: CopyDirection, selectedIDs: Set<Data>? = nil) {
        guard let left, let right, canPreview(ids: selectedIDs ?? selection) else { return }
        guard rootsAreCurrent(left, right) else { refresh(); return }
        let sourceRoot = direction == .right ? left : right
        let targetRoot = direction == .right ? right : left
        let generation = generation
        let filter = filter
        let modelSelection = selection
        let selection = (selectedIDs ?? modelSelection).intersection(self.rows.map(\.id))
        let selected = allEntries.filter { selection.contains($0.id) }
        let targets = selected.filter(\.isDirectory).map { Data(($0.path + "/").utf8) }
        let picked = allEntries.filter { entry in
            if selection.contains(entry.id) { return true }
            return targets.contains { entry.id.starts(with: $0) }
        }
        let rows = picked.filter { !$0.isDirectory || $0.state == .excluded || $0.children.isEmpty }
        guard !rows.isEmpty else { return }

        copyDirection = direction
        previewIsResult = false
        preparing = true
        let initial: [FolderCopyItem] = rows.map { entry in
            let from = direction == .right ? entry.left : entry.right
            let to = direction == .right ? entry.right : entry.left
            let fromVersion = direction == .right ? entry.leftVersion : entry.rightVersion
            let toVersion = direction == .right ? entry.rightVersion : entry.leftVersion
            let fromText = direction == .right ? entry.leftText : entry.rightText
            let toText = direction == .right ? entry.rightText : entry.leftText
            let dest = to ?? LocalAccess.appending(entry.path, to: targetRoot)
            let protected = from.map(registry.isDirty) == true || registry.isDirty(dest)
            let action: FolderCopyItem.Action
            let reason: DiagnosticText
            if entry.state == .excluded || !filter.includes(entry.state) || entry.isDirectory || from == nil {
                action = .skip
                reason = entry.reason.isEmpty ? .init("Outside the effective file selection.", "超出实际文件选择范围。") : entry.diagnostic
            } else if protected {
                action = .blocked
                reason = .init("An editor has unsaved changes for this path.", "此路径在编辑器中有未保存的更改。")
            } else if fromText == nil || (to != nil && toText == nil) || entry.state == .error || entry.state == .pending || entry.state == .conflict {
                action = .skip
                reason = entry.reason.isEmpty ? .init("Both endpoints must be eligible text or a missing destination.", "源文件必须是可比较文本，目标必须是可比较文本或尚不存在。") : entry.diagnostic
            } else if entry.state == .identical {
                action = .unchanged
                reason = .init(verbatim: "")
            } else {
                action = to == nil ? .create : .replace
                reason = .init(verbatim: "")
            }
            return FolderCopyItem(id: entry.id, path: entry.path, source: from, destination: dest, sourceVersion: fromVersion, destinationVersion: toVersion, observation: nil, action: action, diagnostic: reason)
        }
        let worker = Task.detached(priority: .userInitiated) {
            Self.check(initial, sourceRoot: sourceRoot, targetRoot: targetRoot)
        }
        previewTask = Task { [weak self] in
            let (items, count) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == generation, self.selection == modelSelection, self.filter == filter else { return }
            self.preparing = false
            self.preview = items
            self.directoryCount = count
            self.showPreview = true
        }
    }

    private nonisolated static func check(_ initial: [FolderCopyItem], sourceRoot: URL, targetRoot: URL) -> ([FolderCopyItem], Int) {
        var result = initial
        var spellings: [[String]: Set<Data>] = [:]
        var keys: [Int: [[String]]] = [:]
        for index in result.indices where result[index].action.executable {
            if Task.isCancelled { return ([], 0) }
            do {
                let item = result[index]
                guard let source = item.source, let version = item.sourceVersion else { throw WorkspaceError.pathChanged(item.path) }
                let components = try FileWriter.destinationKey(item.destination, root: targetRoot)
                let original = item.path.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == original.count else { throw WorkspaceError.pathChanged(item.path) }
                let prefixes = components.indices.map { Array(components[...$0]) }
                for (key, plain) in zip(prefixes, original) { spellings[key, default: []].insert(Data(plain.utf8)) }
                keys[index] = prefixes
                result[index].observation = try FileWriter.checkCopy(from: source, version: version, sourceRoot: sourceRoot, to: item.destination, destinationVersion: item.destinationVersion, destinationRoot: targetRoot)
            } catch {
                result[index].action = .blocked
                result[index].diagnostic = error.comparisonDiagnostic
            }
        }
        var missing = Set<URL>()
        for index in result.indices where result[index].action.executable {
            if keys[index]?.contains(where: { (spellings[$0]?.count ?? 0) > 1 }) == true {
                result[index].action = .blocked
                result[index].diagnostic = .init("Selected paths collide on the target volume.", "所选路径在目标卷上存在命名冲突。")
                continue
            }
            var parent = result[index].destination.deletingLastPathComponent()
            while parent.path != targetRoot.path && parent.path.count > targetRoot.path.count && !FileManager.default.fileExists(atPath: parent.path) {
                missing.insert(parent)
                parent.deleteLastPathComponent()
            }
        }
        return (result, missing.count)
    }

    func executeCopy() {
        guard let left, let right, complete, showPreview, !writeProtected, !copying, !previewIsResult else { return }
        guard rootsAreCurrent(left, right) else { refresh(); return }
        let sourceRoot = copyDirection == .right ? left : right
        let targetRoot = copyDirection == .right ? right : left
        let paths = Set(preview.filter { $0.action.executable }.flatMap { [$0.source, $0.destination].compactMap { $0 } })
        guard !paths.isEmpty, !paths.contains(where: registry.copyInProgress) else { return }
        registry.copyStarted(paths)
        copying = true
        let batch = WriteBatch()
        copyTask = Task {
            var changed: [URL] = []
            defer {
                registry.copyFinished(paths)
                let failed = preview.filter { $0.action == .failed || $0.action == .blocked }.count
                log(copyDirection.diagnostic.appending(.init("\(changed.count) copied, \(failed) failed or blocked", "已复制 \(changed.count) 项，失败或受阻 \(failed) 项"), separator: " · "))
                previewIsResult = true
                copying = false
                for url in changed { registry.diskChanged(url) }
                refresh()
            }
            for index in preview.indices where preview[index].action.executable {
                if Task.isCancelled {
                    preview[index].action = .pending
                    continue
                }
                let item = preview[index]
                guard let source = item.source, let version = item.sourceVersion else { continue }
                if registry.isDirty(source) || registry.isDirty(item.destination) {
                    preview[index].action = .blocked
                    preview[index].diagnostic = .init("A file now has unsaved edits.", "文件现在有未保存的编辑。")
                    continue
                }
                preview[index].action = .running
                do {
                    try await registry.writer.copy(from: source, version: version, sourceRoot: sourceRoot, to: item.destination, destinationVersion: item.destinationVersion, destinationRoot: targetRoot, observation: item.observation, batch: batch)
                    preview[index].action = .finished
                    changed.append(item.destination)
                } catch is CancellationError {
                    preview[index].action = .pending
                } catch {
                    preview[index].action = .failed
                    preview[index].diagnostic = error.comparisonDiagnostic
                }
            }
        }
    }

    func diskChanged(_ target: URL) {
        guard !copying else { return }
        if [left, right].compactMap({ $0 }).contains(where: { target.path.hasPrefix($0.path + "/") }) { refresh() }
    }
}

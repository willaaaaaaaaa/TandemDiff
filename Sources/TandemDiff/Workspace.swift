import AppKit
import TandemDiffCore
import SwiftUI

func comparisonPathURL(_ input: String, relativeTo directory: URL) -> URL? {
    guard !input.isEmpty else { return nil }
    if input.lowercased().hasPrefix("file:") {
        guard let url = URL(string: input), url.isFileURL, url.path.hasPrefix("/"),
              url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else { return nil }
        return url
    }
    guard !input.contains("://") || input.hasPrefix("/") else { return nil }
    let path = (input as NSString).expandingTildeInPath
    return path.hasPrefix("/") ? LocalAccess.exactURL(path) : LocalAccess.appending(path, to: directory)
}

struct SavedPath: Codable {
    let path: String
    let device: UInt64?
    let inode: UInt64?

    init(_ url: URL) {
        path = url.path
        let version = try? FileVersion.read(url)
        device = version?.device
        inode = version?.inode
    }

    func resolve() throws -> URL {
        let url = LocalAccess.exactURL(path)
        try LocalAccess.validate(url)
        let observed = try FileVersion.read(url)
        guard observed.device == device && observed.inode == inode else {
            throw WorkspaceError.pathChanged(path)
        }
        return url
    }
}

enum WorkspaceError: LocalizedError {
    case pathChanged(String)

    var errorDescription: String? {
        switch self {
        case .pathChanged(let path):
            L("This path is missing or has a different identity:", "此路径已经不存在或已被其他项目替代：") + "\n" + path
        }
    }
}

struct SessionRecord: Codable, Identifiable {
    enum Kind: String, Codable { case folders, text }
    var id: UUID
    var name: String?
    var kind: Kind
    var left: SavedPath?
    var right: SavedPath?
    var leftWasMissing = false
    var rightWasMissing = false
    var timestamp = Date()
    var rules: NameRules?
    var folderFilter: String?
    var folderStructure: String?
    var showExcluded: Bool?
    var expansion: Set<Data>?
    var selection: Set<Data>?
    var folderSelectionScope: FolderSelectionScope?
    var folderSelectedSides: [Data: FolderSelectionScope]?
    var folderWriteProtected: Bool?
    var textSettings: TextSessionSettings?
    var inheritedTextProtection: Bool?
    var folderID: UUID?
    var locked: Bool?
    var revision: UUID?
    var notes: String?
}

struct SessionFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var parent: UUID?
}

@MainActor
final class SessionLibrary: ObservableObject {
    private struct Envelope: Codable {
        var version = 1
        var sessions: [SessionRecord]
        var folders: [SessionFolder]?
        var recentTextPaths: [String]?
        var recentFolderPaths: [String]?
    }

    @Published private(set) var records: [SessionRecord] = []
    @Published private(set) var notice: String?
    @Published private(set) var folders: [SessionFolder] = []
    @Published private(set) var recentTextPaths: [String] = []
    @Published private(set) var recentFolderPaths: [String] = []
    private let url: URL
    private var canStore = true

    init(storageURL: URL? = nil) {
        // Keep one session store across app renames.
        let base = URL.applicationSupportDirectory.appendingPathComponent("MarginDiff", isDirectory: true)
        url = storageURL ?? base.appendingPathComponent("sessions.json")
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1 else {
                notice = L("These saved sessions were created in a different TandemDiff version.", "这些会话来自其他版本的 TandemDiff。")
                canStore = false
                return
            }
            records = envelope.sessions
            folders = envelope.folders ?? []
            if let paths = envelope.recentTextPaths {
                recentTextPaths = paths
            } else {
                let recent = records.filter { $0.kind == .text }.sorted { $0.timestamp > $1.timestamp }
                let paths = recent.flatMap { [$0.leftWasMissing ? nil : $0.left?.path, $0.rightWasMissing ? nil : $0.right?.path].compactMap { $0 } }
                recentTextPaths = Self.uniqueRecentPaths(paths)
            }
            let folderPaths = envelope.recentFolderPaths ?? records.filter { $0.kind == .folders }
                .sorted { $0.timestamp > $1.timestamp }
                .flatMap { [$0.left?.path, $0.right?.path].compactMap { $0 } }
            recentFolderPaths = Self.uniqueRecentPaths(folderPaths).filter { Self.isLocalFolder(LocalAccess.exactURL($0)) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            notice = error.comparisonDiagnostic.localized
            canStore = false
        }
    }

    private static func uniqueRecentPaths(_ paths: [String]) -> [String] {
        var seen = Set<Data>()
        return Array(paths.filter { seen.insert(Data($0.utf8)).inserted }.prefix(20))
    }

    func recordTextFile(_ file: URL) {
        let path = file.path
        guard recentTextPaths.first?.utf8.elementsEqual(path.utf8) != true else { return }
        persist(records, folders, recentPaths: Self.uniqueRecentPaths([path] + recentTextPaths))
    }

    private static func isLocalFolder(_ url: URL) -> Bool {
        guard let version = try? FileVersion.read(url) else { return false }
        return version.mode & S_IFMT == S_IFDIR
    }

    func recordFolders(_ urls: [URL]) {
        let paths = urls.filter(Self.isLocalFolder).map(\.path)
        let next = Self.uniqueRecentPaths(paths + recentFolderPaths)
        guard !next.elementsEqual(recentFolderPaths, by: { $0.utf8.elementsEqual($1.utf8) }) else { return }
        persist(records, folders, folderPaths: next)
    }

    func markOpened(_ record: SessionRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        var next = records
        var opened = next.remove(at: index)
        opened.timestamp = .now
        next.insert(opened, at: 0)
        persist(next, folders)
    }

    @discardableResult
    func store(_ record: SessionRecord) -> Bool {
        guard record.name != nil || record.left != nil || record.right != nil else { return false }
        var next = records
        if record.name == nil {
            next.removeAll {
                $0.name == nil && $0.kind == record.kind && $0.left?.path == record.left?.path && $0.right?.path == record.right?.path
            }
        }
        if next.contains(where: { $0.id == record.id && $0.locked == true }) {
            notice = L("Unlock the saved session before saving changes.", "请先解锁已保存的会话，再保存更改。")
            return false
        }
        next.removeAll { $0.id == record.id }
        next.insert(record, at: 0)
        return persist(next.filter { $0.name != nil } + next.filter { $0.name == nil }.prefix(20), folders)
    }

    func saveDefinition(_ record: SessionRecord, replacing original: SessionRecord?) -> Bool {
        var updated = record
        if let original {
            guard let current = records.first(where: { $0.id == original.id }),
                  current.revision == original.revision, current.locked != true else {
                notice = L("This session changed or was removed. Reopen its settings to edit the current version.", "该会话已变更或移除，请重新打开设置后编辑。")
                return false
            }
        }
        guard updated.folderID == nil || folders.contains(where: { $0.id == updated.folderID }) else {
            notice = L("Choose an existing session folder.", "请选择现有会话文件夹。")
            return false
        }
        updated.revision = UUID()
        return store(updated)
    }

    func setLocked(_ locked: Bool, id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.name != nil }) else { return }
        var next = records
        next[index].locked = locked
        persist(next, folders)
    }

    func removeSessions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty,
              records.filter({ ids.contains($0.id) && $0.locked != true }).count == ids.count else {
            notice = L("The selection changed. Select the sessions again to remove them.", "所选会话已变更，请重新选择后移除。")
            return false
        }
        return persist(records.filter { !ids.contains($0.id) }, folders)
    }

    func childFolders(of parent: UUID?) -> [SessionFolder] {
        folders.filter { $0.parent == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var recordsInSidebarOrder: [SessionRecord] {
        let saved = Dictionary(grouping: records.filter { $0.name != nil }, by: \.folderID)
        let now = Date.now
        let recent = records.filter { $0.name == nil }.sorted { $0.timestamp > $1.timestamp }
        let days = Dictionary(grouping: recent) { RecentDay($0.timestamp, now: now) }
        var result = RecentDay.allCases.flatMap { days[$0] ?? [] }
        func appendBranch(_ parent: UUID?) {
            for folder in childFolders(of: parent) { appendBranch(folder.id) }
            result.append(contentsOf: saved[parent] ?? [])
        }
        appendBranch(nil)
        return result
    }

    func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var visited: Set<UUID> = []
        var current: UUID? = id
        while let id = current, visited.insert(id).inserted, let folder = folders.first(where: { $0.id == id }) {
            names.append(folder.name)
            current = folder.parent
        }
        return names.reversed().joined(separator: " / ")
    }

    func saveFolder(_ folder: SessionFolder, replacing original: SessionFolder? = nil) -> Bool {
        let previous = folders.first(where: { $0.id == folder.id })
        guard previous == original, original == nil || original?.parent == folder.parent else {
            notice = L("This session folder changed. Open it again to rename it.", "该会话文件夹已变更，请重新打开后重命名。")
            return false
        }
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, folder.parent == nil || folders.contains(where: { $0.id == folder.parent }),
              !folders.contains(where: { $0.id != folder.id && $0.parent == folder.parent && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            notice = L("Enter a unique name in this session folder.", "请在此会话文件夹内使用唯一名称。")
            return false
        }
        let saved = SessionFolder(id: folder.id, name: name, parent: folder.parent)
        return persist(records, folders.filter { $0.id != folder.id } + [saved])
    }

    func removeFolder(_ id: UUID) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }) else { return false }
        let siblings = folders.filter { $0.parent == folder.parent && $0.id != id }
        if let conflict = folders.first(where: { child in
            child.parent == id && siblings.contains { $0.name.localizedCaseInsensitiveCompare(child.name) == .orderedSame }
        }) {
            notice = L("Rename the nested folder before moving it up:", "请先重命名同名的子文件夹，再将其移至上一级：") + " " + conflict.name
            return false
        }
        var next = records
        for index in next.indices where next[index].folderID == id {
            next[index].folderID = folder.parent
            next[index].revision = UUID()
        }
        var remaining = folders.filter { $0.id != id }
        for index in remaining.indices where remaining[index].parent == id {
            remaining[index].parent = folder.parent
        }
        return persist(next, remaining)
    }

    @discardableResult
    private func persist(_ next: [SessionRecord], _ groups: [SessionFolder], recentPaths: [String]? = nil, folderPaths: [String]? = nil) -> Bool {
        guard canStore else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(sessions: next, folders: groups, recentTextPaths: recentPaths ?? recentTextPaths, recentFolderPaths: folderPaths ?? recentFolderPaths))
            try data.write(to: url, options: [.atomic])
            records = next
            folders = groups
            if let recentPaths { recentTextPaths = recentPaths }
            if let folderPaths { recentFolderPaths = folderPaths }
            notice = nil
            return true
        } catch {
            notice = error.comparisonDiagnostic.localized
            return false
        }
    }
}

@MainActor
final class EditRegistry {
    private struct WeakEditor {
        weak var model: TextSessionModel?
        var id: UUID
    }

    let writer = FileWriter()
    private var editors: [UUID: WeakEditor] = [:]
    private struct CopyPath { let url: URL; let version: FileVersion? }
    private var applyingCopy: [CopyPath] = []
    private let updates = NotificationCenter()

    func register(_ model: TextSessionModel, id: UUID, writable: @escaping () -> Bool) {
        editors = editors.filter { $0.value.model != nil }
        editors[id] = WeakEditor(model: model, id: id)
        model.mayEdit = { [weak self] url in
            writable() && self?.copyInProgress(url) == false
        }
        model.mayBind = { [weak self] url in
            guard let self else { return false }
            return writable() && !self.copyInProgress(url) && !self.hasBinding(url, excluding: id)
        }
        model.mayWrite = { [weak self] url in
            guard let self else { return false }
            return writable() && !self.copyInProgress(url) && !self.hasBinding(url, excluding: id)
        }
    }

    func hasBinding(_ url: URL, excluding id: UUID? = nil) -> Bool {
        editors.values.contains { $0.id != id && $0.model?.hasWritableBinding(url) == true }
    }

    func isDirty(_ url: URL) -> Bool {
        editors.values.contains { $0.model?.isDirty(at: url) == true }
    }

    func children(of ids: Set<UUID>) -> [TextSessionModel] {
        ids.compactMap { editors[$0]?.model }
    }

    func copyStarted(_ paths: Set<URL>) {
        applyingCopy += paths.map { CopyPath(url: $0, version: try? FileVersion.read($0)) }
        editors.values.forEach { $0.model?.objectWillChange.send() }
    }

    func copyFinished(_ paths: Set<URL>) {
        applyingCopy.removeAll { paths.contains($0.url) }
        editors.values.forEach { $0.model?.objectWillChange.send() }
    }

    func copyInProgress(_ url: URL) -> Bool {
        guard !applyingCopy.isEmpty else { return false }
        if applyingCopy.contains(where: { $0.url == url }) { return true }
        guard let version = try? FileVersion.read(url) else { return false }
        return applyingCopy.contains { $0.version?.device == version.device && $0.version?.inode == version.inode }
    }

    func diskChanged(_ url: URL, excluding id: UUID? = nil) {
        for editor in editors.values where editor.id != id {
            editor.model?.diskChanged(url)
        }
        updates.post(name: .tandemDiffDiskChange, object: url)
    }

    func changes() -> NotificationCenter.Publisher { updates.publisher(for: .tandemDiffDiskChange) }
}

extension Notification.Name {
    static let tandemDiffDiskChange = Notification.Name("TandemDiff.diskChange")
}

@MainActor
final class Workspace: ObservableObject {
    struct Tab: Identifiable {
        enum Payload {
            case folders(FolderSession)
            case text(TextSessionModel)
        }

        let id: UUID
        let payload: Payload
        var name: String?
        var parent: UUID?
        var inheritedGuard = false
        var noFolderWrite = false
        var definitionID: UUID?
        var revision: UUID?

        @MainActor var title: String {
            if let name { return name }
            switch payload {
            case .folders(let folder):
                return folder.title
            case .text(let text):
                return text.leftURL?.lastPathComponent ?? text.rightURL?.lastPathComponent ?? L("Text comparison", "文本比较")
            }
        }

        @MainActor func matchesLiveContents(of record: SessionRecord) -> Bool {
            if record.name != nil { return name != nil && revision == record.revision }
            func matches(_ saved: SavedPath?, _ current: URL?) -> Bool {
                switch (saved, current) {
                case (nil, nil): true
                case let (saved?, current?): saved.path.utf8.elementsEqual(current.path.utf8)
                default: false
                }
            }
            switch (record.kind, payload) {
            case (.folders, .folders(let folder)):
                return matches(record.left, folder.left) && matches(record.right, folder.right)
            case (.text, .text(let editor)):
                return matches(record.left, editor.leftURL) && matches(record.right, editor.rightURL)
                    && record.leftWasMissing == editor.pane(.left).missing
                    && record.rightWasMissing == editor.pane(.right).missing
            default: return false
            }
        }

        var tool: HomeTool {
            switch payload {
            case .folders: .folderCompare
            case .text: .textCompare
            }
        }
    }

    @Published var tabs: [Tab] = []
    @Published var active: UUID?
    struct IncomingPair {
        let kind: SessionRecord.Kind
        var left: URL
        var right: URL
    }

    @Published var incoming: IncomingPair?
    @Published var notice: String?
    let registry: EditRegistry
    let library: SessionLibrary
    let sessionDefaults: SessionDefaults

    init(registry: EditRegistry, library: SessionLibrary, sessionDefaults: SessionDefaults = SessionDefaults()) {
        self.registry = registry
        self.library = library
        self.sessionDefaults = sessionDefaults
    }

    var current: Tab? { tabs.first(where: { $0.id == active }) }

    private func activateNewTab(_ tab: Tab) {
        if sessionDefaults.newTabsBesideActive, let index = tabs.firstIndex(where: { $0.id == active }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        active = tab.id
    }

    func makeFolders(left: URL? = nil, right: URL? = nil, restoring: SessionRecord? = nil) {
        let id = restoring?.id ?? UUID()
        if tabs.contains(where: { $0.id == id }) {
            active = id
            return
        }
        let defaults = restoring == nil ? sessionDefaults.folders : FolderSessionDefaults()
        let folder = FolderSession(left: left, right: right, registry: registry, defaults: defaults)
        folder.onOpen = { [weak self, weak folder] entry in
            guard let self, let folder else { return }
            self.openChild(entry, of: folder, id: id)
        }
        folder.onOpenPair = { [weak self, weak folder] left, right in
            guard let self, let folder else { return }
            self.openChild(left: left, right: right, of: folder, id: id)
        }
        folder.onChange = { [weak self] in self?.objectWillChange.send() }
        folder.onRecent = { [weak self] roots in
            if !roots.isEmpty { self?.library.recordFolders(roots) }
            self?.remember(id)
        }
        folder.onProtectChildren = { [weak self] value in
            guard let self else { return false }
            let children = self.tabs.filter { $0.parent == id && !$0.noFolderWrite }
            var commits: [() -> Void] = []
            if value {
                for child in children {
                    if case .text(let editor) = child.payload {
                        guard let commit = await editor.prepareToClose() else { return false }
                        commits.append(commit)
                    }
                }
            }
            guard self.tabs.filter({ $0.parent == id && !$0.noFolderWrite }).map(\.id) == children.map(\.id) else { return false }
            for commit in commits { commit() }
            for child in children {
                if case .text(let editor) = child.payload { editor.setInheritedProtection(value) }
                if let index = self.tabs.firstIndex(where: { $0.id == child.id }) {
                    self.tabs[index].inheritedGuard = value
                }
            }
            return true
        }
        let tab = Tab(id: id, payload: .folders(folder), name: restoring?.name, definitionID: restoring?.name == nil ? nil : restoring?.id, revision: restoring?.revision)
        activateNewTab(tab)
        if let restoring { folder.restore(restoring) }
        library.recordFolders([left, right].compactMap { $0 })
        if left != nil && right != nil { folder.refresh() }
        remember(id)
    }

    func makeText(
        left: URL? = nil, right: URL? = nil,
        leftMissing: Bool = false, rightMissing: Bool = false,
        parent: UUID? = nil, folder: FolderSession? = nil, relativePaths: [String] = [], excluded: Bool = false,
        restoring: SessionRecord? = nil
    ) {
        let id = restoring?.id ?? UUID()
        if tabs.contains(where: { $0.id == id }) {
            active = id
            return
        }
        let leftDuplicate = left.map { registry.hasBinding($0) } ?? false
        let rightDuplicate = right.map { registry.hasBinding($0) } ?? false
        let restoredGuard = restoring?.inheritedTextProtection == true || restoring?.textSettings?.inheritedGuard == true
        let inheritedGuard = excluded || folder?.writeProtected == true || restoredGuard
        let permanentInspection = excluded || (folder == nil && restoredGuard)
        let model = TextSessionModel(
            left: left, right: right, leftMissing: leftMissing, rightMissing: rightMissing,
            leftReadOnly: leftDuplicate || permanentInspection, rightReadOnly: rightDuplicate || permanentInspection,
            inheritedGuard: inheritedGuard, writer: registry.writer
        ) { [weak self] url in
            self?.registry.diskChanged(url, excluding: id)
            self?.remember(id)
            self?.objectWillChange.send()
        }
        model.onFileAccessed = { [weak library] in library?.recordTextFile($0) }
        model.onPathsChanged = { [weak self] in
            self?.remember(id)
            self?.objectWillChange.send()
        }
        model.leftRoot = folder?.left
        model.rightRoot = folder?.right
        let settings = restoring.map { $0.textSettings ?? .legacyDefaults } ?? sessionDefaults.text
        if settings != TextSessionSettings() { model.restore(settings) }
        let boundRoots = [folder?.left, folder?.right].compactMap { $0 }.map(SavedPath.init)
        registry.register(model, id: id) {
            guard let folder, !relativePaths.isEmpty else { return true }
            guard boundRoots.count == 2, boundRoots.allSatisfy({ (try? $0.resolve()) != nil }) else { return false }
            return relativePaths.allSatisfy(folder.rules.admitsTextPath) && !folder.writeProtected
        }
        let tab = Tab(id: id, payload: .text(model), name: restoring?.name, parent: parent, inheritedGuard: inheritedGuard, noFolderWrite: excluded, definitionID: restoring?.name == nil ? nil : restoring?.id, revision: restoring?.revision)
        activateNewTab(tab)
        remember(id)
    }

    private func openChild(_ entry: FolderEntry, of folder: FolderSession, id: UUID) {
        guard !entry.isDirectory, entry.leftText != nil || entry.rightText != nil else {
            notice = entry.reason.isEmpty ? L("No supported text file in this row.", "此行没有可比较的文本文件。") : entry.diagnostic.localized
            return
        }
        guard entry.state != .error && entry.state != .pending && entry.state != .conflict else { return }
        if (entry.left != nil && entry.leftText == nil) || (entry.right != nil && entry.rightText == nil) {
            notice = L("This pair contains an unsupported entry.", "这组条目含有不支持的文件。")
            return
        }
        openChild(left: entry, right: entry, of: folder, id: id)
    }

    private func openChild(left leftEntry: FolderEntry, right rightEntry: FolderEntry, of folder: FolderSession, id: UUID) {
        guard let left = folder.left, let right = folder.right else { return }
        let leftURL = leftEntry.left ?? LocalAccess.appending(leftEntry.path, to: left)
        let rightURL = rightEntry.right ?? LocalAccess.appending(rightEntry.path, to: right)
        let excluded = leftEntry.state == .excluded || rightEntry.state == .excluded
        if let match = tabs.first(where: {
            guard $0.parent == id, $0.noFolderWrite == excluded, case .text(let text) = $0.payload else { return false }
            return text.leftURL == leftURL && text.rightURL == rightURL
        }) {
            active = match.id
        } else {
            makeText(left: leftURL, right: rightURL, leftMissing: leftEntry.left == nil, rightMissing: rightEntry.right == nil,
                     parent: id, folder: folder, relativePaths: [leftEntry.path, rightEntry.path], excluded: excluded)
        }
    }

    func close(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        switch tab.payload {
        case .text(let text):
            guard await text.canClose() else { return }
        case .folders(let folder):
            await folder.close()
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if active == id { active = tab.parent.flatMap { parent in tabs.first { $0.id == parent }?.id } ?? tabs.last?.id }
    }

    func prepareWindowClose() async -> (() async -> Void)? {
        let snapshot = tabs
        var discarded: [() -> Void] = []
        for tab in snapshot {
            if case .text(let text) = tab.payload {
                guard let commit = await text.prepareToClose() else { return nil }
                discarded.append(commit)
            }
        }
        guard tabs.map(\.id) == snapshot.map(\.id) else { return nil }
        return {
            for commit in discarded { commit() }
            for tab in snapshot {
                if case .folders(let folder) = tab.payload { await folder.close() }
            }
        }
    }

    func selectFiles(folders: Bool) {
        let panel = NSOpenPanel()
        panel.prompt = L("Open", "打开")
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { accept(panel.urls) }
    }

    func accept(_ urls: [URL], for kind: SessionRecord.Kind? = nil) {
        openInputs(urls, expected: kind, confirmOrder: true)
    }

    func startIncoming() {
        guard let pair = incoming else { return }
        incoming = nil
        openInputs([pair.left, pair.right], expected: pair.kind, confirmOrder: false)
    }

    private func openInputs(_ urls: [URL], expected: SessionRecord.Kind?, confirmOrder: Bool) {
        guard let left = urls.first, urls.count <= 2 else {
            notice = L("Choose one item or a pair of the same type.", "请选择一个项目，或一对同类型的项目。")
            return
        }
        do {
            let kinds: [SessionRecord.Kind] = try urls.map { url in
                let version = try FileVersion.read(url)
                return version.mode & S_IFMT == S_IFDIR ? .folders : .text
            }
            let kind = kinds[0]
            guard kinds.allSatisfy({ $0 == kind }) else {
                notice = L("Choose two folders or two files.", "请选择两个文件夹，或两个文件。")
                return
            }
            if let expected, expected != kind {
                notice = expected == .folders
                    ? L("Drop folders onto Folder Compare.", "请将文件夹拖到「文件夹比较」上。")
                    : L("Drop text files onto Text Compare.", "请将文本文件拖到「文本比较」上。")
                return
            }
            let right = urls.dropFirst().first
            if confirmOrder, let right {
                incoming = IncomingPair(kind: kind, left: left, right: right)
            } else if kind == .folders {
                makeFolders(left: left, right: right)
            } else {
                makeText(left: left, right: right)
            }
        } catch { notice = error.comparisonDiagnostic.localized }
    }

    func openSessions(_ ids: Set<UUID>) {
        let selected = library.recordsInSidebarOrder.filter { ids.contains($0.id) }
        guard selected.count == ids.count else {
            notice = L("The selection changed. Select the sessions again to open them.", "所选会话已变更，请重新选择后打开。")
            return
        }
        for record in selected { open(record) }
    }

    func open(_ record: SessionRecord) {
        let otherWindows: [(Workspace, NSWindow?)] = (NSApp?.windows ?? []).compactMap { window in
            guard let other = (window.delegate as? WindowGuard)?.workspace, other !== self else { return nil }
            return (other, window)
        }
        var restoration = record
        for (owner, window) in [(self, nil)] + otherWindows {
            let matching = owner.tabs.first { tab in
                let sessionID = record.name == nil ? tab.id : tab.definitionID
                return sessionID == record.id && tab.matchesLiveContents(of: record)
            }
            if let tab = matching {
                owner.active = tab.id
                if let window {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                }
                library.markOpened(record)
                return
            }
            if owner.tabs.contains(where: { $0.id == record.id }) { restoration.id = UUID() }
        }

        func resolve(_ path: SavedPath?, missing: Bool) throws -> URL? {
            guard let path else { return nil }
            if missing {
                let url = LocalAccess.exactURL(path.path)
                try LocalAccess.validate(url.deletingLastPathComponent())
                guard !FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.pathChanged(url.path) }
                return url
            }
            do { return try path.resolve() }
            catch {
                let panel = NSOpenPanel()
                panel.prompt = L("Open", "打开")
                panel.message = L("Locate the original item or select its replacement.", "请找到原项目，或明确选择替代项目。") + "\n" + path.path
                panel.canChooseDirectories = record.kind == .folders
                panel.canChooseFiles = record.kind == .text
                panel.directoryURL = LocalAccess.exactURL(path.path).deletingLastPathComponent()
                guard panel.runModal() == .OK, let url = panel.url else { throw error }
                try LocalAccess.validate(url)
                return url
            }
        }

        do {
            let left = try resolve(record.left, missing: record.leftWasMissing)
            let right = try resolve(record.right, missing: record.rightWasMissing)
            if record.kind == .folders {
                makeFolders(left: left, right: right, restoring: restoration)
            } else {
                makeText(left: left, right: right, leftMissing: record.leftWasMissing, rightMissing: record.rightWasMissing, restoring: restoration)
            }
            if record.name != nil {
                if let index = tabs.firstIndex(where: { $0.id == restoration.id }) {
                    tabs[index].definitionID = record.id
                }
                library.markOpened(record)
            }
        } catch { notice = error.comparisonDiagnostic.localized }
    }

    func remember(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.name == nil else { return }
        if navigationReady(tab) { library.store(snapshot(tab)) }
    }

    private func navigationReady(_ tab: Tab) -> Bool {
        switch tab.payload {
        case .folders(let folder): folder.left != nil && folder.right != nil
        case .text(let editor): editor.leftURL != nil || editor.rightURL != nil
        }
    }

    func saveSession(asNew: Bool, requestName: ((String) -> String?)? = nil) {
        guard let tab = current else { return }
        var record = snapshot(tab)
        let saved = library.records.first(where: { $0.id == tab.definitionID })
        if let saved {
            record.folderID = saved.folderID
            record.notes = saved.notes
        }
        if asNew || record.name == nil {
            let prompt = requestName ?? Self.promptSessionName
            guard let entered = prompt(tab.title) else { return }
            let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            record.name = name
            if tab.name != nil { record.id = UUID() }
        }
        if tab.name != nil, !asNew {
            guard let definition = saved, definition.revision == tab.revision else {
                notice = L("The saved session changed or was removed. Use Save Session As to keep this tab as another session.", "已保存的会话已变更或移除。使用“会话另存为”保留此标签页的设置。")
                return
            }
            record.id = definition.id
            record.revision = UUID()
        }
        guard library.store(record) else {
            notice = library.notice
            return
        }
        if (tab.name == nil || !asNew), let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].name = record.name
            tabs[index].definitionID = record.id
            tabs[index].revision = record.revision
        }
    }

    private static func promptSessionName(_ title: String) -> String? {
        let dialog = NSAlert()
        dialog.messageText = L("Save Session As", "会话另存为")
        dialog.addButton(withTitle: L("Save", "保存"))
        dialog.addButton(withTitle: L("Cancel", "取消"))
        let field = NSTextField(string: title)
        field.frame.size.width = 320
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        return dialog.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func snapshot(_ tab: Tab) -> SessionRecord {
        switch tab.payload {
        case .folders(let folder):
            return SessionRecord(id: tab.id, name: tab.name, kind: .folders, left: folder.left.map(SavedPath.init), right: folder.right.map(SavedPath.init), rules: folder.rules, folderFilter: folder.filter.rawValue, folderStructure: folder.structure.rawValue, showExcluded: folder.showExcluded, expansion: folder.expanded, selection: folder.selection, folderSelectionScope: folder.selectionScope, folderSelectedSides: folder.selectedSides.isEmpty ? nil : folder.selectedSides, folderWriteProtected: folder.writeProtected)
        case .text(let model):
            let left = model.leftURL.map(SavedPath.init)
            let right = model.rightURL.map(SavedPath.init)
            return SessionRecord(id: tab.id, name: tab.name, kind: .text, left: left, right: right, leftWasMissing: model.pane(.left).missing, rightWasMissing: model.pane(.right).missing, textSettings: model.settings, inheritedTextProtection: tab.inheritedGuard)
        }
    }
}

private struct WorkspaceKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

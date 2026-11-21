import AppKit
import TandemDiffCore
import SwiftUI

struct TextSessionSettings: Codable, Equatable {
    var mode: TextViewMode = .all
    static let legacyDefaults = Self(context: 3)
    var context = 6
    var ignoreCase = false
    var ignoreWhitespace = false
    var hideMinor = false
    var leftLocked = false
    var rightLocked = false
    var inheritedGuard = false
}

@MainActor
final class TextPane {
    var url: URL?
    var root: URL?
    var missing: Bool
    let inspectionOnly: Bool
    var busy = false
    var openingURL: URL?
    var savingURL: URL?
    var error: DiagnosticText?
    var baseline: WriteBaseline?
    var buffer = try! TextBuffer()
    private enum Selection {
        case raw(NSRange)
        case display(NSRange, multiple: Bool)
        case unavailable
    }

    private var selected = Selection.raw(NSRange())
    var projection: TextProjection {
        willSet {
            if case .display = selected { selected = selection.map(Selection.raw) ?? .unavailable }
        }
    }
    var selection: NSRange? {
        get {
            switch selected {
            case .raw(let range): return range
            case .display(let range, _): return projection.rawRange(range)
            case .unavailable: return nil
            }
        }
        set { selected = newValue.map(Selection.raw) ?? .unavailable }
    }
    var displaySelection: NSRange? {
        switch selected {
        case .display(let range, _): return range
        case .raw(let raw):
            guard let start = projection.displayOffset(for: raw.location), let end = projection.displayOffset(for: NSMaxRange(raw)) else { return nil }
            return NSRange(location: start, length: max(0, end - start))
        case .unavailable: return nil
        }
    }
    var multipleSelection: Bool {
        if case .display(_, let multiple) = selected { return multiple }
        return false
    }
    func select(display: NSRange, multiple: Bool = false) { selected = .display(display, multiple: multiple) }

    func install(_ buffer: TextBuffer, baseline: WriteBaseline?, side: TextSide) {
        self.buffer = buffer
        self.baseline = baseline
        missing = baseline == nil
        error = nil
        selection = NSRange()
        projection = TextProjection(content: buffer.content, side: side)
    }

    init(url: URL?, missing: Bool, inspectionOnly: Bool) {
        self.url = url
        self.missing = missing
        self.inspectionOnly = inspectionOnly
        projection = TextProjection(content: buffer.content, side: .left)
    }
}

@MainActor
final class TextSessionModel: ObservableObject {
    private final class CloseReservation {
        let released: () -> Void
        init(released: @escaping () -> Void) { self.released = released }
        deinit { released() }
    }

    private weak var closeReservation: CloseReservation?
    private var panes: [TextPane]
    private let writer: FileWriter
    private let onSaved: (URL) -> Void
    var mayEdit: (URL) -> Bool = { _ in true }
    var mayWrite: (URL) -> Bool = { _ in true }
    var mayBind: (URL) -> Bool = { _ in true }
    var onPathsChanged: () -> Void = {}
    var onFileAccessed: (URL) -> Void = { _ in }
    @Published private(set) var settings = TextSessionSettings()
    @Published private(set) var characterDetails: TextCharacterDetails?
    var alignment: TandemDiffCore.TextAlignment? { characterDetails?.alignment }
    @Published private(set) var hunks = [Range<Int>]()
    private(set) var mapBands = [TextMapBand]()
    let mapViewport = TextMapViewport()
    @Published private(set) var activeRow = 0
    @Published private(set) var focused = TextSide.left
    @Published var statusMessage: DiagnosticText?
    var status: String { statusMessage?.localized ?? "" }
    @Published private(set) var aligning = false
    @Published var showFind = false
    @Published var term = ""
    @Published var replacement = ""
    @Published var caseSensitive = true
    @Published private(set) var composing = Set<TextSide>()
    @Published private(set) var navigation = 0
    private var revealed = IndexSet()
    private var pendingFind: (TextSide, NSRange)?
    private var job: Task<Void, Never>?
    private var generation = 0
    private var equivalentPanes = false
    private var scrollSync = false
    var scrollToY = [TextSide: (CGFloat) -> Void]()
    var revealSelection = [TextSide: (NSRange) -> Void]()
    var leftURL: URL? { pane(.left).url }
    var rightURL: URL? { pane(.right).url }
    var leftRoot: URL? { get { pane(.left).root } set { pane(.left).root = newValue } }
    var rightRoot: URL? { get { pane(.right).root } set { pane(.right).root = newValue } }
    var isDirty: Bool { panes.contains { $0.buffer.isDirty } }
    var hiddenCount = 0
    private var comparisonNotice: DiagnosticText?

    init(left: URL?, right: URL?, leftMissing: Bool = false, rightMissing: Bool = false, leftReadOnly: Bool = false, rightReadOnly: Bool = false, inheritedGuard: Bool = false, writer: FileWriter, onSaved: @escaping (URL) -> Void = { _ in }) {
        self.writer = writer
        self.onSaved = onSaved
        panes = [TextPane(url: left, missing: leftMissing, inspectionOnly: leftReadOnly), TextPane(url: right, missing: rightMissing, inspectionOnly: rightReadOnly)]
        settings.inheritedGuard = inheritedGuard
        let initialSides = TextSide.allCases.filter { pane($0).url != nil }
        for side in initialSides { pane(side).busy = true }
        if let left, let right { equivalentPanes = same(left, right) }
        Task { await loadInitial(initialSides) }
    }

    deinit { job?.cancel() }
    func pane(_ side: TextSide) -> TextPane { panes[side.rawValue] }

    private func loadInitial(_ sides: [TextSide]) async {
        for side in sides {
            await load(side)
            let p = pane(side)
            if let url = p.url, p.baseline != nil { onFileAccessed(url) }
        }
        if equivalentPanes { statusMessage = .init("Both panes refer to the same file. Open a different pair to edit.", "两侧引用同一文件。请打开不同的文件进行编辑。") }
        compare()
    }

    private func load(_ side: TextSide) async {
        let p = pane(side)
        guard let url = p.url else { return }
        p.busy = true
        objectWillChange.send()
        do {
            let (baseline, buffer) = try await readBuffer(url, expectedMissing: p.missing, root: p.root)
            p.install(buffer, baseline: baseline, side: side)
        } catch {
            p.error = error.comparisonDiagnostic
            statusMessage = p.error
        }
        p.busy = false
        objectWillChange.send()
    }

    private func readBuffer(_ url: URL, expectedMissing: Bool, root: URL?) async throws -> (WriteBaseline?, TextBuffer) {
        try await Task.detached(priority: .userInitiated) {
            try LocalAccess.validate(url)
            if expectedMissing {
                _ = try FileWriter.checkAbsence(at: url, root: root)
                return (nil, try TextBuffer())
            }
            let baseline = try WriteBaseline.read(url, maxBytes: TextBuffer.maxBytes)
            return (baseline, try TextBuffer(data: baseline.data, format: baseline.kind))
        }.value
    }

    private func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        if a.standardizedFileURL.path.utf8.elementsEqual(b.standardizedFileURL.path.utf8) { return true }
        guard let x = try? FileVersion.read(a), let y = try? FileVersion.read(b) else { return false }
        return x.device == y.device && x.inode == y.inode
    }

    func uses(_ url: URL) -> Bool { panes.contains { same($0.url, url) } }
    func isDirty(at url: URL) -> Bool { TextSide.allCases.contains { (pane($0).buffer.isDirty || composing.contains($0)) && same(pane($0).url, url) } }
    private func binds(_ p: TextPane, _ url: URL) -> Bool {
        same(p.url, url) || same(p.openingURL, url) || same(p.savingURL, url)
    }
    func hasWritableBinding(_ url: URL) -> Bool { panes.contains { !$0.inspectionOnly && binds($0, url) } }
    func locked(_ side: TextSide) -> Bool { equivalentPanes || settings.inheritedGuard || pane(side).inspectionOnly || (side == .left ? settings.leftLocked : settings.rightLocked) }
    func editable(_ side: TextSide, forResolution: Bool = false) -> Bool {
        let p = pane(side)
        return !locked(side) && !p.busy && (forResolution || (p.openingURL == nil && closeReservation == nil)) && p.error == nil && (p.url.map(mayEdit) ?? true)
    }
    var canTransfer: Bool { alignment != nil && composing.isEmpty && !aligning && !panes.contains { $0.busy || $0.error != nil } }
    func describeTransfer(_ from: TextSide) -> String {
        let label = L("Apply change to ", "应用差异到") + label(from.other)
        guard let map = alignment, let change = currentHunk else { return label }
        let interval = map.interval(change, side: from.other)
        let range = interval.isEmpty ? L("insert before line \(interval.lowerBound + 1)", "插入至第 \(interval.lowerBound + 1) 行前") : L("lines \(interval.lowerBound + 1)–\(interval.upperBound)", "第 \(interval.lowerBound + 1)–\(interval.upperBound) 行")
        return label + " · " + range
    }
    var currentHunk: Range<Int>? { hunks.first { $0.contains(activeRow) } }
    var currentNumber: Int? { hunks.firstIndex { $0.contains(activeRow) }.map { $0 + 1 } }

    func restore(_ value: TextSessionSettings) {
        var value = value
        value.inheritedGuard = settings.inheritedGuard || value.inheritedGuard
        settings = value
        compare()
    }
    func updateSettings(_ apply: (inout TextSessionSettings) -> Void) {
        let before = settings
        apply(&settings)
        guard before != settings else { return }
        revealed = []
        if before.ignoreCase != settings.ignoreCase || before.ignoreWhitespace != settings.ignoreWhitespace { compare() }
        else { project() }
    }

    func cancelComparison() {
        generation += 1; job?.cancel(); aligning = false
        characterDetails = nil; hunks = []
        usePlainText()
        comparisonNotice = .init("Comparison stopped. Recompare to apply changes.", "比较已停止。重新比较后可应用更改。")
        statusMessage = comparisonNotice
    }

    private func usePlainText() {
        guard composing.isEmpty else { return }
        for side in TextSide.allCases {
            let p = pane(side)
            p.projection = TextProjection(content: p.buffer.content, side: side)
        }
        objectWillChange.send()
    }

    func compare() {
        if comparisonNotice != nil, statusMessage == comparisonNotice { statusMessage = nil }
        comparisonNotice = nil
        generation += 1
        job?.cancel()
        characterDetails = nil; hunks = []; hiddenCount = 0
        guard composing.isEmpty && !panes.contains(where: { $0.busy || $0.error != nil }) else { aligning = false; return }
        let id = generation
        let left = pane(.left).buffer.content, right = pane(.right).buffer.content
        var options = TextComparisonOptions()
        options.ignoreCase = settings.ignoreCase
        options.ignoreWhitespace = settings.ignoreWhitespace
        aligning = true
        job = Task {
            let compute = Task.detached(priority: .userInitiated) { try TandemDiffCore.TextAlignment(left, right, options: options) }
            do {
                let map = try await withTaskCancellationHandler(operation: { try await compute.value }, onCancel: { compute.cancel() })
                guard id == generation, composing.isEmpty else { return }
                characterDetails = TextCharacterDetails(alignment: map, left: left, right: right)
                if let (side, hit) = pendingFind {
                    revealMatch(side, hit: hit, in: map)
                    pendingFind = nil
                }
                project()
            } catch {
                guard id == generation else { return }
                usePlainText()
                comparisonNotice = error.comparisonDiagnostic
                statusMessage = comparisonNotice
            }
            if id == generation { aligning = false }
        }
    }

    private func project() {
        guard composing.isEmpty, let map = alignment else { return }
        let visible = map.visible(mode: settings.mode, context: settings.context, hideMinor: settings.hideMinor, revealed: revealed)
        hunks = map.hunks(hideMinor: settings.hideMinor)
        mapBands = TextMapBand.collect(from: map, hunks: hunks)
        hiddenCount = settings.hideMinor ? map.rows.filter { $0.kind == .minor }.count : 0
        for side in TextSide.allCases {
            let p = pane(side)
            p.projection = TextProjection(content: p.buffer.content, side: side, map: map, visible: visible, foldLabel: { L("⋯  \($0) folded rows", "⋯  已折叠 \($0) 行") })
        }
        if activeRow >= map.rows.count { activeRow = max(0, map.rows.count - 1) }
        objectWillChange.send()
    }

    func focus(_ side: TextSide) { if side != focused { focused = side } }
    func select(_ side: TextSide, display: NSRange, multiple: Bool, updateFocus: Bool) {
        guard updateFocus, composing.isEmpty else { return }
        focus(side)
        let p = pane(side)
        p.select(display: display, multiple: multiple)
        objectWillChange.send()
        if let row = p.projection.row(at: display.location), let index = p.projection.rows[row].aligned, activeRow != index { activeRow = index }
    }

    func refreshFoldLabels() {
        if pane(.left).projection.rows.contains(where: { $0.fold != nil }) { project() }
    }

    func revealFold(_ range: Range<Int>) { revealed.insert(integersIn: range); project() }
    func syncedScroll(_ side: TextSide, y: CGFloat) {
        guard !scrollSync, composing.isEmpty else { return }
        scrollSync = true; scrollToY[side.other]?(y); scrollSync = false
    }

    func go(_ row: Int) {
        guard composing.isEmpty, let map = alignment, map.rows.indices.contains(row) else { return }
        if settings.mode == .equal, let hunk = hunks.first(where: { $0.contains(row) }), !revealed.contains(integersIn: hunk) {
            revealFold(hunk)
        }
        activeRow = row
        navigation += 1
        for side in TextSide.allCases {
            let p = pane(side)
            if let record = p.projection.rows.first(where: { $0.aligned == row }) {
                let range = NSRange(location: record.offset, length: 0)
                p.select(display: range)
                revealSelection[side]?(range)
            }
        }
    }

    func goToMapRow(_ row: Int) {
        guard !hunks.isEmpty else { return }
        var low = 0, high = hunks.count
        while low < high {
            let mid = (low + high) / 2
            if hunks[mid].upperBound <= row { low = mid + 1 } else { high = mid }
        }
        if low == hunks.count { go(hunks[low - 1].lowerBound); return }
        let next = hunks[low]
        if next.contains(row) { go(row); return }
        if low > 0, row - (hunks[low - 1].upperBound - 1) < next.lowerBound - row {
            go(hunks[low - 1].lowerBound)
        } else {
            go(next.lowerBound)
        }
    }
    func next(_ delta: Int) {
        let next = delta > 0 ? hunks.first { $0.lowerBound > activeRow } ?? hunks.first : hunks.last { $0.upperBound <= activeRow } ?? hunks.last
        if let next { go(next.lowerBound) }
    }

    func beginComposition(_ side: TextSide) {
        guard !composing.contains(side) else { return }
        composing.insert(side)
        generation += 1; job?.cancel(); aligning = false
    }
    func endComposition(_ side: TextSide) { composing.remove(side); compare() }

    @discardableResult
    func edit(_ side: TextSide, raw: NSRange, replacement: String) -> Bool {
        guard editable(side) else { return false }
        let p = pane(side)
        do {
            let before = p.buffer.content.utf16Count
            try p.buffer.replace(raw, with: replacement, keyboardEndings: true)
            p.selection = NSRange(location: raw.location + raw.length + p.buffer.content.utf16Count - before, length: 0)
            edited(side)
            return true
        } catch { statusMessage = error.comparisonDiagnostic; return false }
    }

    private func edited(_ side: TextSide) {
        let p = pane(side)
        pendingFind = nil
        p.projection = TextProjection(content: p.buffer.content, side: side)
        statusMessage = nil
        revealed = []
        compare()
    }

    func convertLineEndings(_ side: TextSide, to ending: String) {
        guard editable(side), composing.isEmpty, ["\n", "\r\n", "\r"].contains(ending) else { return }
        let p = pane(side), content = p.buffer.content
        guard content.lines.contains(where: { !$0.ending.isEmpty && $0.ending != ending }) else { return }
        let offset = p.selection?.location ?? 0
        let line = content.line(atOffset: offset)
        let output = content.lines.map { $0.text + ($0.ending.isEmpty ? "" : ending) }.joined()
        do {
            try p.buffer.replace(NSRange(location: 0, length: content.utf16Count), with: output)
            let newOffset = line.map { p.buffer.content.starts[$0] + min(offset - content.starts[$0], content.lines[$0].text.utf16.count) } ?? 0
            p.selection = NSRange(location: offset == content.utf16Count ? p.buffer.content.utf16Count : newOffset, length: 0)
            edited(side)
        } catch { statusMessage = error.comparisonDiagnostic }
    }

    func history(_ side: TextSide, redo: Bool) {
        guard editable(side), composing.isEmpty else { return }
        do {
            let p = pane(side)
            if redo { try p.buffer.redo() } else { try p.buffer.undo() }
            p.selection = NSRange(location: min(p.selection?.location ?? 0, p.buffer.content.utf16Count), length: 0)
            edited(side)
        } catch { statusMessage = error.comparisonDiagnostic }
    }

    func apply(from side: TextSide, selected: Bool = false) {
        guard canTransfer, editable(side.other), let map = alignment else { return }
        var scope = currentHunk
        let p = pane(side)
        if selected {
            guard !p.multipleSelection else { statusMessage = .init("Select one continuous line range.", "请选择一个连续行范围。"); return }
            guard let display = p.displaySelection, let range = p.projection.selectedRows(display), p.projection.rows[range].contains(where: { $0.line != nil }),
                  !p.projection.rows[range].contains(where: { $0.fold != nil }) else { statusMessage = .init("Reveal the folded lines first.", "请先展开折叠的行。"); return }
            let ids = p.projection.rows[range].compactMap(\.aligned)
            if let first = ids.first, let last = ids.last { scope = first..<(last + 1) }
        }
        guard let scope else { return }
        let src = map.interval(scope, side: side), dest = map.interval(scope, side: side.other)
        let target = pane(side.other)
        do {
            let offset = target.buffer.content.offset(atLine: dest.lowerBound)
            try target.buffer.splice(dest, from: p.buffer.content.lines[src])
            target.selection = NSRange(location: offset, length: 0)
            edited(side.other)
            let target = paneLabel(side.other)
            statusMessage = .init("Applied to " + target.english + " · Unsaved", "已应用到" + target.simplifiedChinese + " · 未保存")
        } catch { statusMessage = error.comparisonDiagnostic }
    }

    func insertSelection(from side: TextSide) {
        let p = pane(side), target = pane(side.other)
        guard canTransfer, editable(side.other), !p.multipleSelection, !target.multipleSelection,
              let source = p.selection, source.length > 0, let destination = target.selection else { return }
        let str = (p.buffer.content.string as NSString).substring(with: source)
        _ = edit(side.other, raw: destination, replacement: str)
    }

    func find(backwards: Bool = false, replace: Bool = false, all: Bool = false) {
        guard !term.isEmpty, composing.isEmpty else { return }
        let side = focused, p = pane(side), text = p.buffer.content.string as NSString
        var options: NSString.CompareOptions = [.literal]
        if !caseSensitive { options.insert(.caseInsensitive) }
        if backwards { options.insert(.backwards) }
        if (replace || all) && !editable(side) { return }
        if all {
            do {
                guard try p.buffer.replaceAll(term, with: replacement, caseSensitive: caseSensitive) else { statusMessage = .init("No matches", "无匹配项"); return }
                p.selection = NSRange(location: 0, length: 0)
                edited(side)
            } catch { statusMessage = error.comparisonDiagnostic }
            return
        }
        if replace, let selection = p.selection, selection.length > 0, text.range(of: term, options: options, range: selection) == selection {
            guard edit(side, raw: selection, replacement: replacement) else { return }
        }
        let fresh = p.buffer.content.string as NSString
        let selection = p.selection ?? NSRange()
        let cursor = backwards ? selection.location : NSMaxRange(selection)
        let search = backwards ? NSRange(location: 0, length: cursor) : NSRange(location: cursor, length: fresh.length - cursor)
        var hit = fresh.range(of: term, options: options, range: search)
        if hit.location == NSNotFound { hit = fresh.range(of: term, options: options) }
        guard hit.location != NSNotFound else { statusMessage = .init("No matches", "无匹配项"); return }
        p.selection = hit
        if let map = alignment { revealMatch(side, hit: hit, in: map); project() }
        else { pendingFind = (side, hit) }
        navigation += 1
        if let display = p.displaySelection { revealSelection[side]?(display) }
    }

    private func revealMatch(_ side: TextSide, hit: NSRange, in map: TandemDiffCore.TextAlignment) {
        let content = pane(side).buffer.content
        guard let first = content.line(atOffset: hit.location), let last = content.line(atOffset: NSMaxRange(hit) - 1) else { return }
        let hits = map.rows.indices.filter { map.rows[$0][side].map { (first...last).contains($0) } ?? false }
        if let start = hits.first, let end = hits.last { revealed.insert(integersIn: start..<(end + 1)); activeRow = start }
    }

    private func paneLabel(_ side: TextSide) -> DiagnosticText {
        let name = pane(side).url?.lastPathComponent
        return DiagnosticText((side == .left ? "Left" : "Right") + " · " + (name ?? "Untitled"), (side == .left ? "左侧" : "右侧") + " · " + (name ?? "未命名"))
    }

    func label(_ side: TextSide) -> String { paneLabel(side).localized }

    var canChangeFiles: Bool {
        closeReservation == nil && composing.isEmpty && !panes.contains { $0.busy || $0.openingURL != nil }
    }

    func swap() {
        guard canChangeFiles else { return }
        panes.swapAt(0, 1)
        let old = settings.leftLocked; settings.leftLocked = settings.rightLocked; settings.rightLocked = old
        revealed = []
        compare()
        onPathsChanged()
    }

    func toggleLock(_ side: TextSide) async {
        guard !settings.inheritedGuard, !pane(side).inspectionOnly, composing.isEmpty else { return }
        if !locked(side), !(await resolve(side)) { return }
        if side == .left { settings.leftLocked.toggle() } else { settings.rightLocked.toggle() }
    }

    func setInheritedProtection(_ value: Bool) {
        settings.inheritedGuard = value
    }

    private enum Resolution { case keep, discard, cancel }

    var promptUnsaved: (String, URL?) -> NSApplication.ModalResponse = { label, url in
        let alert = NSAlert()
        alert.messageText = L("Save changes to ", "保存更改到") + label + "?"
        alert.informativeText = url?.path ?? L("Choose a location to keep these edits.", "选择一个位置以保留这些编辑。")
        alert.addButton(withTitle: L("Save", "保存")); alert.addButton(withTitle: L("Discard", "放弃")); alert.addButton(withTitle: L("Cancel", "取消"))
        return alert.runModal()
    }

    private func decision(_ side: TextSide, forReservation: Bool = false) async -> Resolution {
        let p = pane(side)
        guard !p.busy, composing.isEmpty, forReservation || (p.openingURL == nil && closeReservation == nil) else { return .cancel }
        guard p.buffer.isDirty else { return .keep }
        switch promptUnsaved(label(side), p.url) {
        case .alertFirstButtonReturn: return await save(side, forResolution: forReservation) ? .keep : .cancel
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func discard(_ side: TextSide) -> Bool {
        let p = pane(side)
        do {
            p.buffer = try TextBuffer(data: p.baseline?.data ?? Data(), format: p.baseline?.kind ?? .utf8)
            p.selection = NSRange(location: 0, length: 0)
            edited(side)
            return true
        } catch { statusMessage = error.comparisonDiagnostic; return false }
    }

    private func resolve(_ side: TextSide) async -> Bool {
        switch await decision(side) {
        case .keep: return true
        case .discard: return discard(side)
        case .cancel: return false
        }
    }

    func prepareToClose() async -> (() -> Void)? {
        guard closeReservation == nil, composing.isEmpty, !panes.contains(where: { $0.busy || $0.openingURL != nil }) else { return nil }
        let reservation = CloseReservation { [weak self] in self?.objectWillChange.send() }
        closeReservation = reservation
        objectWillChange.send()
        var discards = [TextSide]()
        for side in TextSide.allCases {
            switch await decision(side, forReservation: true) {
            case .cancel: return nil
            case .discard: discards.append(side)
            case .keep: continue
            }
        }
        return { [self, reservation] in
            withExtendedLifetime(reservation) {
                for side in discards { _ = discard(side) }
            }
        }
    }

    func canClose() async -> Bool {
        guard let commit = await prepareToClose() else { return false }
        commit()
        return true
    }
    func reload(_ side: TextSide? = nil) async {
        let sides = (side.map { [$0] } ?? TextSide.allCases).filter { pane($0).url != nil }
        guard canChangeFiles, !sides.isEmpty else { return }
        let reservation = CloseReservation { [weak self] in self?.objectWillChange.send() }
        closeReservation = reservation
        objectWillChange.send()
        defer { withExtendedLifetime(reservation) {} }
        for side in sides {
            guard await decision(side, forReservation: true) != .cancel else { return }
        }
        do {
            var replacements: [(TextSide, WriteBaseline?, TextBuffer)] = []
            for side in sides {
                let p = pane(side)
                guard let url = p.url else { return }
                let absent = p.missing && (try? FileVersion.read(url)) == nil
                let (baseline, buffer) = try await readBuffer(url, expectedMissing: absent, root: p.root)
                replacements.append((side, baseline, buffer))
            }
            for (side, baseline, buffer) in replacements {
                pane(side).install(buffer, baseline: baseline, side: side)
            }
            revealed = []; pendingFind = nil
            statusMessage = .init("Reloaded from disk.", "已从磁盘重新载入。")
            compare()
        } catch { statusMessage = error.comparisonDiagnostic }
    }

    func diskChanged(_ url: URL) {
        for side in TextSide.allCases where same(pane(side).url, url) {
            let p = pane(side)
            if p.buffer.isDirty || p.busy || p.openingURL != nil || closeReservation != nil || !composing.isEmpty {
                statusMessage = .init("Disk contents changed. Reload or save to another file.", "磁盘内容已更改。请重新载入或另存为其他文件。")
            } else {
                p.busy = true
                if p.missing, (try? FileVersion.read(url)) != nil { p.missing = false }
                objectWillChange.send()
                Task { await load(side); compare() }
            }
        }
    }

    @discardableResult
    func save(_ side: TextSide, asNew: Bool = false, forResolution: Bool = false) async -> Bool {
        let p = pane(side)
        guard editable(side, forResolution: forResolution), composing.isEmpty else { return false }
        var output = p.url, format = p.buffer.format
        let panelRequested = asNew || output == nil
        if panelRequested {
            guard let destination = TextSavePanel.choose(for: side, source: output, format: format) else { return false }
            output = destination.url
            format = destination.format
        }
        guard let chosen = output else { return false }
        let original = same(p.url, chosen)
        let url = original ? (p.url ?? chosen) : chosen
        if original { format = p.buffer.format }
        guard !binds(pane(side.other), url), !same(p.openingURL, url), p.url.map(mayWrite) ?? true, mayWrite(url), (original || mayBind(url)) else {
            statusMessage = .init("Another pane owns this destination. Choose another file.", "其他窗格正在使用此目标。请选择其他文件。")
            return false
        }
        p.busy = true; p.savingURL = url; objectWillChange.send()
        defer { p.busy = false; p.savingURL = nil; objectWillChange.send() }
        do {
            let bytes = try p.buffer.encoded(as: format)
            try LocalAccess.validate(url)
            guard TextEligibility.check(bytes, name: url.lastPathComponent) == format else { throw TextFailure.decode }
            let target: WriteTarget
            if original, let baseline = p.baseline { target = .existing(baseline) }
            else if original || !FileManager.default.fileExists(atPath: url.path) { target = .absent }
            else { target = .existing(try await Task.detached { try WriteBaseline.read(url, maxBytes: TextBuffer.maxBytes) }.value) }
            let destinationRoot = original ? p.root : nil
            let absence: WriteAbsence?
            if case .absent = target { absence = try FileWriter.checkAbsence(at: url, root: destinationRoot) } else { absence = nil }
            if !original || p.missing {
                let alert = NSAlert()
                switch target {
                case .absent: alert.messageText = L("Create this file?", "创建此文件？")
                case .existing: alert.messageText = L("Replace this file?", "替换此文件？")
                }
                alert.informativeText = url.path + "\n" + format.formatName + " · " + FolderMetadata.size(Int64(bytes.count))
                alert.addButton(withTitle: L("Save", "保存")); alert.addButton(withTitle: L("Cancel", "取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
            guard !binds(pane(side.other), url), p.url.map(mayWrite) ?? true, mayWrite(url), original || mayBind(url) else {
                statusMessage = .init("This destination is protected or in use.", "目标已被保护或正在使用中。")
                return false
            }
            try await writer.save(bytes, to: url, expecting: target, root: destinationRoot, absence: absence)
            let committed = try await Task.detached { try WriteBaseline.read(url, maxBytes: TextBuffer.maxBytes) }.value
            guard committed.data == bytes else {
                statusMessage = .init("The file changed after saving. Your edits are still available.", "保存后文件又被更改。编辑仍保留在窗格中。")
                onSaved(url)
                return false
            }
            p.url = url; p.baseline = committed; p.missing = false; p.error = nil
            if !original { p.root = nil }
            p.buffer.markSaved(as: format)
            onFileAccessed(url)
            onSaved(url)
            statusMessage = .init("Saved " + url.path, "已保存 " + url.path)
            return true
        } catch { statusMessage = error.comparisonDiagnostic; return false }
    }
}

extension TextSessionModel {
    func chooseFile(_ side: TextSide) async {
        guard canChangeFiles, !locked(side) else { return }
        let panel = NSOpenPanel()
        panel.prompt = L("Open", "打开")
        panel.title = L("Open file on ", "打开文件到") + label(side)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = pathDirectory(side)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openFile(url, on: side)
    }

    private func pathDirectory(_ side: TextSide) -> URL {
        pane(side).url?.deletingLastPathComponent() ?? pane(side.other).url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func openPath(_ input: String, on side: TextSide) async {
        guard canChangeFiles, !locked(side) else { return }
        guard !input.isEmpty else { statusMessage = .init("Enter a file name or path.", "请输入文件名或路径。"); return }
        guard let url = comparisonPathURL(input, relativeTo: pathDirectory(side)) else {
            statusMessage = .init("Choose a local file path.", "请选择本地文件路径。")
            return
        }
        await openFile(url, on: side)
    }

    func openFile(_ url: URL, on side: TextSide, read: (URL) async throws -> (WriteBaseline, TextBuffer) = { url in
        try await Task.detached(priority: .userInitiated) {
            let baseline = try WriteBaseline.read(url, maxBytes: TextBuffer.maxBytes)
            return (baseline, try TextBuffer(data: baseline.data, format: baseline.kind))
        }.value
    }) async {
        let p = pane(side)
        guard closeReservation == nil, !p.busy, p.openingURL == nil, composing.isEmpty, !locked(side) else { return }
        if same(p.url, url) { await reload(side); return }
        func destinationAvailable() -> Bool {
            guard !binds(pane(side.other), url), mayBind(url) else {
                statusMessage = .init("This file is already bound to another pane.", "此文件已绑定到其他窗格。")
                return false
            }
            return true
        }
        guard destinationAvailable() else { return }
        p.openingURL = url
        objectWillChange.send()
        defer { p.openingURL = nil; objectWillChange.send() }
        let previous = p.buffer, revision = previous.revision
        do {
            let (baseline, buffer) = try await read(url)
            guard destinationAvailable(), await decision(side, forReservation: true) != .cancel,
                  pane(side) === p, p.buffer === previous, previous.revision == revision,
                  !locked(side), destinationAvailable() else { return }
            p.url = url; p.root = nil; p.baseline = baseline; p.missing = false; p.error = nil; p.buffer = buffer
            p.selection = NSRange(); edited(side)
            onFileAccessed(url)
            onPathsChanged()
        } catch { statusMessage = error.comparisonDiagnostic }
    }
}

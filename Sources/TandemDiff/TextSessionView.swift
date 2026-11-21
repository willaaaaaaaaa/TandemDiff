import SwiftUI
import TandemDiffCore

struct TextSessionView: View {
    @ObservedObject var model: TextSessionModel
    let workspace: Workspace
    @AppStorage("textShowsLineNumbers") private var showLineNumbers = true
    @AppStorage("textShowsWhitespace") private var showWhitespace = false
    @AppStorage("textShowsDetails") private var showDetails = true
    @AppStorage("escapeClosesFileView") private var escapeClosesFileView = true
    @State private var showOptions = false
    @State private var showOverview = false
    @State private var closing = false
    @FocusState private var findFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.showFind { Divider(); finder }
            Divider()
            HStack(spacing: 0) {
                TextDifferenceMap(model: model)
                editor(.left)
                Divider()
                VStack(spacing: 9) {
                    Spacer()
                    transfer(.left, symbol: "arrowshape.right.fill")
                    transfer(.right, symbol: "arrowshape.left.fill")
                    Spacer()
                }.frame(width: 34).background(TandemDiffStyle.canvas)
                Divider()
                editor(.right)
            }
            if showDetails { Divider(); detail }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.composing.isEmpty ? "info.circle" : "keyboard")
                Text(status).lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.hiddenCount > 0 {
                    Button(L("Reveal \(model.hiddenCount) minor rows", "显示 \(model.hiddenCount) 行细微差异")) {
                        model.updateSettings { $0.hideMinor = false }
                    }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
        }.background(TandemDiffStyle.canvas)
        .focusedSceneObject(model)
        .background {
            ComparisonNavigationKeys(disabled: !model.canNavigateDifferences, previous: { model.next(-1) }, next: { model.next(1) }, handlesFieldClipboard: true, escape: handleEscape)
                .frame(width: 0, height: 0)
        }
    }

    private func handleEscape(editingField: Bool) -> Bool {
        guard model.composing.isEmpty, !showOptions, !showOverview else { return false }
        if model.showFind {
            model.showFind = false
            return true
        }
        guard !editingField, escapeClosesFileView, let tab = workspace.current,
              tab.parent != nil, case .text(let active) = tab.payload, active === model else { return false }
        if !closing {
            closing = true
            Task {
                await workspace.close(tab.id)
                closing = false
            }
        }
        return true
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ComparisonSessionControls(workspace: workspace) {
                        Button(L("Recompare edited text", "重新比较当前文本")) { model.compare() }
                            .disabled(!model.canRefreshComparison)
                    }
                    ComparisonToolDivider()
                    ComparisonViewControls(mode: $model.comparisonDisplay) { EmptyView() }
                        .disabled(!model.composing.isEmpty)
                    ComparisonToolButton(L("Context", "上下文"), "text.line.first.and.arrowtriangle.forward", ink: TextCommandInk.secondary, selected: model.settings.mode == .context) {
                        model.updateSettings { $0.mode = $0.mode == .context ? .changes : .context }
                    }.disabled(!model.composing.isEmpty)
                    ComparisonToolDivider()
                    ComparisonToolButton(L("Rules", "规则"), "slider.horizontal.3", ink: TextCommandInk.secondary) { showOptions.toggle() }
                        .popover(isPresented: $showOptions) { options }
                    ComparisonToolMenu(title: L("Format", "格式"), symbol: "doc.badge.gearshape.fill", ink: TextCommandInk.secondary, help: L("Text display and line endings", "文本显示与换行符")) {
                        Toggle(L("Line numbers", "显示行号"), isOn: $showLineNumbers)
                        Toggle(L("Visible whitespace", "显示空白字符"), isOn: $showWhitespace)
                        Toggle(L("Line details", "显示行详情"), isOn: $showDetails)
                        Divider()
                        Menu(L("Line endings · ", "换行符 · ") + model.label(model.focused)) {
                            Button("LF (Unix)") { model.convertLineEndings(model.focused, to: "\n") }
                            Button("CRLF (Windows)") { model.convertLineEndings(model.focused, to: "\r\n") }
                            Button(L("CR (Classic Mac)", "CR（经典 Mac）")) { model.convertLineEndings(model.focused, to: "\r") }
                        }.disabled(!model.editable(model.focused) || !model.composing.isEmpty)
                    }
                    ComparisonToolDivider()
                    let source = model.focused
                    let hasSelection = (model.pane(source).displaySelection?.length ?? 0) > 0
                    ComparisonToolButton(L("Copy", "复制"), source == .left ? "arrow.right.to.line" : "arrow.left.to.line", ink: TandemDiffStyle.accent,
                         help: L("Copy to ", "复制到") + model.label(source.other)) {
                        model.apply(from: source, selected: hasSelection)
                    }.disabled(!model.canTransfer || !model.editable(source.other) || model.pane(source).multipleSelection || (!hasSelection && model.currentHunk == nil))
                    ComparisonNavigationControls(previous: { model.next(-1) }, next: { model.next(1) }, disabled: !model.canNavigateDifferences)
                    ComparisonToolDivider()
                    ComparisonToolButton(L("Swap", "交换"), "arrow.left.arrow.right", ink: TandemDiffStyle.accent, help: L("Swap sides", "交换两侧") + " (⇧⌘X)") { model.swap() }
                        .disabled(!model.canChangeFiles)
                    ComparisonToolButton(L("Reload", "重载"), "arrow.clockwise", ink: TandemDiffStyle.accent, help: L("Reload files from disk", "从磁盘重新载入文件")) {
                        Task { await model.reload() }
                    }.disabled(!model.canChangeFiles || (model.leftURL == nil && model.rightURL == nil))
                    ComparisonToolButton(L("Find", "查找"), "magnifyingglass", ink: TextCommandInk.secondary, selected: model.showFind, help: L("Find and replace", "查找和替换") + " (⌘F)") {
                        model.showFind.toggle(); findFocus = model.showFind
                    }.keyboardShortcut("f", modifiers: .command)
                }.padding(.horizontal, 6).padding(.vertical, 3)
            }.scrollIndicators(.automatic)
            Spacer(minLength: 0)
            if model.aligning {
                Button(L("Stop", "停止")) { model.cancelComparison() }
            } else {
                Button {
                    showOverview.toggle()
                } label: {
                    Text(model.currentNumber.map { "\($0) / \(model.hunks.count)" } ?? L("\(model.hunks.count) changes", "\(model.hunks.count) 处差异"))
                        .monospacedDigit()
                }.buttonStyle(.borderless).disabled(model.hunks.isEmpty).help(L("Change overview", "差异概览"))
                    .popover(isPresented: $showOverview) { overview }
            }
        }.controlSize(.small).padding(.trailing, 12)
    }

    private var status: String {
        if !model.composing.isEmpty { return L("Composing text", "正在使用输入法组合文本") }
        if !model.status.isEmpty { return model.status }
        if model.aligning { return L("Comparing lines…", "正在比较行…") }
        if model.pane(.left).buffer.format != model.pane(.right).buffer.format {
            return L("Encoding differs", "编码不同") + " · " + model.pane(.left).buffer.format.formatName + " ↔ " + model.pane(.right).buffer.format.formatName
        }
        if model.leftURL == nil && model.rightURL == nil && TextSide.allCases.allSatisfy({ model.pane($0).buffer.content.utf16Count == 0 && model.editable($0) }) {
            return L("Type or paste text on either side, or enter a file path above and press Return.", "在两侧输入或粘贴文本，或在上方输入文件路径后按回车。")
        }
        return L("Left and right save independently.", "左右两侧分别保存。")
    }

    private func setting<T>(_ path: WritableKeyPath<TextSessionSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { new in model.updateSettings { $0[keyPath: path] = new } })
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("Ignore case", "忽略大小写"), isOn: setting(\.ignoreCase))
            Toggle(L("Ignore spaces and tabs", "忽略空格与制表符"), isOn: setting(\.ignoreWhitespace))
            Toggle(L("Hide minor changes", "隐藏细微差异"), isOn: setting(\.hideMinor))
            Divider()
            Stepper(value: setting(\.context), in: 0...100) { Text(L("Context lines", "上下文行数") + "  \(model.settings.context)") }
        }.toggleStyle(.checkbox).padding(16).frame(width: 230)
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.hunks.enumerated()), id: \.element.lowerBound) { number, range in
                    let left = model.alignment?.interval(range, side: .left)
                    let right = model.alignment?.interval(range, side: .right)
                    Button {
                        showOverview = false; model.go(range.lowerBound)
                    } label: {
                        HStack {
                            Text("#\(number + 1)").frame(width: 38, alignment: .leading)
                            Text(L("Left", "左") + " \((left?.lowerBound ?? 0) + 1)"); Spacer()
                            Text(L("Right", "右") + " \((right?.lowerBound ?? 0) + 1)")
                        }.padding(4)
                    }.buttonStyle(.plain)
                }
            }.padding(10)
        }.frame(width: 230, height: min(300, CGFloat(model.hunks.count * 32 + 20)))
    }

    private var finder: some View {
        HStack(spacing: 6) {
            TextField(L("Find in ", "查找于") + model.label(model.focused), text: $model.term).focused($findFocus).onSubmit { model.find() }
            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.left") }.accessibilityLabel(L("Previous match", "上一个匹配"))
            Button { model.find() } label: { Image(systemName: "chevron.right") }.accessibilityLabel(L("Next match", "下一个匹配"))
            Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button).help(L("Match case", "区分大小写"))
            TextField(L("Replace with", "替换为"), text: $model.replacement)
            Button(L("Replace", "替换")) { model.find(replace: true) }
            Button(L("All", "全部替换")) { model.find(all: true) }
            Button { model.showFind = false } label: { Image(systemName: "xmark") }.accessibilityLabel(L("Close find", "关闭查找"))
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func transfer(_ from: TextSide, symbol: String) -> some View {
        let name = model.describeTransfer(from)
        return Button { model.apply(from: from) } label: {
            TextCommandIcon(symbol: symbol, ink: TandemDiffStyle.accent).frame(width: 19, height: 23)
        }.buttonStyle(.borderless).help(name + (from == .left ? " (⌘⌥→)" : " (⌘⌥←)")).accessibilityLabel(name)
            .disabled(!model.canApplyChange(from: from))
    }

    private func editor(_ side: TextSide) -> some View {
        let p = model.pane(side)
        return VStack(spacing: 0) {
            TextFileBar(model: model, side: side, library: workspace.library)
            Divider()
            if let error = p.error {
                ContentUnavailableView { Label(L("Could not open text", "无法打开文本"), systemImage: "exclamationmark.triangle") }
                    description: { Text(error.localized) }
            } else { TextNativeView(model: model, side: side, showLineNumbers: showLineNumbers, showWhitespace: showWhitespace) }
            Divider()
            HStack(spacing: 8) {
                Text(p.buffer.format.formatName)
                Text(p.buffer.content.endingSummary.isEmpty ? L("No separator", "无换行符") : p.buffer.content.endingSummary)
                if p.missing { Text(L("Missing on disk", "磁盘上不存在")) }
                Spacer(minLength: 2)
                Text(position(p)).monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 23)
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func position(_ p: TextPane) -> String {
        let raw = p.buffer.content
        guard let selection = p.selection else { return "—" }
        let line = raw.line(atOffset: selection.location)
        if selection.location == raw.utf16Count, let last = raw.lines.last, !last.ending.isEmpty {
            return L("Ln \(raw.lines.count + 1)  Col 1", "行 \(raw.lines.count + 1)  列 1")
        }
        let start = line.map { raw.starts[$0] } ?? 0
        let col = (raw.string as NSString).substring(with: NSRange(location: start, length: max(0, min(raw.utf16Count, selection.location) - start))).count + 1
        return L("Ln \((line ?? 0) + 1)  Col \(col)", "行 \((line ?? 0) + 1)  列 \(col)")
    }

    @ViewBuilder private var detail: some View {
        if let map = model.alignment, map.rows.indices.contains(model.activeRow) {
            let row = map.rows[model.activeRow]
            let a = row.left.map { model.pane(.left).buffer.content.lines[$0] }
            let b = row.right.map { model.pane(.right).buffer.content.lines[$0] }
            let spans = model.characterDetails?.spans(at: model.activeRow)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    detailGutter(.left, index: row.left, line: a, highlightEnding: a?.ending != b?.ending && b != nil)
                    detailGutter(.right, index: row.right, line: b, highlightEnding: a?.ending != b?.ending && a != nil)
                }
                .padding(.horizontal, 8)
                Divider()
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        detailText(a, kind: row.kind, spans: spans?.left)
                        detailText(b, kind: row.kind, spans: spans?.right)
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .top) { Divider().offset(y: detailRowHeight).allowsHitTesting(false) }
            .background(TandemDiffStyle.surface)
        }
    }

    private let detailRowHeight: CGFloat = 24

    private func detailGutter(_ side: TextSide, index: Int?, line: TextLine?, highlightEnding: Bool) -> some View {
        let eol: String = switch line?.ending { case "\r\n": "CRLF"; case "\r": "CR"; case "\n": "LF"; case "": "EOF"; default: "" }
        return HStack(spacing: 5) {
            Text(side == .left ? L("Left", "左") : L("Right", "右"))
                .fontWeight(.semibold)
            Text(index.map { "\($0 + 1)" } ?? "—").monospacedDigit()
            Spacer(minLength: 4)
            Text(eol).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(highlightEnding ? Color(nsColor: TextDiffPalette.changedText) : .secondary)
        }
        .font(.caption).foregroundStyle(.secondary).frame(minWidth: 76)
        .fixedSize(horizontal: true, vertical: false).frame(height: detailRowHeight)
    }

    private func detailText(_ line: TextLine?, kind: TextRowKind, spans: [NSRange]?) -> some View {
        let value = line?.text ?? ""
        let limited = spans == nil || value.utf8.count > TandemDiffCore.TextAlignment.detailLimit
        var result = AttributedString(limited ? L("Character detail limit reached", "字符详情已达到上限") : value)
        if line == nil { result = AttributedString("—"); result.foregroundColor = .secondary }
        for range in limited ? [] : spans ?? [] {
            if let swiftRange = Range(range, in: value), let attrRange = Range(swiftRange, in: result) {
                if kind == .minor {
                    result[attrRange].backgroundColor = .secondary.opacity(0.2)
                } else {
                    result[attrRange].foregroundColor = Color(nsColor: TextDiffPalette.changedText)
                    result[attrRange].backgroundColor = Color(nsColor: TextDiffPalette.changedRow)
                }
            }
        }
        return Text(result).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .fixedSize().frame(height: detailRowHeight)
    }
}

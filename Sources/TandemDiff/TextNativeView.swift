import AppKit
import SwiftUI
import TandemDiffCore

private final class ComparisonTextView: NSTextView {
    var ownedStorage: NSTextStorage?
    var projection: TextProjection?
    var characterDetails: TextCharacterDetails?
    var side: TextSide = .left
    private var coloredRows = IndexSet()
    var onComposition: ((Bool) -> Void)?
    var onFold: ((Range<Int>) -> Void)?
    var onFocus: (() -> Void)?
    var onHistory: ((Bool) -> Void)?
    var ownsComposition = false
    var rendering = false
    var focusWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, let window else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.isEditable,
                  window.firstResponder === window, window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditable else { return }
        if !ownsComposition {
            clearChangeColors()
            ownsComposition = true
            onComposition?(true)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        finishCompositionIfNeeded()
    }

    override func unmarkText() {
        super.unmarkText()
        // insertText can call unmarkText internally before it replaces the marked range.
        DispatchQueue.main.async { [weak self] in self?.finishCompositionIfNeeded() }
    }

    func finishCompositionIfNeeded() {
        if ownsComposition && !hasMarkedText() {
            ownsComposition = false
            onComposition?(false)
        }
    }

    override func copy(_ sender: Any?) {
        guard !ownsComposition, let projection else { super.copy(sender); return }
        let parts = selectedRanges.map { projection.clipboardText(in: $0.rangeValue) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(parts.joined(separator: "\n"), forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        if ownsComposition { super.keyDown(with: event); finishCompositionIfNeeded(); return }
        if !hasMarkedText(), event.modifierFlags.intersection([.control, .option, .command, .shift]) == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return
            case "v": if isEditable { pasteAsPlainText(nil) }; return
            default: break
            }
        }
        if event.keyCode == 36, let row = projection?.row(at: selectedRange().location), let fold = projection?.rows[row].fold { onFold?(fold); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, !ownsComposition, event.charactersIgnoringModifiers?.lowercased() == "z", flags == [.command] || flags == [.command, .shift] {
            onHistory?(flags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let row = projection?.row(at: index), let fold = projection?.rows[row].fold { onFold?(fold); return }
        super.mouseDown(with: event)
    }

    func visibleLines(in dirty: NSRect, _ body: @escaping (Int, TextProjection.Row, NSRect) -> Void) {
        guard !ownsComposition, let projection, let layout = layoutManager, let container = textContainer, !projection.rows.isEmpty else { return }
        let origin = textContainerOrigin
        let area = dirty.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            guard range.length > 0 else { return }
            let offset = layout.characterIndexForGlyph(at: range.location)
            guard let index = projection.row(at: offset) else { return }
            body(index, projection.rows[index], rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        // A final alignment spacer has no glyph, even when it represents the whole empty side.
        if let last = projection.rows.last, last.line == nil, last.fold == nil, last.offset == textStorage?.length {
            let extra = layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            let line = NSRect(x: origin.x, y: extra.minY, width: dirty.width, height: max(extra.height, defaultParagraphStyle?.minimumLineHeight ?? 0))
            if line.maxY > dirty.minY && line.minY < dirty.maxY { body(projection.rows.count - 1, last, line) }
        }
    }

    func clearChangeColors() {
        if !coloredRows.isEmpty, let length = textStorage?.length, length > 0 {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        }
        coloredRows.removeAll()
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = dirtyRect.intersection(visibleRect)
        if !visible.isEmpty, let layout = layoutManager, let characterDetails {
            visibleLines(in: visible) { [self] index, row, _ in
                guard row.kind == .change, let aligned = row.aligned, row.line != nil,
                      row.length > 0, !coloredRows.contains(index) else { return }
                coloredRows.insert(index)
                guard let changes = characterDetails.spans(at: aligned) else { return }
                for range in side == .left ? changes.left : changes.right {
                    let display = NSRange(location: row.offset + range.location, length: range.length)
                    layout.addTemporaryAttribute(.foregroundColor, value: TextDiffPalette.changedText, forCharacterRange: display)
                }
            }
        }
        super.draw(dirtyRect)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let visible = rect.intersection(visibleRect)
        guard !visible.isEmpty else { return }
        visibleLines(in: visible) { _, row, line in
            let band = NSRect(x: visible.minX, y: line.minY, width: visible.width, height: line.height)
            let color: NSColor
            if row.fold != nil { color = NSColor.tertiaryLabelColor.withAlphaComponent(0.10) }
            else if row.line == nil {
                let hatch = NSBezierPath()
                let step: CGFloat = 7
                var x = floor(band.minX / step) * step
                while x < band.maxX + band.height {
                    hatch.move(to: NSPoint(x: x, y: band.minY))
                    hatch.line(to: NSPoint(x: x - band.height, y: band.maxY))
                    x += step
                }
                NSColor.separatorColor.setStroke()
                hatch.lineWidth = 0.7
                hatch.stroke()
                return
            } else {
                switch row.kind {
                case .equal: return
                case .change: color = TextDiffPalette.changedRow
                case .minor: color = NSColor.systemGray.withAlphaComponent(0.10)
                case .ending: color = NSColor.systemBlue.withAlphaComponent(0.10)
                }
            }
            color.setFill()
            band.fill()
        }
    }
}

private final class TextLineRuler: NSRulerView {
    weak var editor: ComparisonTextView?
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); rect.fill()
        guard let editor else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        editor.visibleLines(in: editor.visibleRect) { _, row, line in
            var label = row.line.map { String($0 + 1) } ?? "·"
            switch row.kind {
            case .change: label += " •"
            case .minor: label += " ≈"
            case .ending: label += " ↵"
            case .equal: label += "  "
            }
            let value = label as NSString, size = value.size(withAttributes: attributes)
            let point = self.convert(NSPoint(x: 0, y: line.midY), from: editor)
            value.draw(at: NSPoint(x: self.ruleThickness - size.width - 5, y: point.y - size.height / 2), withAttributes: attributes)
        }
    }
}

struct TextNativeView: NSViewRepresentable {
    @ObservedObject var model: TextSessionModel
    let side: TextSide
    var showLineNumbers = true
    var showWhitespace = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model, side: side) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        let editor = ComparisonTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        editor.side = side
        editor.ownedStorage = storage
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.usesFindBar = false
        editor.allowsUndo = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19; paragraph.maximumLineHeight = 19
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        if model.leftURL == nil && model.rightURL == nil && !model.isDirty {
            editor.focusWhenAttached = model.editable(side) && side == (model.editable(.left) ? .left : .right)
        }
        scroll.documentView = editor
        let ruler = TextLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clipsToBounds = true
        ruler.editor = editor; ruler.clientView = editor; ruler.ruleThickness = 53
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.attach(editor, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.documentView?.setAccessibilityLabel(side == .left ? L("Left text editor", "左侧文本编辑器") : L("Right text editor", "右侧文本编辑器"))
        if scroll.rulersVisible != showLineNumbers { scroll.rulersVisible = showLineNumbers }
        if let layout = (scroll.documentView as? NSTextView)?.layoutManager, layout.showsInvisibleCharacters != showWhitespace {
            layout.showsInvisibleCharacters = showWhitespace
        }
        context.coordinator.render()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TextSessionModel, side: TextSide
        private weak var editor: ComparisonTextView?
        private weak var scroll: NSScrollView?
        private var originalComposition: String?
        private var nav = -1
        private var viewportUpdatePending = false

        init(model: TextSessionModel, side: TextSide) { self.model = model; self.side = side }

        fileprivate func attach(_ view: ComparisonTextView, scroll: NSScrollView) {
            editor = view; self.scroll = scroll
            view.delegate = self
            view.onFocus = { [weak self] in guard let self else { return }; self.model.focus(self.side) }
            view.onHistory = { [weak self] redo in guard let self else { return }; self.model.history(self.side, redo: redo); self.render() }
            view.onFold = { [weak self] in self?.model.revealFold($0); self?.render() }
            view.onComposition = { [weak self] begins in self?.composition(begins) }
            model.scrollToY[side] = { [weak self] y in
                guard let scroll = self?.scroll else { return }
                let clip = scroll.contentView
                let target = min(y, max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height))
                guard abs(clip.bounds.minY - target) > 0.5 else { return }
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scroll.reflectScrolledClipView(clip)
            }
            model.revealSelection[side] = { [weak self] range in
                guard let self else { return }
                self.render()
                guard let editor = self.editor, !editor.ownsComposition, NSMaxRange(range) <= editor.string.utf16.count else { return }
                editor.rendering = true
                editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
                editor.rendering = false
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            render()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if editor?.ownsComposition == true { model.endComposition(side) }
            model.scrollToY[side] = nil
            model.revealSelection[side] = nil
        }

        @objc private func scrolled() {
            guard let scroll else { return }
            scroll.verticalRulerView?.needsDisplay = true
            if editor?.rendering == false { model.syncedScroll(side, y: scroll.contentView.bounds.minY) }
            scheduleViewportUpdate()
        }

        private func scheduleViewportUpdate() {
            guard !viewportUpdatePending, model.alignment != nil, side == .left || model.pane(.left).error != nil else { return }
            viewportUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                viewportUpdatePending = false
                guard let editor, let projection = editor.projection, projection === model.pane(side).projection,
                      let layout = editor.layoutManager, let container = editor.textContainer,
                      !editor.ownsComposition, !editor.visibleRect.isEmpty else { return }
                var visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
                visible.origin.x = 0
                let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let first = projection.row(at: chars.location).map { projection.rows[$0] }
                var last = projection.row(at: chars.location + max(0, chars.length - 1)).map { projection.rows[$0] }
                if layout.extraLineFragmentTextContainer != nil, visible.intersects(layout.extraLineFragmentRect) {
                    last = projection.rows.last
                }
                let start = first?.aligned ?? first?.fold?.lowerBound
                let end = last?.aligned.map { $0 + 1 } ?? last?.fold?.upperBound
                let rows: Range<Int>? = if let start, let end, start < end { start..<end } else { nil }
                if model.mapViewport.rows != rows { model.mapViewport.rows = rows }
            }
        }

        func render() {
            guard let editor, !editor.ownsComposition, !editor.hasMarkedText(), model.composing.isEmpty else { return }
            let p = model.pane(side), projection = p.projection
            editor.isEditable = model.editable(side)
            let changed = editor.projection !== projection || editor.characterDetails !== model.characterDetails
            guard changed || nav != model.navigation else { return }
            nav = model.navigation
            scheduleViewportUpdate()
            editor.rendering = true
            defer { editor.rendering = false }
            if changed {
                editor.clearChangeColors()
                editor.projection = projection
                editor.characterDetails = model.characterDetails
            }
            if changed && !editor.string.utf8.elementsEqual(projection.string.utf8) {
                editor.string = projection.string
            }
            let range = p.displaySelection ?? NSRange()
            if editor.selectedRange() != range || (!p.multipleSelection && editor.selectedRanges.count > 1) { editor.setSelectedRange(range) }
            editor.needsDisplay = true; scroll?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor, !editor.rendering, !editor.ownsComposition, !editor.hasMarkedText(), editor.projection === model.pane(side).projection else { return }
            model.select(side, display: editor.selectedRange(), multiple: editor.selectedRanges.count > 1, updateFocus: editor.window?.firstResponder === editor)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let editor, !editor.rendering else { return true }
            if editor.ownsComposition || editor.hasMarkedText() { return true }
            guard let replacementString, let projection = editor.projection, let raw = projection.rawRange(affectedCharRange) else {
                model.statusMessage = .init("Reveal folded rows or select editable text.", "请展开折叠行或选择可编辑文本。")
                return false
            }
            if model.edit(side, raw: raw, replacement: replacementString) { render(); editor.scrollRangeToVisible(editor.selectedRange()) }
            return false
        }

        private func composition(_ begins: Bool) {
            guard let editor else { return }
            if begins { originalComposition = editor.string; model.beginComposition(side); return }
            defer { originalComposition = nil; model.endComposition(side); render() }
            guard let original = originalComposition else { return }
            let old = original as NSString, new = editor.string as NSString
            var prefix = 0
            while prefix < min(old.length, new.length) && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            if prefix == old.length && prefix == new.length { return }
            if prefix > 0 && UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
            var a = old.length, b = new.length
            while a > prefix && b > prefix && old.character(at: a - 1) == new.character(at: b - 1) { a -= 1; b -= 1 }
            if a < old.length && UTF16.isTrailSurrogate(old.character(at: a)) { a += 1; b += 1 }
            let display = NSRange(location: prefix, length: a - prefix)
            guard let raw = editor.projection?.rawRange(display), model.edit(side, raw: raw, replacement: new.substring(with: NSRange(location: prefix, length: b - prefix))) else {
                editor.rendering = true; editor.string = original; editor.rendering = false
                return
            }
        }
    }
}

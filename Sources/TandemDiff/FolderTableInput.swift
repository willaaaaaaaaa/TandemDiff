import AppKit
import TandemDiffCore
import SwiftUI

/// SwiftUI exposes the selected row IDs. The native table supplies the clicked column.
struct FolderTableInput: NSViewRepresentable {
    let session: FolderSession
    let compare: (Set<Data>) -> Void

    final class Anchor: NSView {
        var input: FolderTableInput?
        var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil, !isHiddenOrHasHiddenAncestor else { return false }
            if event.type == .keyDown {
                return window.isKeyWindow && handleSelectionKey(event, responder: window.firstResponder)
            }
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) {
                if let input, let hit = tableHit(for: event) {
                    let modifiers = event.modifierFlags.intersection([.command, .shift, .option])
                    if modifiers == .command, let side = hit.side {
                        let rows = input.session.rows
                        let entry = rows[hit.row].entry
                        guard entry.url(on: side) != nil else { return true }
                        let selectedIDs = Set(hit.table.selectedRowIndexes.map { rows[$0].id })
                        input.session.toggleSelectedSide(side, of: entry, extending: selectedIDs)
                        let selection = input.session.selection
                        hit.table.selectRowIndexes(IndexSet(rows.indices.filter { selection.contains(rows[$0].id) }), byExtendingSelection: false)
                        window.makeFirstResponder(hit.table)
                        return true
                    }
                    input.session.selectionScope = FolderSelectionScope(side: hit.side)
                }
                return false
            }
            guard let (table, menu) = pointerMenu(for: event) else { return false }
            window.makeFirstResponder(table)
            NSMenu.popUpContextMenu(menu, with: event, for: table)
            return true
        }

        func handleSelectionKey(_ event: NSEvent, responder: NSResponder?) -> Bool {
            guard let input, !(responder is NSText), let table = ancestorTable(of: responder as? NSView),
                  bounds.intersects(convert(table.visibleRect, from: table)) else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
            guard (modifiers == .control || modifiers == .command), event.charactersIgnoringModifiers?.lowercased() == "a",
                  !input.session.copying, table.numberOfRows == input.session.rows.count else { return false }
            table.selectAll(nil)
            recordSelectAll(in: table)
            return true
        }

        @objc func menuDidSendAction(_ note: Notification) {
            guard let item = note.userInfo?["MenuItem"] as? NSMenuItem, let action = item.action,
                  action == #selector(NSTableView.selectAll(_:)),
                  let table = NSApp.target(forAction: action, to: item.target, from: item) as? NSTableView,
                  table.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.intersects(convert(table.visibleRect, from: table)) else { return }
            recordSelectAll(in: table)
        }

        private func recordSelectAll(in table: NSTableView) {
            guard let session = input?.session, !session.copying, table.numberOfSelectedRows > 0,
                  table.numberOfSelectedRows == session.rows.count else { return }
            session.selection = Set(session.rows.map(\.id))
            session.selectionScope = .all
        }

        func pointerMenu(for event: NSEvent) -> (NSTableView, NSMenu)? {
            guard let input,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  let hit = tableHit(for: event) else { return nil }
            let table = hit.table
            let rows = input.session.rows
            let id = rows[hit.row].id
            if let scope = input.session.selectedSides[id], hit.side.map(scope.includes) ?? true {
                let menu = FolderContextMenu(session: input.session, ids: input.session.selection, side: nil, compare: input.compare)
                return (table, menu.nativeMenu())
            }
            let wasSelected = table.selectedRowIndexes.contains(hit.row)
            if !wasSelected || !input.session.selectedSides.isEmpty {
                table.selectRowIndexes(IndexSet(integer: hit.row), byExtendingSelection: false)
            }
            let ids = Set(table.selectedRowIndexes.map { rows[$0].id })
            guard !ids.isEmpty else { return nil }
            let preserveAll = wasSelected && input.session.isAllVisibleSelection(count: ids.count)
            input.session.selection = ids
            if !preserveAll {
                input.session.selectionScope = FolderSelectionScope(side: hit.side)
            } else if !input.session.explicitSelectAll {
                input.session.selectionScope = .both
            }
            let menu = FolderContextMenu(session: input.session, ids: ids, side: hit.side, compare: input.compare)
            return (table, menu.nativeMenu())
        }

        private func tableHit(for event: NSEvent) -> (table: NSTableView, row: Int, side: TextSide?)? {
            guard let input, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)),
                  let table = table(at: event.locationInWindow) else { return nil }
            let location = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: location)
            guard input.session.rows.indices.contains(row), table.numberOfRows == input.session.rows.count else { return nil }
            trackScrollView(table, in: input.session)
            switch table.column(at: location) {
            case 0...2: return (table, row, .left)
            case 4...6: return (table, row, .right)
            default: return (table, row, nil)
            }
        }

        func connectScrollView() {
            guard let session = input?.session, let table = table(at: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)),
                  let scrollView = table.enclosingScrollView else { return }
            trackScrollView(table, in: session)
            if let origin = session.pairScrollOrigin {
                session.pairScrollOrigin = nil
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func trackScrollView(_ table: NSTableView, in session: FolderSession) {
            session.readTableScrollOrigin = { [weak scrollView = table.enclosingScrollView] in scrollView?.contentView.bounds.origin }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.connectScrollView() }
        }

        private func table(at location: NSPoint) -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            let point = content.superview?.convert(location, from: nil) ?? location
            return ancestorTable(of: content.hitTest(point))
        }

        private func ancestorTable(of view: NSView?) -> NSTableView? {
            var ancestor = view
            while let current = ancestor {
                if let table = current as? NSTableView { return table }
                ancestor = current.superview
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        NotificationCenter.default.addObserver(view, selector: #selector(Anchor.menuDidSendAction(_:)), name: NSMenu.didSendActionNotification, object: nil)
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown]) { [weak view] event in
            view?.handle(event) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { view.input = self }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(view, name: NSMenu.didSendActionNotification, object: nil)
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
    }
}

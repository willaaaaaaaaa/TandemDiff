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
                if let hit = tableHit(for: event) {
                    input?.session.selectionScope = FolderSelectionScope(side: hit.side)
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
            let wasSelected = table.selectedRowIndexes.contains(hit.row)
            if !wasSelected {
                table.selectRowIndexes(IndexSet(integer: hit.row), byExtendingSelection: false)
            }
            let rows = input.session.rows
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
            guard let input, let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)), let content = window.contentView else { return nil }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let table = ancestorTable(of: content.hitTest(point)) else { return nil }
            let location = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: location)
            guard input.session.rows.indices.contains(row), table.numberOfRows == input.session.rows.count else { return nil }
            switch table.column(at: location) {
            case 0...2: return (table, row, .left)
            case 4...6: return (table, row, .right)
            default: return (table, row, nil)
            }
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

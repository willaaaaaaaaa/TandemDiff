import AppKit
import TandemDiffCore

@MainActor
enum TextSavePanel {
    static func choose(for side: TextSide, source: URL?, format: TextKind) -> (url: URL, format: TextKind)? {
        let panel = NSSavePanel()
        panel.prompt = L("Save", "保存")
        panel.title = side == .left ? L("Save Left Text", "保存左侧文本") : L("Save Right Text", "保存右侧文本")
        let nameLabel = NSTextField(labelWithString: L("Save As:", "保存为："))
        panel.nameFieldLabel = nameLabel.stringValue
        panel.nameFieldStringValue = source?.lastPathComponent ?? L("Untitled.txt", "未命名.txt")
        if let source { panel.directoryURL = source.deletingLastPathComponent() }
        panel.showsTagField = false

        let formats: [TextKind] = [.utf8, .utf8BOM, .utf16LE, .utf16BE]
        let chooser = NSPopUpButton()
        chooser.addItems(withTitles: formats.map(\.formatName))
        chooser.selectItem(at: formats.firstIndex(of: format) ?? 0)
        chooser.setAccessibilityLabel(L("Text encoding", "文本编码"))

        let caption = NSTextField(labelWithString: L("Encoding:", "编码："))
        caption.alignment = .right
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, chooser])
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
        accessory.autoresizingMask = [.width]
        accessory.addSubview(row)
        let fieldCenter = chooser.centerXAnchor.constraint(equalTo: accessory.centerXAnchor)
        NSLayoutConstraint.activate([
            fieldCenter,
            row.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            chooser.widthAnchor.constraint(equalToConstant: 230)
        ])
        let labelWidth = nameLabel.alignmentRect(forFrame: NSRect(origin: .zero, size: nameLabel.fittingSize)).width
        let alignment = FieldAlignment(fieldCenter, compactOffset: (labelWidth + row.spacing) / 2)
        alignment.panel(panel, willExpand: panel.isExpanded)
        panel.delegate = alignment
        panel.accessoryView = accessory
        let response = withExtendedLifetime(alignment) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }
        return (url, formats[chooser.indexOfSelectedItem])
    }

    private final class FieldAlignment: NSObject, NSOpenSavePanelDelegate {
        let center: NSLayoutConstraint
        let compactOffset: CGFloat
        init(_ center: NSLayoutConstraint, compactOffset: CGFloat) {
            self.center = center
            self.compactOffset = compactOffset
        }

        func panel(_ sender: Any, willExpand expanding: Bool) {
            // The compact form reserves a label column. The browser centers the name field itself.
            center.constant = expanding ? 0 : compactOffset
        }
    }
}

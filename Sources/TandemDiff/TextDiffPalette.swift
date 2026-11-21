import AppKit

enum TextDiffPalette {
    static let changedText = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 1.0, green: 0.60, blue: 0.64, alpha: 1)
        }
        return NSColor(srgbRed: 0.70, green: 0.10, blue: 0.17, alpha: 1)
    }
    static let changedRow = NSColor.systemRed.withAlphaComponent(0.11)
}

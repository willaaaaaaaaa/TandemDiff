import SwiftUI

enum TextCommandInk {
    static let secondary = TandemDiffStyle.adaptive(light: 0x4B6670, dark: 0xB2CBCF)
    static let red = TandemDiffStyle.adaptive(light: 0xB32D3D, dark: 0xFF949D)
}

struct TextCommandIcon: View {
    let symbol: String
    let ink: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let color = enabled ? ink : Color(nsColor: .disabledControlTextColor)
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, color.opacity(0.70))
            .accessibilityHidden(true)
    }
}

struct TextSaveIcon: View {
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let ink = enabled ? TextCommandInk.secondary : Color(nsColor: .disabledControlTextColor)
        Canvas { context, _ in
            var disk = Path()
            disk.move(to: CGPoint(x: 1.5, y: 1.5))
            disk.addLine(to: CGPoint(x: 12, y: 1.5))
            disk.addLine(to: CGPoint(x: 15.5, y: 5))
            disk.addLine(to: CGPoint(x: 15.5, y: 15.5))
            disk.addLine(to: CGPoint(x: 1.5, y: 15.5))
            disk.closeSubpath()
            context.fill(disk, with: .color(ink.opacity(0.75)))
            context.stroke(disk, with: .color(ink), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            let label = Path(roundedRect: CGRect(x: 3.5, y: 8.8, width: 10, height: 5.7), cornerRadius: 0.7)
            context.fill(label, with: .color(Color(nsColor: .textBackgroundColor)))
            context.fill(Path(CGRect(x: 4.3, y: 2, width: 6.9, height: 4.4)), with: .color(Color(nsColor: .controlBackgroundColor)))
            context.fill(Path(CGRect(x: 8.8, y: 2.2, width: 1.6, height: 3)), with: .color(ink))
            context.fill(Path(CGRect(x: 5.1, y: 10.8, width: 6.8, height: 1)), with: .color(ink.opacity(0.7)))
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

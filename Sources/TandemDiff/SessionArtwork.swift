import AppKit
import SwiftUI

enum TandemDiffStyle {
    static let accent = adaptive(light: 0x175653, dark: 0x7ABCB1)
    static let marker = adaptive(light: 0xC45100, dark: 0xFFAD65)
    static let canvas = adaptive(light: 0xF3F8F6, dark: 0x172726)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x213533)
    static let border = adaptive(light: 0xCEDDD8, dark: 0x4B645F)

    static func adaptive(light: Int, dark: Int) -> Color {
        func color(_ rgb: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

struct SessionArtwork: View {
    let tool: HomeTool
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: tool == .folderCompare ? "folder" : "doc.on.doc")
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .padding(1)
            } else {
                Canvas { context, size in
                    let scale = min(size.width / 96, size.height / 80)
                    context.translateBy(x: (size.width - 96 * scale) / 2, y: (size.height - 80 * scale) / 2)
                    context.scaleBy(x: scale, y: scale)
                    context.addFilter(.shadow(color: .black.opacity(0.18), radius: 1.8, x: 0, y: 2.2))
                    context.drawLayer { drawing in
                        switch tool {
                        case .folderCompare: drawFolders(in: &drawing)
                        case .textCompare: drawPages(in: &drawing)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private let ink = Color(red: 0.03, green: 0.29, blue: 0.28)
    private let tangerine = Color(red: 1, green: 0.54, blue: 0)
    private let paper = Color(red: 1, green: 0.99, blue: 0.97)
    private let paperShadow = Color(red: 0.84, green: 0.90, blue: 0.87)

    private func plate(_ path: Path, from: Color, to: Color, lifted: Bool = false, in context: inout GraphicsContext) {
        if lifted {
            var shadow = context
            shadow.addFilter(.shadow(color: ink.opacity(0.25), radius: 1.2, x: 0.5, y: 1.1, options: .shadowOnly))
            shadow.fill(path, with: .color(.black))
        }
        let box = path.boundingRect
        context.fill(path, with: .linearGradient(Gradient(colors: [from, to]),
                                                startPoint: CGPoint(x: box.midX, y: box.minY),
                                                endPoint: CGPoint(x: box.midX, y: box.maxY)))
        context.stroke(path, with: .color(ink.opacity(0.36)), lineWidth: 0.85)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius)
    }

    private func rule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color, in context: inout GraphicsContext) {
        context.fill(rect(x, y, width, height, min(0.7, height / 2)), with: .color(color))
    }

    private func stroke(_ points: [CGPoint], _ color: Color, width: CGFloat, in context: inout GraphicsContext) {
        var path = Path()
        path.addLines(points)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func folderSilhouette(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        path.move(to: p(0, 4))
        path.addQuadCurve(to: p(4, 0), control: p(0, 0))
        path.addLine(to: p(19, 0))
        path.addQuadCurve(to: p(22, 1.3), control: p(21, 0))
        path.addLine(to: p(26, 5))
        path.addLine(to: p(width - 4, 5))
        path.addQuadCurve(to: p(width, 9), control: p(width, 5))
        path.addLine(to: p(width - 2, height - 4))
        path.addQuadCurve(to: p(width - 6, height), control: p(width - 2, height))
        path.addLine(to: p(6, height))
        path.addQuadCurve(to: p(2, height - 4), control: p(2, height))
        path.closeSubpath()
        return path
    }

    private func drawFolders(in context: inout GraphicsContext) {
        var rear = context
        rear.translateBy(x: 25, y: 10)
        rear.rotate(by: .degrees(7))
        plate(folderSilhouette(width: 59, height: 42),
              from: Color(red: 0.16, green: 0.46, blue: 0.43),
              to: ink, in: &rear)
        stroke([p(6, 2), p(18, 2)], paper.opacity(0.65), width: 1.1, in: &rear)
        var sheet = context
        sheet.translateBy(x: 24, y: 23)
        sheet.rotate(by: .degrees(-7))
        plate(rect(0, 0, 49, 36, 1.6), from: paper, to: paperShadow, lifted: true, in: &sheet)
        rule(6, 4, 20, 1.6, ink.opacity(0.38), in: &sheet)
        var front = context
        front.translateBy(x: 8, y: 29)
        front.rotate(by: .degrees(-4))
        plate(folderSilhouette(width: 68, height: 41),
              from: Color(red: 0.52, green: 0.75, blue: 0.69),
              to: Color(red: 0.32, green: 0.60, blue: 0.55), lifted: true, in: &front)
        stroke([p(5, 2), p(18, 2)], .white.opacity(0.72), width: 1.2, in: &front)
        stroke([p(27, 6.2), p(62, 6.2)], paper.opacity(0.53), width: 1.1, in: &front)
        stroke([p(7, 39.7), p(60, 39.7)], ink.opacity(0.13), width: 1, in: &front)
        plate(rect(17, 13, 32, 18, 2.4), from: paper, to: paperShadow, in: &front)
        rule(21, 17, 9, 2.4, tangerine, in: &front)
        rule(21, 23, 7, 2.2, ink.opacity(0.68), in: &front)
        rule(33, 16, 1, 12, ink.opacity(0.3), in: &front)
        rule(37, 17, 8, 2.4, ink.opacity(0.86), in: &front)
        rule(37, 23, 5, 2.2, ink.opacity(0.68), in: &front)
    }

    private func drawPages(in context: inout GraphicsContext) {
        var rear = context
        rear.translateBy(x: 32, y: 8)
        rear.rotate(by: .degrees(9))
        plate(rect(0, 0, 43, 54, 1.6), from: paper, to: paperShadow, in: &rear)
        rule(6, 6, 31, 2.1, ink.opacity(0.53), in: &rear)
        rule(6, 12, 29, 1.7, ink.opacity(0.34), in: &rear)
        rule(6, 18, 24, 1.7, ink.opacity(0.34), in: &rear)
        var leaf = context
        leaf.translateBy(x: 19, y: 20)
        leaf.rotate(by: .degrees(-7))
        plate(rect(0, 0, 45, 51, 1.6), from: paper,
              to: paperShadow, lifted: true, in: &leaf)
        stroke([p(1.1, 46), p(1.1, 2), p(42, 1.1)], .white.opacity(0.69), width: 1.2, in: &leaf)
        rule(6, 7, 11, 2.6, ink, in: &leaf)
        rule(6, 12, 32, 0.8, ink.opacity(0.32), in: &leaf)
        rule(11, 20, 25, 3.0, ink, in: &leaf)
        rule(11, 27, 20, 3.0, ink, in: &leaf)
        rule(11, 34, 23, 3.0, ink, in: &leaf)
        stroke([p(8, 25), p(4.8, 25), p(4.8, 32), p(8, 32)], tangerine, width: 2.1, in: &leaf)
        rule(29, 45, 8, 1.2, ink.opacity(0.35), in: &leaf)
    }
}

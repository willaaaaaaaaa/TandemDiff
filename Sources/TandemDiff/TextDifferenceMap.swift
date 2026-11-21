import TandemDiffCore
import SwiftUI

struct TextMapBand {
    var rows: Range<Int>
    let kind: TextRowKind
    let left: Bool
    let right: Bool

    static func collect(from map: TandemDiffCore.TextAlignment, hunks: [Range<Int>]) -> [Self] {
        var bands = [Self]()
        for hunk in hunks {
            for index in hunk {
                let row = map.rows[index], left = row.left != nil, right = row.right != nil
                if let last = bands.last, last.rows.upperBound == index, last.kind == row.kind, last.left == left, last.right == right {
                    bands[bands.count - 1].rows = last.rows.lowerBound..<(index + 1)
                } else {
                    bands.append(Self(rows: index..<(index + 1), kind: row.kind, left: left, right: right))
                }
            }
        }
        return bands
    }
}

@MainActor
final class TextMapViewport: ObservableObject {
    @Published var rows: Range<Int>?
}

struct TextDifferenceMap: View {
    @ObservedObject var model: TextSessionModel
    var body: some View {
        let count = model.alignment?.rows.count ?? 0
        ZStack {
            TextMapMarks(bands: count > 0 ? model.mapBands : [], count: count)
            TextMapPosition(viewport: model.mapViewport, count: count, active: model.currentHunk == nil ? nil : model.activeRow)
            TextMapNavigator(model: model)
        }
        .padding(.vertical, 5)
        .frame(width: 28)
        .background(TandemDiffStyle.canvas)
        .overlay(alignment: .trailing) { Divider() }
    }
}

private struct TextMapNavigator: NSViewRepresentable {
    @ObservedObject var model: TextSessionModel

    func makeNSView(context: Context) -> MapSlider {
        let slider = MapSlider()
        slider.isVertical = true
        slider.model = model
        slider.target = slider
        slider.action = #selector(MapSlider.chooseChange)
        slider.setAccessibilityElement(true)
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityOrientation(.vertical)
        return slider
    }

    func updateNSView(_ slider: MapSlider, context: Context) {
        slider.setAccessibilityLabel(L("Difference map", "差异分布图"))
        slider.toolTip = L("Click to jump to a change. Use the up and down arrows to move between changes.", "点击可跳转到差异，使用上下方向键切换差异块。")
        slider.setAccessibilityHelp(slider.toolTip)
        slider.isEnabled = model.canNavigateDifferences
        slider.maxValue = Double(model.hunks.count)
        slider.minValue = model.currentNumber == nil ? 0 : 1
        slider.doubleValue = Double(model.currentNumber ?? 0)
        slider.setAccessibilityValueDescription(model.currentNumber.map { "\($0) / \(model.hunks.count)" } ?? L("\(model.hunks.count) changes", "\(model.hunks.count) 处差异"))
    }

    final class MapSlider: NSSlider {
        weak var model: TextSessionModel?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { isEnabled }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        override func draw(_ dirtyRect: NSRect) { }
        override func drawFocusRingMask() { NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)).fill() }
        override var focusRingMaskBounds: NSRect { bounds }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let model, let count = model.alignment?.rows.count, bounds.height > 0 else { return }
            window?.makeFirstResponder(self)
            let y = convert(event.locationInWindow, from: nil).y
            model.goToMapRow(min(count - 1, max(0, Int(y / bounds.height * CGFloat(count)))))
        }

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .upArrow: model?.next(-1)
            case .downArrow: model?.next(1)
            default: super.keyDown(with: event)
            }
        }

        override func accessibilityPerformIncrement() -> Bool { step(1) }
        override func accessibilityPerformDecrement() -> Bool { step(-1) }
        override func accessibilityValue() -> Any? { model?.currentNumber ?? 0 }
        override func accessibilityMinValue() -> Any? { model?.currentNumber == nil ? 0 : 1 }
        override func accessibilityMaxValue() -> Any? { model?.hunks.count ?? 0 }
        override func setAccessibilityValue(_ value: Any?) {
            guard let model, model.canNavigateDifferences, let number = value as? NSNumber else { return }
            let ordinal = number.intValue
            if (1...model.hunks.count).contains(ordinal) { model.go(model.hunks[ordinal - 1].lowerBound) }
        }

        private func step(_ direction: Int) -> Bool {
            guard isEnabled, let model else { return false }
            model.next(direction)
            return true
        }

        @objc func chooseChange() {
            setAccessibilityValue(integerValue)
        }
    }
}

private struct TextMapMarks: View {
    let bands: [TextMapBand]
    let count: Int

    var body: some View {
        Canvas { context, size in
            let laneWidth: CGFloat = 7
            for x: CGFloat in [8, 16] {
                context.fill(Path(CGRect(x: x, y: 0, width: laneWidth, height: size.height)), with: .color(.primary.opacity(0.065)))
            }
            guard count > 0, size.height > 0 else { return }
            let scale = size.height / CGFloat(count)
            let inks: [(TextRowKind, Color)] = [(.minor, .secondary), (.ending, .blue), (.change, Color(nsColor: .systemRed))]
            for (kind, ink) in inks {
                var path = Path(), leftEnd: CGFloat = 0, rightEnd: CGFloat = 0
                func mark(at x: CGFloat, from top: CGFloat, to bottom: CGFloat, paintedThrough end: inout CGFloat) {
                    let start = max(top, end)
                    guard bottom > start else { return }
                    path.addRect(CGRect(x: x, y: start, width: laneWidth, height: bottom - start))
                    end = bottom
                }
                for band in bands where band.kind == kind {
                    let height = min(size.height, max(3, CGFloat(band.rows.count) * scale))
                    let middle = CGFloat(band.rows.lowerBound + band.rows.upperBound) * scale / 2
                    let top = floor(min(size.height - height, max(0, middle - height / 2)))
                    let bottom = min(size.height, ceil(top + height))
                    if band.left { mark(at: 8, from: top, to: bottom, paintedThrough: &leftEnd) }
                    if band.right { mark(at: 16, from: top, to: bottom, paintedThrough: &rightEnd) }
                }
                context.fill(path, with: .color(ink))
            }
        }
    }
}

private struct TextMapPosition: View {
    @ObservedObject var viewport: TextMapViewport
    let count: Int
    let active: Int?

    var body: some View {
        Canvas { context, size in
            guard count > 0, size.height > 0 else { return }
            let scale = size.height / CGFloat(count)
            if let rows = viewport.rows?.clamped(to: 0..<count), !rows.isEmpty {
                let height = min(size.height, max(4, CGFloat(rows.count) * scale))
                let y = min(size.height - height, CGFloat(rows.lowerBound) * scale)
                let rect = CGRect(x: 6, y: y, width: 19, height: height).insetBy(dx: 0.5, dy: 0.5)
                context.stroke(Path(rect), with: .color(.primary.opacity(0.55)), lineWidth: 1)
            }
            if let active {
                let y = max(3, min(size.height - 3, (CGFloat(active) + 0.5) * scale))
                var pointer = Path()
                pointer.move(to: CGPoint(x: 0.5, y: y - 3.5))
                pointer.addLine(to: CGPoint(x: 5.5, y: y))
                pointer.addLine(to: CGPoint(x: 0.5, y: y + 3.5))
                pointer.closeSubpath()
                context.fill(pointer, with: .color(TandemDiffStyle.marker))
            }
        }
    }
}

import Foundation

/// One projection owns the UTF-16 offsets that AppKit sees. Disk terminators stay in TextContent.
public final class TextProjection: Sendable {
    public struct Row: Sendable {
        public let offset: Int
        public let length: Int
        public let line: Int?
        public let aligned: Int?
        public let fold: Range<Int>?
        public let kind: TextRowKind
    }

    public let string: String
    public let rows: [Row]
    public let content: TextContent
    private let count: Int

    public init(content: TextContent, side: TextSide, map: TextAlignment? = nil, visible: [TextVisibleRow]? = nil, foldLabel: (Int) -> String = { "⋯  \($0)" }) {
        self.content = content
        let n = visible?.count ?? content.lines.count
        var projected = "", records = [Row](), offset = 0
        records.reserveCapacity(n)
        for i in 0..<n {
            let aligned: Int?, line: Int?, fold: Range<Int>?, value: String, kind: TextRowKind
            switch visible?[i] {
            case .fold(let run):
                aligned = nil; line = nil; fold = run; value = foldLabel(run.count); kind = .equal
            case .line(let index):
                aligned = index; line = map?.rows[index][side]; fold = nil
                value = line.map { content.lines[$0].text } ?? ""
                kind = map?.rows[index].kind ?? .equal
            case nil:
                aligned = nil; line = i; fold = nil; value = content.lines[i].text; kind = .equal
            }
            let length = value.utf16.count
            records.append(Row(offset: offset, length: length, line: line, aligned: aligned, fold: fold, kind: kind))
            projected += value
            offset += length
            if i < n - 1 || (line == content.lines.indices.last && line != nil && !content.lines[line!].ending.isEmpty) {
                projected += "\n"
                offset += 1
            }
        }
        string = projected
        rows = records
        count = offset
    }

    public func row(at offset: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var first = 0, end = rows.count
        while first < end {
            let mid = first + (end - first) / 2
            if rows[mid].offset <= offset { first = mid + 1 } else { end = mid }
        }
        return max(0, first - 1)
    }

    public func selectedRows(_ selection: NSRange) -> ClosedRange<Int>? {
        guard let first = row(at: selection.location), let last = row(at: selection.location + max(0, selection.length - 1)) else { return nil }
        return first...last
    }

    // Display-only spacers and fold captions have no source characters to copy or replace.
    private func sourceRanges(in selection: NSRange, rows span: ClosedRange<Int>) -> [NSRange] {
        var ranges: [NSRange] = []
        let end = NSMaxRange(selection)
        for row in rows[span] {
            guard let index = row.line else { continue }
            let lineEnd = row.offset + row.length
            let start = min(row.length, max(0, selection.location - row.offset))
            var limit = min(row.length, end - row.offset)
            if selection.location <= lineEnd && lineEnd < end { limit += content.lines[index].ending.utf16.count }
            guard limit > start else { continue }
            let range = NSRange(location: content.starts[index] + start, length: limit - start)
            if let previous = ranges.last, NSMaxRange(previous) == range.location {
                ranges[ranges.count - 1].length += range.length
            } else { ranges.append(range) }
        }
        return ranges
    }

    public func clipboardText(in selection: NSRange) -> String {
        guard selection.location <= count, selection.length > 0, selection.length <= count - selection.location,
              let span = selectedRows(selection) else { return "" }
        let text = content.string as NSString
        return sourceRanges(in: selection, rows: span).map { text.substring(with: $0) }.joined()
    }

    public func rawRange(_ selection: NSRange) -> NSRange? {
        if rows.isEmpty { return selection == NSRange(location: 0, length: 0) ? selection : nil }
        guard selection.location <= count, selection.length <= count - selection.location,
              let span = selectedRows(selection), !rows[span].contains(where: { $0.fold != nil }) else { return nil }
        if content.lines.isEmpty { return NSRange() }
        if selection.length > 0 {
            let ranges = sourceRanges(in: selection, rows: span)
            return ranges.count == 1 ? ranges[0] : nil
        }
        let row = rows[span.lowerBound]
        guard let index = row.line else { return nil }
        if selection.location == count, index == content.lines.indices.last { return NSRange(location: content.utf16Count, length: 0) }
        let offset = content.starts[index] + min(row.length, max(0, selection.location - row.offset))
        return NSRange(location: offset, length: 0)
    }

    public func displayOffset(for rawOffset: Int) -> Int? {
        guard let line = content.line(atOffset: rawOffset) else { return 0 }
        guard let record = rows.first(where: { $0.line == line }) else { return nil }
        let column = rawOffset - content.starts[line]
        if column > record.length { return min(count, record.offset + record.length + 1) }
        return record.offset + max(0, column)
    }
}

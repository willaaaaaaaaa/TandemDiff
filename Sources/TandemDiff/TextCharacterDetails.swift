import Foundation
import TandemDiffCore

@MainActor
final class TextCharacterDetails {
    typealias Spans = (left: [NSRange], right: [NSRange])
    let alignment: TandemDiffCore.TextAlignment
    private let left: TextContent, right: TextContent
    private var entries = [Int: Result<Spans, Error>]()
    private var order = [Int]()

    init(alignment: TandemDiffCore.TextAlignment, left: TextContent, right: TextContent) {
        self.alignment = alignment
        self.left = left
        self.right = right
    }

    func spans(at index: Int) -> Spans? {
        if let cached = entries[index] { return try? cached.get() }
        let row = alignment.rows[index]
        if row.kind == .equal || row.kind == .ending { return ([], []) }
        let value = Result<Spans, Error> {
            let a = row.left.map { left.lines[$0].text } ?? ""
            let b = row.right.map { right.lines[$0].text } ?? ""
            if row.left == nil || row.right == nil {
                func whole(_ text: String) -> [NSRange] {
                    text.isEmpty ? [] : [NSRange(location: 0, length: text.utf16.count)]
                }
                return (whole(a), whole(b))
            }
            return try TandemDiffCore.TextAlignment.characterChanges(a, b)
        }
        if order.count == 256 { entries.removeValue(forKey: order.removeFirst()) }
        order.append(index)
        entries[index] = value
        return try? value.get()
    }
}

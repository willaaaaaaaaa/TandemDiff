import Foundation

public enum TextSide: Int, CaseIterable, Identifiable, Sendable {
    case left, right
    public var id: Int { rawValue }
    public var other: Self { self == .left ? .right : .left }
}

public enum TextViewMode: String, Codable, CaseIterable, Sendable { case all, changes, equal, context }

public struct TextComparisonOptions: Equatable, Sendable {
    public var ignoreCase = false
    public var ignoreWhitespace = false
    public init() {}
}

public enum TextRowKind: Sendable { case equal, minor, change, ending }

public struct TextAlignedRow: Sendable {
    public let left: Int?
    public let right: Int?
    public let kind: TextRowKind
    public subscript(side: TextSide) -> Int? { side == .left ? left : right }
}

public enum TextVisibleRow: Equatable, Sendable {
    case line(Int)
    case fold(Range<Int>)
}

public struct TextAlignment: Sendable {
    public static let detailLimit = 131_072
    public let rows: [TextAlignedRow]

    public init(_ left: TextContent, _ right: TextContent, options: TextComparisonOptions = .init(), workLimit: Int = 4_000_000) throws {
        var ids = [Data: Int]()
        func identifiers(_ lines: [TextLine]) throws -> [Int] {
            try lines.enumerated().map { number, line in
                if number.isMultiple(of: 256) { try Task.checkCancellation() }
                let key = Data(line.text.utf8)
                if let value = ids[key] { return value }
                let value = ids.count
                ids[key] = value
                return value
            }
        }
        let a = try identifiers(left.lines), b = try identifiers(right.lines)
        // Use the right sequence as the x-axis. Traversal and traceback both take the x-step when predecessor frontiers tie.
        let matches = try Self.matches(b, a, workLimit: workLimit).map { ($1, $0) }
        var result = [TextAlignedRow](), i = 0, j = 0
        func comparable(_ text: String) -> Data {
            let value = options.ignoreCase ? text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) : text
            return options.ignoreWhitespace ? Data(value.utf8.filter { $0 != 32 && $0 != 9 }) : Data(value.utf8)
        }
        func appendGap(_ x: Int, _ y: Int) throws {
            while i < x || j < y {
                if result.count.isMultiple(of: 512) { try Task.checkCancellation() }
                let l = i < x ? i : nil, r = j < y ? j : nil
                var kind: TextRowKind = .change
                if let l, let r, max(left.lines[l].text.utf8.count, right.lines[r].text.utf8.count) > Self.detailLimit { throw TextFailure.alignmentLimit }
                if (options.ignoreCase || options.ignoreWhitespace), let l, let r,
                   left.lines[l].ending == right.lines[r].ending, comparable(left.lines[l].text) == comparable(right.lines[r].text) { kind = .minor }
                result.append(TextAlignedRow(left: l, right: r, kind: kind))
                if l != nil { i += 1 }
                if r != nil { j += 1 }
            }
        }
        for (x, y) in matches {
            try appendGap(x, y)
            let kind: TextRowKind = left.lines[x].ending == right.lines[y].ending ? .equal : .ending
            result.append(TextAlignedRow(left: x, right: y, kind: kind))
            i += 1
            j += 1
        }
        try appendGap(a.count, b.count)
        rows = result
    }

    // Myers' frontier records only reachable diagonals. Bound the search and traceback together.
    private static func matches(_ a: [Int], _ b: [Int], workLimit: Int) throws -> [(Int, Int)] {
        var prefix = 0
        while prefix < min(a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
        var matched = (0..<prefix).map { ($0, $0) }
        let n = a.count - prefix, m = b.count - prefix
        if n > 0 && m > 0 {
            var trace = [[Int]](), frontier = [0], budget = workLimit
            var complete = false
            for d in 0...(n + m) {
                try Task.checkCancellation()
                budget -= d + 1
                guard budget >= 0 else { throw TextFailure.alignmentLimit }
                var next = Array(repeating: 0, count: d + 1)
                for index in 0...d {
                    let k = 2 * index - d
                    var x: Int
                    if d == 0 { x = 0 }
                    else if index == 0 || (index < d && frontier[index - 1] < frontier[index]) { x = frontier[index] }
                    else { x = frontier[index - 1] + 1 }
                    var y = x - k
                    let nextYStart = y
                    while x < n && y < m && a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                    budget -= y - nextYStart
                    guard budget >= 0 else { throw TextFailure.alignmentLimit }
                    next[index] = x
                    if x >= n && y >= m { complete = true; break }
                }
                trace.append(next)
                frontier = next
                if complete { break }
            }
            var x = n, y = m, reversed = [(Int, Int)]()
            for d in stride(from: trace.count - 1, through: 1, by: -1) {
                let previous = trace[d - 1], k = x - y, index = (k + d) / 2
                let down = index == 0 || (index < d && previous[index - 1] < previous[index])
                let prevX = previous[down ? index : index - 1]
                let prevY = prevX - (down ? k + 1 : k - 1)
                while x > prevX && y > prevY { x -= 1; y -= 1; reversed.append((prefix + x, prefix + y)) }
                x = prevX
                y = prevY
            }
            matched.append(contentsOf: reversed.reversed())
        }
        return matched
    }

    public func hunks(hideMinor: Bool = false) -> [Range<Int>] {
        var result = [Range<Int>](), start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .equal || (hideMinor && row.kind == .minor) {
                if let indexOfStart = start { result.append(indexOfStart..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let start { result.append(start..<rows.count) }
        return result
    }

    public func interval(_ aligned: Range<Int>, side: TextSide) -> Range<Int> {
        let first = aligned.lazy.compactMap { rows[$0][side] }.first
        if let first, let last = aligned.reversed().lazy.compactMap({ rows[$0][side] }).first { return first..<(last + 1) }
        var i = aligned.lowerBound
        while i > 0 {
            i -= 1
            if let value = rows[i][side] { return (value + 1)..<(value + 1) }
        }
        return 0..<0
    }

    public func visible(mode: TextViewMode, context: Int, hideMinor: Bool, revealed: IndexSet) -> [TextVisibleRow] {
        var visible = IndexSet(), result = [TextVisibleRow]()
        if mode == .all { visible.insert(integersIn: 0..<rows.count) }
        let radius = max(0, min(context, rows.count))
        for (index, row) in rows.enumerated() {
            let changed = row.kind != .equal && !(hideMinor && row.kind == .minor)
            if mode == .context && changed { visible.insert(integersIn: max(0, index - radius)..<min(rows.count, index + radius + 1)) }
            if (mode == .equal && !changed) || (mode == .changes && changed) { visible.insert(index) }
        }
        if hideMinor { for index in rows.indices where rows[index].kind == .minor { visible.remove(index) } }
        visible.formUnion(revealed)
        var hiddenStart: Int?
        for index in rows.indices {
            if visible.contains(index) {
                if let start = hiddenStart { result.append(.fold(start..<index)); hiddenStart = nil }
                result.append(.line(index))
            } else if hiddenStart == nil { hiddenStart = index }
        }
        if let start = hiddenStart { result.append(.fold(start..<rows.count)) }
        return result
    }

    public static func characterChanges(_ left: String, _ right: String) throws -> (left: [NSRange], right: [NSRange]) {
        let strings = [left, right]
        guard !left.utf8.elementsEqual(right.utf8) else { return ([], []) }
        guard max(left.utf8.count, right.utf8.count) <= detailLimit else { throw TextFailure.alignmentLimit }
        var ids = [Data: Int]()
        let characters = strings.map { Array($0) }
        let keys = characters.map { row in row.map { character -> Int in
            let bytes = Data(String(character).utf8)
            if let id = ids[bytes] { return id }
            let id = ids.count
            ids[bytes] = id
            return id
        } }
        let a = keys[0], b = keys[1]
        var prefix = 0, endA = a.count, endB = b.count
        while prefix < min(endA, endB), a[prefix] == b[prefix] { prefix += 1 }
        while prefix < min(endA, endB), a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        // Once the common ends are accounted for, disjoint interiors have no possible matches.
        if Set(a[prefix..<endA]).isDisjoint(with: b[prefix..<endB]) {
            let start = characters[0][..<prefix].reduce(0) { $0 + String($1).utf16.count }
            let suffixLength = characters[0][endA...].reduce(0) { $0 + String($1).utf16.count }
            func interior(_ text: String) -> [NSRange] {
                let length = text.utf16.count - start - suffixLength
                return length > 0 ? [NSRange(location: start, length: length)] : []
            }
            return (interior(left), interior(right))
        }
        let pairs = try matches(a, b, workLimit: 200_000)
        func changed(_ side: Int) -> [NSRange] {
            let equal = Set(pairs.map { side == 0 ? $0.0 : $0.1 })
            var result = [NSRange](), offset = 0, start: Int?
            for (idx, ch) in characters[side].enumerated() {
                if equal.contains(idx) { if let begin = start { result.append(NSRange(location: begin, length: offset - begin)); start = nil } }
                else if start == nil { start = offset }
                offset += String(ch).utf16.count
            }
            if let start { result.append(NSRange(location: start, length: offset - start)) }
            return result
        }
        return (changed(0), changed(1))
    }
}

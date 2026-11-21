import Foundation

public enum TextFailure: ComparisonFailure, Equatable {
    case decode, byteLimit, lineLimit, alignmentLimit, invalidRange, prohibitedScalar, historyByteLimit

    var diagnostic: DiagnosticText {
        switch self {
        case .decode: return .init("The bytes do not match the supported text encoding.", "文件字节与支持的文本编码不匹配。")
        case .byteLimit: return .init("This edit or file exceeds the 16 MiB encoded-text limit.", "此次编辑或文件超过了 16 MiB 的编码文本上限。")
        case .historyByteLimit: return .init("The undo or redo history exceeds 16 MiB in this encoding. Choose another encoding.", "使用此编码时撤销或重做历史超过 16 MiB。请选择其他编码。")
        case .lineLimit: return .init("This edit or file exceeds the 200,000 logical-line limit.", "此次编辑或文件超过了 200,000 个逻辑行的上限。")
        case .alignmentLimit: return .init("Alignment limit reached. Editing and saving are available.", "已达到行对齐上限。仍可编辑和保存。")
        case .invalidRange: return .init("Select one continuous range of text.", "请选择一段连续的文本。")
        case .prohibitedScalar: return .init("The text contains a control character that cannot be saved.", "文本包含无法保存的控制字符。")
        }
    }
}

public struct TextLine: Sendable {
    public let text: String
    public let ending: String
    public init(_ text: String, ending: String) {
        self.text = text
        self.ending = ending
    }
}

public extension TextKind {
    var formatName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16LE BOM"
        case .utf16BE: return "UTF-16BE BOM"
        }
    }

    var marker: Data {
        switch self {
        case .utf8: return Data()
        case .utf8BOM: return Data([0xef, 0xbb, 0xbf])
        case .utf16LE: return Data([0xff, 0xfe])
        case .utf16BE: return Data([0xfe, 0xff])
        }
    }

    private var encoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }

    func byteCount(_ text: String) -> Int {
        switch self {
        case .utf8, .utf8BOM: return marker.count + text.utf8.count
        case .utf16LE, .utf16BE: return 2 + 2 * text.utf16.count
        }
    }

    func encode(_ text: String) throws -> Data {
        guard byteCount(text) <= TextBuffer.maxBytes else { throw TextFailure.byteLimit }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw TextFailure.prohibitedScalar }
        guard let bytes = text.data(using: encoding) else { throw TextFailure.decode }
        return marker + bytes
    }

    func decode(_ data: Data) throws -> String {
        guard data.count <= TextBuffer.maxBytes else { throw TextFailure.byteLimit }
        guard data.starts(with: marker) else { throw TextFailure.decode }
        let body = data.dropFirst(marker.count)
        let string: String
        switch self {
        case .utf8, .utf8BOM:
            string = String(decoding: body, as: UTF8.self)
        case .utf16LE, .utf16BE:
            guard body.count.isMultiple(of: 2) else { throw TextFailure.decode }
            let units = body.withUnsafeBytes { raw in
                (0..<(raw.count / 2)).map { index -> UInt16 in
                    let unit = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                    return self == .utf16LE ? UInt16(littleEndian: unit) : UInt16(bigEndian: unit)
                }
            }
            string = String(decoding: units, as: UTF16.self)
        }
        // Reject repaired invalid sequences and retain a second BOM that is actual text.
        guard try encode(string) == data else { throw TextFailure.decode }
        return string
    }
}

public struct TextContent: Sendable {
    public let string: String
    public let lines: [TextLine]
    public let starts: [Int]
    public let utf16Count: Int
    public let preferredEnding: String
    public let endingSummary: String

    public init(_ text: String) throws {
        string = text
        var records = [TextLine]()
        var offsets = [Int]()
        var location = 0, counts = [String: Int](), order = [String]()
        let bytes = text.utf8
        var start = bytes.startIndex, cursor = start
        func append(_ end: String.UTF8View.Index, _ terminator: String) throws {
            guard records.count < TextBuffer.maxLines else { throw TextFailure.lineLimit }
            let body = String(decoding: bytes[start..<end], as: UTF8.self)
            offsets.append(location)
            records.append(TextLine(body, ending: terminator))
            location += body.utf16.count + terminator.utf16.count
            if !terminator.isEmpty {
                if counts[terminator] == nil { order.append(terminator) }
                counts[terminator, default: 0] += 1
            }
        }
        while cursor < bytes.endIndex {
            let end = cursor, c = bytes[cursor]
            bytes.formIndex(after: &cursor)
            guard c == 10 || c == 13 else { continue }
            var ending = c == 10 ? "\n" : "\r"
            if c == 13 && cursor < bytes.endIndex && bytes[cursor] == 10 {
                ending = "\r\n"
                bytes.formIndex(after: &cursor)
            }
            try append(end, ending)
            start = cursor
        }
        if start < bytes.endIndex { try append(bytes.endIndex, "") }
        lines = records
        starts = offsets
        utf16Count = location
        preferredEnding = order.reduce(order.first ?? "\n") { (counts[$1] ?? 0) > (counts[$0] ?? 0) ? $1 : $0 }
        endingSummary = order.map { $0 == "\n" ? "LF" : $0 == "\r" ? "CR" : "CRLF" }.joined(separator: " / ")
    }

    public func offset(atLine index: Int) -> Int { index == starts.count ? utf16Count : starts[index] }

    public func line(atOffset offset: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        var first = 0, end = starts.count
        while first < end {
            let mid = first + (end - first) / 2
            if starts[mid] <= offset { first = mid + 1 } else { end = mid }
        }
        return max(0, first - 1)
    }
}

public final class TextBuffer {
    public static let maxBytes = 16 * 1_024 * 1_024
    public static let maxLines = 200_000
    public private(set) var content: TextContent
    public private(set) var format: TextKind
    public private(set) var revision = 0

    private struct Edit {
        let start: Int
        let old: String
        let new: String
        let before: Int
        let after: Int
    }

    private var history = [Edit](), cursor = 0, nextRevision = 1, savedRevision = 0
    public var isDirty: Bool { revision != savedRevision }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count }

    public init(data: Data = Data(), format: TextKind = .utf8) throws {
        self.format = format
        content = try TextContent(format.decode(data))
    }

    public func markSaved(as kind: TextKind) { format = kind; savedRevision = revision }

    public func encoded(as kind: TextKind? = nil) throws -> Data {
        let chosen = kind ?? format
        let bytes = try chosen.encode(content.string)
        if chosen != format {
            var size = bytes.count
            for edit in history[..<cursor].reversed() {
                size += chosen.byteCount(edit.old) - chosen.byteCount(edit.new)
                guard size <= Self.maxBytes else { throw TextFailure.historyByteLimit }
            }
            size = bytes.count
            for edit in history[cursor...] {
                size += chosen.byteCount(edit.new) - chosen.byteCount(edit.old)
                guard size <= Self.maxBytes else { throw TextFailure.historyByteLimit }
            }
        }
        return bytes
    }

    public func replace(_ range: NSRange, with text: String, keyboardEndings: Bool = false) throws {
        guard range.location >= 0, range.location <= content.utf16Count, range.length >= 0, range.length <= content.utf16Count - range.location else { throw TextFailure.invalidRange }
        var replacement: String
        if keyboardEndings && (text.utf8.contains(10) || text.utf8.contains(13)) {
            replacement = try TextContent(text).lines.map { $0.text + ($0.ending.isEmpty ? "" : content.preferredEnding) }.joined()
        } else {
            replacement = text
        }
        let raw = content.string as NSString
        let old = raw.substring(with: range)
        guard !old.utf8.elementsEqual(replacement.utf8) else { return }
        if keyboardEndings { replacement = preservingJoins(replacement, replacing: range, in: raw) }
        let projectedBytes = format.byteCount(content.string) - format.byteCount(old) + format.byteCount(replacement)
        guard projectedBytes <= Self.maxBytes else { throw TextFailure.byteLimit }
        try install(range, replacement)
        history.removeLast(history.count - cursor)
        history.append(Edit(start: range.location, old: old, new: replacement, before: revision, after: nextRevision))
        cursor += 1
        revision = nextRevision
        nextRevision += 1
    }

    @discardableResult
    public func replaceAll(_ term: String, with replacement: String, caseSensitive: Bool) throws -> Bool {
        guard !term.isEmpty else { return false }
        let raw = content.string as NSString
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        let full = NSRange(location: 0, length: raw.length)
        var hit = raw.range(of: term, options: options, range: full)
        guard hit.location != NSNotFound else { return false }
        let insert = try TextContent(replacement).lines.map { $0.text + ($0.ending.isEmpty ? "" : content.preferredEnding) }.joined()
        var output = "", emitted = format.marker.count, position = 0
        let insertBytes = format.byteCount(insert) - format.marker.count
        var trailingCR = false
        func append(_ piece: String, size: Int, original: NSRange? = nil) throws {
            guard !piece.isEmpty else { return }
            let startsMidCRLF = original.map { $0.location > 0 && raw.character(at: $0.location - 1) == 13 } ?? false
            let endsMidCRLF = original.map { NSMaxRange($0) < raw.length && raw.character(at: NSMaxRange($0)) == 10 } ?? false
            let widen = trailingCR && piece.utf8.first == 10 && !startsMidCRLF
            emitted += size + (widen ? format.byteCount("\n") - format.marker.count : 0)
            guard emitted <= Self.maxBytes else { throw TextFailure.byteLimit }
            if widen { output += "\n" }
            output += piece
            trailingCR = piece.utf8.last == 13 && !endsMidCRLF
        }
        func appendOriginal(through end: Int) throws {
            let range = NSRange(location: position, length: end - position)
            let piece = raw.substring(with: range)
            try append(piece, size: format.byteCount(piece) - format.marker.count, original: range)
        }
        while hit.location != NSNotFound {
            try appendOriginal(through: hit.location)
            try append(insert, size: insertBytes)
            position = NSMaxRange(hit)
            hit = raw.range(of: term, options: options, range: NSRange(location: position, length: raw.length - position))
        }
        try appendOriginal(through: raw.length)
        try replace(full, with: output)
        return true
    }

    private func install(_ range: NSRange, _ replacement: String) throws {
        let candidate = (content.string as NSString).replacingCharacters(in: range, with: replacement)
        guard format.byteCount(candidate) <= Self.maxBytes else { throw TextFailure.byteLimit }
        content = try TextContent(candidate)
    }

    public func splice(_ target: Range<Int>, from source: ArraySlice<TextLine>) throws {
        guard target.lowerBound >= 0, target.upperBound <= content.lines.count else { throw TextFailure.invalidRange }
        let start = content.offset(atLine: target.lowerBound), end = content.offset(atLine: target.upperBound)
        var text = ""
        if !source.isEmpty, target.lowerBound > 0, content.lines[target.lowerBound - 1].ending.isEmpty { text += content.preferredEnding }
        for line in source {
            if text.utf8.last == 13, line.text.isEmpty, line.ending == "\n" { text += "\r" }
            text += line.text + line.ending
        }
        if let last = source.last, last.ending.isEmpty, target.upperBound < content.lines.count { text += content.preferredEnding }
        let range = NSRange(location: start, length: end - start)
        try replace(range, with: preservingJoins(text, replacing: range, in: content.string as NSString))
    }

    // Two independent terminators must remain two rows. Widen a bare CR at a right or deletion join, or a leading LF at a left join.
    private func preservingJoins(_ text: String, replacing range: NSRange, in raw: NSString) -> String {
        let start = range.location, end = NSMaxRange(range)
        let previousCR = start > 0 && raw.character(at: start - 1) == 13 && (start == raw.length || raw.character(at: start) != 10)
        let nextLF = end < raw.length && raw.character(at: end) == 10 && (end == 0 || raw.character(at: end - 1) != 13)
        if text.isEmpty { return previousCR && nextLF ? "\n" : "" }
        var joined = text
        if previousCR && text.utf8.first == 10 { joined = "\r" + joined }
        if nextLF && text.utf8.last == 13 { joined += "\n" }
        return joined
    }

    public func undo() throws {
        guard canUndo else { return }
        let edit = history[cursor - 1]
        try install(NSRange(location: edit.start, length: edit.new.utf16.count), edit.old)
        cursor -= 1
        revision = edit.before
    }

    public func redo() throws {
        guard canRedo else { return }
        let edit = history[cursor]
        try install(NSRange(location: edit.start, length: edit.old.utf16.count), edit.new)
        cursor += 1
        revision = edit.after
    }
}

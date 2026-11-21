import Darwin
import Foundation

public enum TextKind: String, Codable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE
}

public enum TextEligibility {
    private static let opaqueExtensions: Set<String> = [
        "7z", "a", "aac", "aif", "aiff", "app", "ar", "avi", "bmp", "bz2", "class", "dmg", "doc", "docx", "dylib", "elf", "exe", "flac", "gif", "gz", "heic", "heif", "icns", "ico", "iso", "jar", "jpeg", "jpg", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpeg", "numbers", "o", "odt", "otf", "pages", "pdf", "pkg", "png", "ppt", "pptx", "rar", "so", "sqlite", "sqlite3", "tar", "tgz", "tif", "tiff", "ttf", "wav", "webm", "webp", "woff", "woff2", "xls", "xlsx", "xz", "zip", "zst"
    ]
    private static let signatures: [[UInt8]] = [
        [0x89, 0x50, 0x4e, 0x47], [0x50, 0x4b, 3, 4], [0x50, 0x4b, 5, 6], [0x50, 0x4b, 7, 8],
        [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
        [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca], [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        [0x7f, 0x45, 0x4c, 0x46], [0x1f, 0x8b], [0xff, 0xd8, 0xff], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
        [0xff, 0xfe, 0, 0], [0, 0, 0xfe, 0xff], [0xfe, 0xff, 0, 0], [0, 0, 0xff, 0xfe],
        [0xf7, 0x64, 0x4c], [0xdd, 0x73, 0x66, 0x73], [0x0e, 0xfe, 0xff], [0xfb, 0xee, 0x28], [0x84, 0x31, 0x95, 0x33],
        Array("%PDF-".utf8), Array("GIF87a".utf8), Array("GIF89a".utf8), Array("bplist00".utf8), Array("!<arch>\n".utf8),
        Array("+/v8".utf8), Array("+/v9".utf8), Array("+/v+".utf8), Array("+/v/".utf8)
    ]

    static func isOpaqueName(_ name: String) -> Bool {
        opaqueExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private struct Decoder {
        var kind = TextKind.utf8
        var started = false
        var valid = true
        var continuation = 0
        var minimum: UInt8 = 0x80
        var maximum: UInt8 = 0xbf
        var unmatchedByte: UInt8?
        var highSurrogate = false

        var result: TextKind? {
            valid && continuation == 0 && unmatchedByte == nil && !highSurrogate ? kind : nil
        }

        mutating func consume(_ bytes: UnsafeRawBufferPointer) {
            var i = 0
            if !started {
                started = true
                if signatures.contains(where: { bytes.starts(with: $0) }) { valid = false; return }
                if bytes.starts(with: [0xef, 0xbb, 0xbf]) { kind = .utf8BOM; i = 3 }
                else if bytes.starts(with: [0xff, 0xfe]) { kind = .utf16LE; i = 2 }
                else if bytes.starts(with: [0xfe, 0xff]) { kind = .utf16BE; i = 2 }
            }
            if kind == .utf8 || kind == .utf8BOM {
                while i < bytes.count {
                    if continuation == 0 && i + 8 <= bytes.count {
                        let word = bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                        let highBits: UInt64 = 0x8080_8080_8080_8080
                        if (word & highBits) == 0 && ((word &- 0x2020_2020_2020_2020) & highBits) == 0 { i += 8; continue }
                    }
                    let byte = bytes[i]
                    i += 1
                    if continuation > 0 {
                        guard (minimum...maximum).contains(byte) else { valid = false; return }
                        continuation -= 1
                        minimum = 0x80
                        maximum = 0xbf
                    } else {
                        switch byte {
                        case 9, 10, 13, 0x20...0x7f: break
                        case 0xc2...0xdf: continuation = 1
                        case 0xe0...0xef:
                            continuation = 2
                            if byte == 0xe0 { minimum = 0xa0 }
                            if byte == 0xed { maximum = 0x9f }
                        case 0xf0...0xf4:
                            continuation = 3
                            if byte == 0xf0 { minimum = 0x90 }
                            if byte == 0xf4 { maximum = 0x8f }
                        default: valid = false; return
                        }
                    }
                }
            } else {
                while i < bytes.count {
                    if let first = unmatchedByte {
                        unmatchedByte = nil
                        let second = bytes[i]
                        let unit = kind == .utf16LE ? UInt16(second) << 8 | UInt16(first) : UInt16(first) << 8 | UInt16(second)
                        if highSurrogate {
                            guard (0xdc00...0xdfff).contains(unit) else { valid = false; return }
                            highSurrogate = false
                        } else {
                            switch unit {
                            case 9, 10, 13: break
                            case 0...31, 0xdc00...0xdfff: valid = false; return
                            case 0xd800...0xdbff: highSurrogate = true
                            default: break
                            }
                        }
                    } else { unmatchedByte = bytes[i] }
                    i += 1
                }
            }
        }
    }

    public static func check(_ data: Data, name: String) -> TextKind? {
        guard !isOpaqueName(name) else { return nil }
        var decoder = Decoder()
        data.withUnsafeBytes { decoder.consume($0) }
        return decoder.result
    }

    public static func check(_ url: URL) throws -> TextKind? {
        try LocalAccess.withoutMaterializing {
            let fd = try LocalAccess.openPath(url, flags: O_RDONLY)
            let version = try FileVersion.read(descriptor: fd.raw)
            let result = try check(descriptor: fd.raw, name: url.lastPathComponent)
            guard try FileVersion.read(descriptor: fd.raw) == version, try FileVersion.read(url) == version else { throw FolderAccessError.stale }
            return result
        }
    }

    public static func check(descriptor fd: Int32, name: String) throws -> TextKind? {
        try LocalAccess.withoutMaterializing {
            try LocalAccess.validate(descriptor: fd)
            let version = try FileVersion.read(descriptor: fd)
            guard version.mode & S_IFMT == S_IFREG else { throw FolderAccessError.unsupported(.init("Choose a regular file.", "请选择普通文件。")) }
            guard !isOpaqueName(name) else { return nil }
            var decoder = Decoder()
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while decoder.valid {
                try Task.checkCancellation()
                let count = try buffer.withUnsafeMutableBytes { try readChunk(fd, at: offset, into: $0) }
                if count == 0 { break }
                buffer.withUnsafeBytes { decoder.consume(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                offset += off_t(count)
                if count < buffer.count { break }
            }
            guard try FileVersion.read(descriptor: fd) == version else { throw FolderAccessError.stale }
            return decoder.result
        }
    }

    private static func readChunk(_ fd: Int32, at offset: off_t, into bytes: UnsafeMutableRawBufferPointer) throws -> Int {
        var used = 0
        while used < bytes.count {
            let n = pread(fd, bytes.baseAddress!.advanced(by: used), bytes.count - used, offset + off_t(used))
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw FolderAccessError.system(.init("Read file data", "读取文件数据"), errno) }
            if n == 0 { break }
            used += n
        }
        return used
    }

    static func sameBytes(_ left: Int32, _ right: Int32) throws -> Bool {
        var a = [UInt8](repeating: 0, count: 65_536)
        var b = a
        var offset: off_t = 0
        while true {
            try Task.checkCancellation()
            let ac = try a.withUnsafeMutableBytes { try readChunk(left, at: offset, into: $0) }
            let bc = try b.withUnsafeMutableBytes { try readChunk(right, at: offset, into: $0) }
            guard ac == bc else { return false }
            if ac == 0 { return true }
            let equal = a.withUnsafeBytes { x in b.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, ac) == 0 } }
            if !equal { return false }
            offset += off_t(ac)
            if ac < a.count { return true }
        }
    }
}

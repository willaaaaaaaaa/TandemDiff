import Darwin
import Foundation

public enum FolderState: String, CaseIterable, Codable, Sendable {
    case identical, different, leftOnly, rightOnly, notCompared, conflict, error, pending, excluded
}

public struct FolderEntry: Sendable, Identifiable {
    public var path: String
    public var left: URL?
    public var right: URL?
    public var leftVersion: FileVersion?
    public var rightVersion: FileVersion?
    public var leftText: TextKind?
    public var rightText: TextKind?
    public var isDirectory: Bool
    public var state: FolderState
    public fileprivate(set) var diagnostic: DiagnosticText
    public var reason: String {
        get { diagnostic.english }
        set { diagnostic = .init(verbatim: newValue) }
    }
    public var children: [FolderEntry]
    public var equivalentDestinationName: String?
    public var id: Data { Data(path.utf8) }
    public var isUnexamined: Bool {
        if state == .notCompared || state == .error || state == .pending || state == .excluded { return true }
        if !isDirectory && (state == .leftOnly || state == .rightOnly) {
            return leftText == nil && rightText == nil
        }
        return isDirectory && children.isEmpty && coverage.unresolved > 0
    }
    fileprivate var coverage = FolderCoverage()

    public init(path: String, left: URL? = nil, right: URL? = nil, leftVersion: FileVersion? = nil, rightVersion: FileVersion? = nil, leftText: TextKind? = nil, rightText: TextKind? = nil, isDirectory: Bool, state: FolderState, reason: String = "", children: [FolderEntry] = []) {
        self.path = path
        self.left = left
        self.right = right
        self.leftVersion = leftVersion
        self.rightVersion = rightVersion
        self.leftText = leftText
        self.rightText = rightText
        self.isDirectory = isDirectory
        self.state = state
        self.diagnostic = .init(verbatim: reason)
        self.children = children
    }
}

private struct FolderCoverage {
    var equal = 0
    var changed = 0
    var skipped = 0
    var unresolved = 0
    var excluded = 0
}

public enum FolderScanner {
    private struct Directory {
        let url: URL
        let fd: FolderDescriptor
        let version: FileVersion

        init(url: URL, fd: FolderDescriptor) throws {
            self.url = url
            self.fd = fd
            version = try FileVersion.read(descriptor: fd.raw)
        }

        func names() throws -> Set<Data> {
            let duplicate = dup(fd.raw)
            guard duplicate >= 0 else { throw FolderAccessError.system(.init("Open directory listing", "打开目录列表"), errno) }
            guard let stream = fdopendir(duplicate) else {
                let code = errno
                close(duplicate)
                throw FolderAccessError.system(.init("Read directory", "读取目录"), code)
            }
            defer { closedir(stream) }
            var names = Set<Data>()
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 { throw FolderAccessError.system(.init("Read directory", "读取目录"), errno) }
                    break
                }
                let length = Int(item.pointee.d_namlen)
                let bytes = withUnsafeBytes(of: &item.pointee.d_name) { Data($0.prefix(length)) }
                if bytes == Data([46]) || bytes == Data([46, 46]) { continue }
                guard String(data: bytes, encoding: .utf8) != nil else { throw FolderAccessError.unsupported(.init("Directory contains an unrepresentable filename.", "目录包含无法表示的文件名。")) }
                names.insert(bytes)
            }
            try verify()
            return names
        }

        func verify() throws {
            guard try FileVersion.read(descriptor: fd.raw) == version else { throw FolderAccessError.stale }
        }

        // An exact enumerated spelling is absent. Ask this particular filesystem which
        // existing name, if any, a lookup of the proposed spelling would actually use.
        func equivalentSpelling(_ name: String) throws -> String? {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_NAME)
            var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 16)
            if getattrlistat(fd.raw, name, &attributes, &bytes, bytes.count, UInt(FSOPT_NOFOLLOW)) != 0 {
                if errno == ENOENT { return nil }
                throw FolderAccessError.system(.init("Check destination spelling", "检查目标文件名拼写"), errno)
            }
            return try bytes.withUnsafeBytes { raw in
                let start = 4 + Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
                let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
                guard start >= 12, count > 1, start + count <= bytes.count,
                      let spelling = String(bytes: raw[start..<(start + count - 1)], encoding: .utf8) else {
                    throw FolderAccessError.unsupported(.init("Cannot identify the destination spelling.", "无法确定目标文件名的拼写。"))
                }
                guard !spelling.utf8.elementsEqual(name.utf8) else { throw FolderAccessError.stale }
                return spelling
            }
        }
    }

    private struct Item {
        let directory: Directory
        let name: String
        let info: stat
        var type: UInt16 { info.st_mode & S_IFMT }
        var url: URL { LocalAccess.appending(name, to: directory.url, isDirectory: type == S_IFDIR) }
        var version: FileVersion { FileVersion(info) }
        var typeName: DiagnosticText {
            switch type {
            case S_IFDIR: return .init("Folder", "文件夹")
            case S_IFREG: return .init("Regular file", "普通文件")
            case S_IFLNK: return .init("Symbolic link", "符号链接")
            case S_IFIFO: return .init("Named pipe", "命名管道")
            case S_IFSOCK: return .init("Socket", "套接字")
            default: return .init("Special device", "特殊设备")
            }
        }

        func open(_ flags: Int32) throws -> FolderDescriptor {
            guard version.device == directory.version.device else { throw FolderAccessError.unsupported(.init("Mount boundary. Select this volume explicitly.", "遇到挂载点。请直接选择该卷。")) }
            return try LocalAccess.openEntry(parent: directory.fd, parentName: directory.url.lastPathComponent, name: name, info: info, flags: flags)
        }

        func verify() throws {
            guard try FileVersion(entryStat(directory.fd.raw, name)) == version else { throw FolderAccessError.stale }
        }
    }

    private struct Scan {
        let rules: FolderRules
        let showExcluded: Bool
        let selectedIDs: Set<Data>
        let ancestorIDs: Set<Data>

        init(rules: FolderRules, showExcluded: Bool, selectedIDs: Set<Data>) {
            self.rules = rules
            self.showExcluded = showExcluded
            self.selectedIDs = selectedIDs
            var ancestors = Set<Data>()
            for id in selectedIDs {
                var parent = id
                while let separator = parent.lastIndex(of: UInt8(ascii: "/")) {
                    parent = parent.prefix(upTo: separator)
                    if !ancestors.insert(parent).inserted { break }
                }
            }
            ancestorIDs = ancestors
        }

        func descend(left: Directory?, right: Directory?, prefix: String, admitted: Bool, excluded: Bool, previous: [FolderEntry]? = nil, onRow: (@Sendable (FolderEntry) -> Void)? = nil) throws -> [FolderEntry] {
            let a = try left?.names() ?? []
            let b = try right?.names() ?? []
            var rows: [FolderEntry] = []
            func scanChild(_ key: Data, previousEntry: FolderEntry? = nil) throws {
                try Task.checkCancellation()
                let name = String(decoding: key, as: UTF8.self)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let leftDir = a.contains(key) ? left : nil
                let rightDir = b.contains(key) ? right : nil
                guard leftDir != nil || rightDir != nil else { return }
                var row = try entry(path: path, name: name, left: leftDir, right: rightDir, admitted: admitted, inheritedExclusion: excluded, previousEntry: previousEntry)
                if row.state == .leftOnly || row.state == .rightOnly {
                    let opposite = row.state == .leftOnly ? right : left
                    do {
                        if let spelling = try opposite?.equivalentSpelling(name) {
                            row.equivalentDestinationName = spelling
                            row.diagnostic = row.diagnostic.appending(.init("Destination spelling “\(spelling)” conflicts with “\(name)”.", "目标名称“\(spelling)”与“\(name)”存在拼写冲突。"))
                        }
                    } catch {
                        row.state = .error
                        row.diagnostic = error.comparisonDiagnostic
                        row.children = []
                        row.leftText = nil
                        row.rightText = nil
                    }
                }
                summarize(&row)
                rows.append(row)
                try Task.checkCancellation()
                onRow?(row)
            }
            if let previous {
                let start = prefix.isEmpty ? 0 : prefix.utf8.count + 1
                for cached in previous {
                    try Task.checkCancellation()
                    let id = cached.id
                    if selectedIDs.contains(id) {
                        try scanChild(Data(id.dropFirst(start)))
                    } else if ancestorIDs.contains(id) {
                        try scanChild(Data(id.dropFirst(start)), previousEntry: cached)
                    } else {
                        rows.append(cached)
                    }
                }
            } else {
                for key in a.union(b).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    try scanChild(key)
                }
            }
            try left?.verify()
            try right?.verify()
            return rows
        }

        func entry(path: String, name: String, left: Directory?, right: Directory?, admitted: Bool, inheritedExclusion: Bool, previousEntry: FolderEntry?) throws -> FolderEntry {
            var row = FolderEntry(path: path, left: left.map { LocalAccess.appending(name, to: $0.url) }, right: right.map { LocalAccess.appending(name, to: $0.url) }, isDirectory: false, state: .pending, reason: "", children: [])
            let presence: FolderState? = left == nil ? .rightOnly : (right == nil ? .leftOnly : nil)
            var excluded = inheritedExclusion
            do {
                let a = try left.map { Item(directory: $0, name: name, info: try entryStat($0.fd.raw, name)) }
                let b = try right.map { Item(directory: $0, name: name, info: try entryStat($0.fd.raw, name)) }
                row.left = a?.url
                row.right = b?.url
                row.leftVersion = a?.version
                row.rightVersion = b?.version
                row.isDirectory = a?.type == S_IFDIR || b?.type == S_IFDIR
                let admittedHere = admitted || (row.isDirectory && rules.admitsDirectory(path, name: name))
                if row.isDirectory { excluded = excluded || rules.excludesDirectory(path, name: name) }
                else { excluded = excluded || !admitted || !rules.admitsFile(path, name: name) }

                if excluded && !showExcluded {
                    row.state = .excluded
                    row.diagnostic = row.isDirectory ? .init("Excluded subtree; descendant count unknown.", "已排除子目录，子项数量未知。") : .init("Excluded by name rules.", "已按名称规则排除。")
                    return row
                }
                if let a, let b, a.type != b.type {
                    excluded = excluded || !admittedHere
                    row.state = .conflict
                    row.diagnostic = a.typeName.appending(b.typeName, separator: " / ")
                } else if row.isDirectory {
                    let l = try a.map { try Directory(url: $0.url, fd: $0.open(O_RDONLY | O_DIRECTORY)) }
                    let r = try b.map { try Directory(url: $0.url, fd: $0.open(O_RDONLY | O_DIRECTORY)) }
                    // A replaced or newly paired directory invalidates its cached children.
                    let previousChildren: [FolderEntry]? = if let previousEntry,
                       sameDirectory(previousEntry.leftVersion, l?.version),
                       sameDirectory(previousEntry.rightVersion, r?.version) {
                        previousEntry.children
                    } else { nil }
                    row.children = try descend(left: l, right: r, prefix: path, admitted: admittedHere, excluded: excluded, previous: previousChildren)
                    if !admittedHere && row.children.allSatisfy({ $0.state == .excluded }) { excluded = true }
                    row.state = presence ?? .identical
                } else if (a ?? b)?.type == S_IFREG {
                    let l = try a.map { try $0.open(O_RDONLY) }
                    let r = try b.map { try $0.open(O_RDONLY) }
                    row.leftText = try l.flatMap { try TextEligibility.check(descriptor: $0.raw, name: name) }
                    row.rightText = try r.flatMap { try TextEligibility.check(descriptor: $0.raw, name: name) }
                    if let presence { row.state = presence }
                    else if row.leftText == nil || row.rightText == nil { row.state = .notCompared }
                    else if let l, let r, a?.version.size == b?.version.size {
                        row.state = try TextEligibility.sameBytes(l.raw, r.raw) ? .identical : .different
                    } else { row.state = .different }
                    if (a != nil && row.leftText == nil) || (b != nil && row.rightText == nil) {
                        row.diagnostic = TextEligibility.isOpaqueName(name) ? .init("Opaque file type.", "不支持比较此文件类型。") : .init("Binary signature, prohibited control character or unsupported text encoding.", "包含二进制签名、受限控制字符或不支持的文本编码。")
                    }
                } else {
                    row.state = presence ?? .notCompared
                    row.diagnostic = (a ?? b)?.typeName ?? .init("Unsupported filesystem entry", "不支持的文件系统项目")
                }
                try a?.verify()
                try b?.verify()
            } catch is CancellationError { throw CancellationError() }
            catch let error as FolderAccessError {
                row.children = []
                row.leftText = nil
                row.rightText = nil
                switch error {
                case .stale: row.state = .error
                case .unsupported: row.state = presence ?? .notCompared
                case .system(_, ENOENT): row.state = .error
                case .system:
                    row.state = presence ?? .error
                    row.coverage.unresolved = 1
                }
                row.diagnostic = error.comparisonDiagnostic
            }
            if excluded {
                row.state = .excluded
                row.diagnostic = DiagnosticText("Excluded by name rules.", "已按名称规则排除。").appending(row.diagnostic)
                if !showExcluded { row.children = [] }
            }
            return row
        }

        private func sameDirectory(_ previous: FileVersion?, _ current: FileVersion?) -> Bool {
            previous?.device == current?.device && previous?.inode == current?.inode
        }

        private func summarize(_ row: inout FolderEntry) {
            if row.state == .excluded { row.coverage = FolderCoverage(excluded: 1); return }
            let unilateral = row.state == .leftOnly || row.state == .rightOnly
            if row.children.isEmpty {
                switch row.state {
                case .identical: row.coverage.equal = 1
                case .different, .conflict: row.coverage.changed = 1
                case .leftOnly, .rightOnly:
                    row.coverage.changed = 1
                    if row.coverage.unresolved == 0 && row.leftText == nil && row.rightText == nil && !row.reason.isEmpty { row.coverage.skipped = 1 }
                case .error, .pending: row.coverage.unresolved = 1
                case .notCompared: row.coverage.skipped = 1
                default: break
                }
                return
            }
            var total = FolderCoverage()
            for child in row.children {
                total.equal += child.coverage.equal
                total.changed += child.coverage.changed
                total.skipped += child.coverage.skipped
                total.unresolved += child.coverage.unresolved
                total.excluded += child.coverage.excluded
            }
            if unilateral && total.changed == 0 { total.changed = 1 }
            row.coverage = total
            let noneIncluded = total.equal + total.changed + total.unresolved + total.skipped == 0
            if !unilateral {
                if total.changed > 0 { row.state = .different }
                else if total.unresolved > 0 { row.state = .error }
                else if total.skipped > 0 || noneIncluded { row.state = .notCompared }
            }
            if noneIncluded { row.diagnostic = .init("No included items.", "没有符合规则的项目。") }
            else if total.changed + total.skipped + total.unresolved + total.excluded > 0 {
                let summary = DiagnosticText("\(total.changed) changed, \(total.skipped) not compared, \(total.unresolved) unresolved, \(total.excluded) excluded.", "有变化 \(total.changed) 项，未比较 \(total.skipped) 项，未解决 \(total.unresolved) 项，已排除 \(total.excluded) 项。")
                row.diagnostic = row.diagnostic.appending(summary)
            }
        }
    }

    /// A scoped scan replaces selected subtrees in the previous result and recomputes their ancestors.
    public static func scan(left: URL, right: URL, rules: NameRules, showExcluded: Bool = false, rechecking: (ids: Set<Data>, entries: [FolderEntry])? = nil, onRow: @Sendable (FolderEntry) -> Void = { _ in }) throws -> [FolderEntry] {
        try withoutActuallyEscaping(onRow) { publish in
            try LocalAccess.withoutMaterializing {
                let a = try Directory(url: left, fd: LocalAccess.openPath(left, flags: O_RDONLY | O_DIRECTORY))
                let b = try Directory(url: right, fd: LocalAccess.openPath(right, flags: O_RDONLY | O_DIRECTORY))
                let compiled = FolderRules(rules)
                let scan = Scan(rules: compiled, showExcluded: showExcluded, selectedIDs: rechecking?.ids ?? [])
                let rows = try scan.descend(left: a, right: b, prefix: "", admitted: compiled.admitsRoot, excluded: false, previous: rechecking?.entries, onRow: publish)
                guard try FileVersion.read(left) == a.version, try FileVersion.read(right) == b.version else { throw FolderAccessError.stale }
                try Task.checkCancellation()
                return rows
            }
        }
    }
}

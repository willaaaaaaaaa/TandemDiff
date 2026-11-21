import Darwin
import Foundation

struct WriteFailure: ComparisonFailure {
    let diagnostic: DiagnosticText
    init(_ diagnostic: DiagnosticText) { self.diagnostic = diagnostic }
}

func checked(_ result: Int32, _ action: @autoclosure () -> DiagnosticText) throws {
    if result == -1 {
        let code = errno
        throw WriteFailure(action().appending(.init(verbatim: String(cString: strerror(code))), separator: ": "))
    }
}

struct DiskIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

final class WriteHandle {
    let fd: Int32

    init(_ result: Int32, _ action: @autoclosure () -> DiagnosticText) throws {
        try checked(result, action())
        fd = result
    }

    deinit { close(fd) }

    func info() throws -> stat {
        var info = stat()
        try checked(fstat(fd, &info), .init("Inspect file", "检查文件"))
        return info
    }

    func requireSpelling(_ name: String) throws {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        try checked(fcntl(fd, F_GETPATH, &path), .init("Check name spelling", "检查文件名拼写"))
        let raw = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let start = raw.lastIndex(of: 47), raw[(start + 1)...].elementsEqual(name.utf8) else {
            throw WriteFailure(.init("The stored spelling differs from “\(name)”. Refresh and resolve the name conflict.", "磁盘上的文件名与“\(name)”拼写不同。请刷新并解决名称冲突。"))
        }
    }

    func entry(_ name: String) throws -> stat? {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        try checked(-1, .init("Inspect “\(name)”", "检查“\(name)”"))
        return nil
    }

    func regular(_ url: URL, writable: Bool = false) throws -> WriteHandle {
        let name = url.lastPathComponent
        guard let before = try entry(name), before.st_mode & S_IFMT == S_IFREG else {
            throw WriteFailure(.init("“\(name)” is missing or is not a regular file.", "“\(name)”不存在或并非普通文件。"))
        }
        try LocalAccess.checkName(name, directory: false, parentName: url.deletingLastPathComponent().lastPathComponent)
        let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
        let result = try WriteHandle(openat(fd, name, flags), .init("Open “\(name)”", "打开“\(name)”"))
        guard FileVersion(before) == (try FileVersion(result.info())) else { throw staleFile() }
        try result.requireSpelling(name)
        try LocalAccess.validate(descriptor: result.fd)
        return result
    }
}

func staleFile() -> WriteFailure {
    WriteFailure(.init("The file or its parent changed. Refresh or save to a different path.", "文件或父目录已更改。请刷新或另存到其他路径。"))
}

struct WriteDirectory {
    let handle: WriteHandle
    let identities: [DiskIdentity]
    let missing: [String]

    /// All names are opened separately. ELOOP, EACCES and ENOTDIR never signify absence.
    static func walk(_ url: URL, allowMissing: Bool = false) throws -> WriteDirectory {
        let path = try LocalAccess.canonicalURL(url)
        var current = try WriteHandle(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), .init("Open filesystem root", "打开文件系统根目录"))
        try LocalAccess.validate(descriptor: current.fd)
        var identities = [DiskIdentity(try current.info())]
        let names = Array(path.pathComponents.dropFirst())
        for (index, name) in names.enumerated() {
            try LocalAccess.checkName(name, directory: true, parentName: index > 0 ? names[index - 1] : nil)
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = openat(current.fd, name, flags)
            if next == -1 && errno == ENOENT && allowMissing {
                for j in names.indices where j > index {
                    try LocalAccess.checkName(names[j], directory: true, parentName: names[j - 1])
                }
                return WriteDirectory(handle: current, identities: identities, missing: Array(names[index...]))
            }
            let child = try WriteHandle(next, .init("Open directory “\(name)”", "打开目录“\(name)”"))
            try LocalAccess.validate(descriptor: child.fd)
            try child.requireSpelling(name)
            identities.append(DiskIdentity(try child.info()))
            current = child
        }
        return WriteDirectory(handle: current, identities: identities, missing: [])
    }

    func requireAncestor(_ root: WriteDirectory) throws {
        guard let device = root.identities.last?.device, identities.starts(with: root.identities), identities.dropFirst(root.identities.count).allSatisfy({ $0.device == device }) else {
            throw WriteFailure(.init("The file is outside its selected root.", "文件位于所选根目录之外。"))
        }
    }

    func verifyPrefix(_ observed: [DiskIdentity]) throws {
        guard identities.starts(with: observed) else { throw staleFile() }
    }
}

func validateEndpoint(_ url: URL, under root: URL?) throws -> URL {
    let path = try LocalAccess.canonicalURL(url)
    guard !path.lastPathComponent.isEmpty, path.path != "/" else { throw WriteFailure(.init("Choose a file name.", "请选择文件名。")) }
    if let root {
        let base = try LocalAccess.canonicalURL(root)
        let prefix = base.pathComponents
        let names = path.pathComponents
        guard names.count > prefix.count, zip(names, prefix).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) }) else {
            throw WriteFailure(.init("The file is outside its selected root.", "文件位于所选根目录之外。"))
        }
    }
    try LocalAccess.validate(path)
    return path
}

struct WriteFileMetadata: Equatable {
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    let flags: UInt32
    let acl: Data?
    let attributes: [Data: Data]

    init(_ file: WriteHandle) throws {
        let info = try file.info()
        owner = info.st_uid
        group = info.st_gid
        mode = info.st_mode & 0o7777
        flags = info.st_flags
        if let handle = acl_get_fd_np(file.fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(handle)) }
            var length = 0
            guard let value = acl_to_text(handle, &length) else { throw WriteFailure(.init("Cannot read the access control list.", "无法读取访问控制列表。")) }
            defer { acl_free(value) }
            acl = Data(bytes: value, count: length)
        } else {
            guard errno == ENOENT else { throw WriteFailure(.init("Cannot read the access control list.", "无法读取访问控制列表。")) }
            acl = nil
        }
        let count = flistxattr(file.fd, nil, 0, 0)
        guard count >= 0, count <= 1 << 20 else { throw WriteFailure(.init("Cannot inspect extended attributes.", "无法检查扩展属性。")) }
        var names = [CChar](repeating: 0, count: count)
        guard flistxattr(file.fd, &names, count, 0) == count else { throw staleFile() }
        var values = [Data: Data]()
        var budget = 16 << 20
        for raw in names.split(separator: 0) {
            let key = Data(raw.map { UInt8(bitPattern: $0) })
            guard let name = String(data: key, encoding: .utf8) else {
                throw WriteFailure(.init("Cannot preserve an extended attribute name.", "无法保留扩展属性名称。"))
            }
            if name == "com.apple.ResourceFork" { throw WriteFailure(.init("A resource fork protects this file from replacement or copying.", "文件包含资源分支，无法替换或复制。")) }
            let size = fgetxattr(file.fd, name, nil, 0, 0, 0)
            guard size >= 0, size <= budget else { throw WriteFailure(.init("Cannot preserve extended attribute “\(name)”.", "无法保留扩展属性“\(name)”。")) }
            var value = Data(count: size)
            let read = value.withUnsafeMutableBytes { fgetxattr(file.fd, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { throw staleFile() }
            values[key] = value
            budget -= size
        }
        attributes = values
    }

    func protectOverwrite(_ info: stat) throws {
        if info.st_nlink != 1 { throw WriteFailure(.init("A hard-linked destination cannot be replaced.", "无法替换具有硬链接的目标文件。")) }
        if flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 {
            throw WriteFailure(.init("The destination is immutable or append-only.", "目标文件具有不可更改或仅可追加属性。"))
        }
    }

    func protectCopySource() throws {
        guard acl == nil, flags == 0, attributes.keys.allSatisfy({ $0.elementsEqual("com.apple.provenance".utf8) }) else {
            throw WriteFailure(.init("The source has extended metadata that folder copy cannot preserve.", "源文件包含文件夹复制无法保留的扩展元数据。"))
        }
    }

    func apply(to stage: WriteHandle, from original: WriteHandle) throws {
        let current = try WriteFileMetadata(stage)
        if current.owner != owner || current.group != group {
            try checked(fchown(stage.fd, owner, group), .init("Preserve owner and group", "保留所有者和群组"))
        }
        if current.acl != acl {
            try checked(fcopyfile(original.fd, stage.fd, nil, copyfile_flags_t(COPYFILE_ACL)), .init("Preserve access control list", "保留访问控制列表"))
        }
        if current.mode != mode || current.owner != owner || current.group != group {
            try checked(fchmod(stage.fd, mode), .init("Preserve permissions", "保留权限"))
        }
        for key in current.attributes.keys where attributes[key] == nil {
            let name = String(decoding: key, as: UTF8.self)
            try checked(fremovexattr(stage.fd, name, 0), .init("Remove an inherited attribute", "移除继承的属性"))
        }
        for (key, value) in attributes where current.attributes[key] != value {
            let name = String(decoding: key, as: UTF8.self)
            let result = value.withUnsafeBytes { fsetxattr(stage.fd, name, $0.baseAddress, $0.count, 0, 0) }
            try checked(result, .init("Preserve extended attribute “\(name)”", "保留扩展属性“\(name)”"))
        }
        if flags != current.flags { try checked(fchflags(stage.fd, flags), .init("Preserve file flags", "保留文件标志")) }
        guard try WriteFileMetadata(stage) == self else { throw WriteFailure(.init("Staged permissions or metadata differ from the original.", "暂存文件的权限或元数据与原文件不同。")) }
    }
}

private let writeChunkSize = 128 * 1024

func forWriteChunks(_ file: WriteHandle, body: (UnsafeRawBufferPointer, off_t) throws -> Void) throws {
    var offset: off_t = 0
    var chunk = [UInt8](repeating: 0, count: writeChunkSize)
    while true {
        try Task.checkCancellation()
        let count = chunk.withUnsafeMutableBytes { pread(file.fd, $0.baseAddress, $0.count, offset) }
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw WriteFailure(DiagnosticText("Read failed", "读取失败").appending(.init(verbatim: String(cString: strerror(errno))), separator: ": ")) }
        if count == 0 { return }
        try chunk.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[..<count]), offset) }
        offset += off_t(count)
    }
}

func writeBytes(_ bytes: UnsafeRawBufferPointer, to file: WriteHandle) throws {
    var index = 0
    while index < bytes.count {
        try Task.checkCancellation()
        let count = Darwin.write(file.fd, bytes.baseAddress!.advanced(by: index), min(writeChunkSize, bytes.count - index))
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw WriteFailure(DiagnosticText("Stage write failed", "写入暂存文件失败").appending(.init(verbatim: String(cString: strerror(errno))), separator: ": ")) }
        index += count
    }
}

func matches(_ file: WriteHandle, _ data: Data) throws -> Bool {
    guard try file.info().st_size == data.count else { return false }
    var equal = true
    var length = 0
    try data.withUnsafeBytes { expected in
        try forWriteChunks(file) { actual, offset in
            let start = Int(offset)
            guard start <= expected.count, actual.count <= expected.count - start else { throw staleFile() }
            length += actual.count
            if memcmp(actual.baseAddress!, expected.baseAddress!.advanced(by: start), actual.count) != 0 { equal = false }
        }
    }
    return equal && length == data.count
}

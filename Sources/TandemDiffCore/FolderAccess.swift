import Darwin
import Foundation
import UniformTypeIdentifiers

enum FolderAccessError: ComparisonFailure {
    case unsupported(DiagnosticText), stale, system(DiagnosticText, Int32)

    var diagnostic: DiagnosticText {
        switch self {
        case let .unsupported(message): return message
        case .stale: return .init("The item changed during the operation. Refresh to retry.", "操作期间项目已更改。请刷新后重试。")
        case let .system(operation, code):
            return operation.appending(.init(verbatim: String(cString: strerror(code))), separator: ": ")
        }
    }
}

public struct FileVersion: Equatable, Codable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modified: Date
    public var links: UInt64
    public let mode: UInt16
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    public init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = info.st_ino
        size = info.st_size
        links = UInt64(info.st_nlink)
        mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
        modified = Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9)
    }

    public static func read(_ url: URL) throws -> Self {
        try LocalAccess.withoutMaterializing {
            let fd = try LocalAccess.openPath(url, flags: O_EVTONLY)
            return try read(descriptor: fd.raw)
        }
    }

    public static func read(descriptor: Int32) throws -> Self {
        Self(try descriptorStat(descriptor))
    }
}

func descriptorStat(_ fd: Int32) throws -> stat {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw FolderAccessError.system(.init("Inspect item", "检查项目"), errno) }
    return info
}

func entryStat(_ parent: Int32, _ name: String) throws -> stat {
    var info = stat()
    guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw FolderAccessError.system(.init("Inspect \(name)", "检查 \(name)"), errno)
    }
    return info
}

final class FolderDescriptor {
    let raw: Int32
    init(_ fd: Int32, operation: @autoclosure () -> DiagnosticText) throws {
        guard fd >= 0 else {
            let code = errno
            throw FolderAccessError.system(operation(), code)
        }
        raw = fd
    }
    deinit { close(raw) }
}

public enum LocalAccess {
    private static let packageExtensions = Set(["app", "appex", "bundle", "framework", "plugin", "pkg", "rtfd", "xcodeproj", "xcworkspace", "playground", "photoslibrary", "photolibrary", "pages", "numbers", "key", "logicx", "band", "vst", "vst3", "component"])

    static func checkName(_ name: String, directory: Bool, parentName: String?) throws {
        let lower = name.lowercased()
        if (parentName?.lowercased() == "library" && ["cloudstorage", "mobile documents"].contains(lower)) || lower == "file provider storage" || lower.hasSuffix(".icloud") {
            throw FolderAccessError.unsupported(.init("Cloud-managed location. Choose a local copy.", "此位置由云服务管理。请选择本地副本。"))
        }
        if directory {
            let ext = (name as NSString).pathExtension.lowercased()
            if packageExtensions.contains(ext) || (!ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .package) == true) {
                throw FolderAccessError.unsupported(.init("File package", "文件包"))
            }
        }
    }

    /// File-path initializers can decompose Unicode. Keep the bytes returned by directory enumeration.
    public static func exactURL(_ path: String, isDirectory: Bool = false) -> URL {
        var parts = URLComponents()
        parts.scheme = "file"
        parts.host = ""
        parts.path = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        return parts.url ?? URL(string: "about:invalid")!
    }

    public static func appending(_ name: String, to parent: URL, isDirectory: Bool = false) -> URL {
        guard parent.isFileURL, parent.host == nil || parent.host == "" || parent.host?.lowercased() == "localhost" else { return parent }
        let path = parent.path(percentEncoded: false)
        return exactURL(path + (path.hasSuffix("/") ? "" : "/") + name, isDirectory: isDirectory)
    }

    public static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
            throw FolderAccessError.unsupported(.init("Choose a local file URL.", "请选择本地文件 URL。"))
        }
        let path = url.path(percentEncoded: false)
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !path.utf8.contains(0), !parts.contains("."), !parts.contains("..") else {
            throw FolderAccessError.unsupported(.init("Choose a path with no relative components.", "请选择不含相对路径分量的路径。"))
        }
        if let first = parts.first, ["var", "tmp", "etc"].contains(first) {
            return exactURL("/private" + path, isDirectory: url.hasDirectoryPath)
        }
        return url
    }

    public static func withoutMaterializing<T>(_ work: () throws -> T) throws -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let saved = getiopolicy_np(type, scope)
        guard saved >= 0 else { throw FolderAccessError.system(.init("Read download policy", "读取下载策略"), errno) }
        if saved == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { return try work() }
        guard setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw FolderAccessError.system(.init("Prevent cloud download", "阻止云端下载"), errno)
        }
        defer { _ = setiopolicy_np(type, scope, saved) }
        return try work()
    }

    public static func validate(descriptor fd: Int32) throws {
        let info = try descriptorStat(fd)
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw FolderAccessError.unsupported(.init("Unsupported filesystem entry", "不支持的文件系统项目")) }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw FolderAccessError.unsupported(.init("Cloud placeholder. Choose a local copy.", "此项目是云端占位符。请选择本地副本。")) }

        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { throw FolderAccessError.system(.init("Identify volume", "识别卷"), errno) }
        let apfs = withUnsafeBytes(of: &volume.f_fstypename) { $0.starts(with: [97, 112, 102, 115, 0]) }
        guard apfs, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw FolderAccessError.unsupported(.init("Choose a local APFS volume.", "请选择本地 APFS 卷。")) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        var flags = [UInt8](repeating: 0, count: 12)
        guard fgetattrlist(fd, &attributes, &flags, flags.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else {
            throw FolderAccessError.system(.init("Identify storage management", "识别存储管理方式"), errno)
        }
        let extended = flags.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        guard extended & UInt64(EF_IS_SYNC_ROOT) == 0 else { throw FolderAccessError.unsupported(.init("Cloud sync root. Choose a local copy.", "此位置为云同步根目录。请选择本地副本。")) }
        if extended & UInt64(EF_NO_XATTRS) != 0 { return }

        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw FolderAccessError.system(.init("Inspect file attributes", "检查文件属性"), errno) }
        if size == 0 { return }
        var names = [CChar](repeating: 0, count: size)
        let count = flistxattr(fd, &names, size, 0)
        guard count >= 0 else { throw FolderAccessError.system(.init("Read file attributes", "读取文件属性"), errno) }
        for raw in names.prefix(count).split(separator: 0) {
            let attribute = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let key = attribute.lowercased()
            if key.hasPrefix("com.apple.fileprovider") || key.hasPrefix("com.apple.icloud") || key.hasPrefix("com.apple.ubiquity") {
                throw FolderAccessError.unsupported(.init("Cloud-managed item. Choose a local copy.", "此项目由云服务管理。请选择本地副本。"))
            }
            if attribute == "com.apple.FinderInfo" {
                var data = [UInt8](repeating: 0, count: 32)
                guard fgetxattr(fd, attribute, &data, data.count, 0, 0) == data.count else { throw FolderAccessError.system(.init("Inspect Finder metadata", "检查访达元数据"), errno) }
                if data[8] & 0x80 != 0 { throw FolderAccessError.unsupported(.init("Finder alias", "访达替身")) }
                if type == S_IFDIR, data[8] & 0x20 != 0 { throw FolderAccessError.unsupported(.init("File package", "文件包")) }
            }
        }
    }

    static func openEntry(parent: FolderDescriptor, parentName: String?, name: String, info: stat, flags: Int32, matchVersion: Bool = true) throws -> FolderDescriptor {
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw FolderAccessError.unsupported(.init("Unsupported filesystem entry", "不支持的文件系统项目")) }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw FolderAccessError.unsupported(.init("Cloud placeholder. Choose a local copy.", "此项目是云端占位符。请选择本地副本。")) }
        try checkName(name, directory: type == S_IFDIR, parentName: parentName)
        let fd = try FolderDescriptor(openat(parent.raw, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY), operation: .init("Open \(name)", "打开 \(name)"))
        let opened = try descriptorStat(fd.raw)
        guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino, opened.st_mode & S_IFMT == type else { throw FolderAccessError.stale }
        if matchVersion && FileVersion(opened) != FileVersion(info) { throw FolderAccessError.stale }
        try validate(descriptor: fd.raw)
        return fd
    }

    private static func walk(_ url: URL, flags: Int32, allowMissing: Bool) throws -> FolderDescriptor? {
        let canonical = try canonicalURL(url)
        let parts = canonical.path(percentEncoded: false).split(separator: "/").map(String.init)
        var fd = try FolderDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), operation: .init("Open root", "打开根目录"))
        try validate(descriptor: fd.raw)
        for (i, name) in parts.enumerated() {
            let last = i + 1 == parts.count
            let info: stat
            do { info = try entryStat(fd.raw, name) }
            catch FolderAccessError.system(_, ENOENT) where allowMissing {
                for index in i..<parts.count {
                    try checkName(parts[index], directory: index + 1 < parts.count, parentName: index > 0 ? parts[index - 1] : nil)
                }
                return nil
            }
            fd = try openEntry(parent: fd, parentName: i > 0 ? parts[i - 1] : nil, name: name, info: info, flags: last ? flags : O_RDONLY | O_DIRECTORY, matchVersion: last)
        }
        return fd
    }

    static func openPath(_ url: URL, flags: Int32) throws -> FolderDescriptor {
        guard let result = try walk(url, flags: flags, allowMissing: false) else { throw FolderAccessError.stale }
        return result
    }

    public static func validate(_ url: URL) throws {
        try withoutMaterializing { _ = try walk(url, flags: O_EVTONLY, allowMissing: true) }
    }
}

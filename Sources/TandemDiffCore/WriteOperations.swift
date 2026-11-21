import Darwin
import Foundation
import os

private enum BaselineMetadata: Sendable {
    case observed(WriteFileMetadata)
    case unavailable(DiagnosticText)
}

public struct WriteBaseline: Sendable {
    public let data: Data
    public let kind: TextKind
    public let version: FileVersion
    fileprivate let ancestry: [DiskIdentity]
    fileprivate let metadata: BaselineMetadata

    public static func read(_ url: URL, maxBytes: Int? = nil) throws -> Self {
        try LocalAccess.withoutMaterializing {
            let url = try validateEndpoint(url, under: nil)
            let parentURL = url.deletingLastPathComponent()
            let parent = try WriteDirectory.walk(parentURL)
            let name = url.lastPathComponent
            let file = try parent.handle.regular(url)
            let version = try FileVersion(file.info())
            if let maxBytes, version.size > maxBytes { throw WriteFailure(.init("The file exceeds the editor byte limit.", "文件大小超过编辑器上限。")) }
            var bytes = Data()
            try forWriteChunks(file) { chunk, _ in
                guard chunk.count <= Int(version.size) - bytes.count else { throw staleFile() }
                bytes.append(contentsOf: chunk)
            }
            guard let kind = TextEligibility.check(bytes, name: name) else { throw WriteFailure(.init("Unsupported text or file name.", "不支持此文本或文件名。")) }
            let metadata: BaselineMetadata
            do { metadata = .observed(try WriteFileMetadata(file)) }
            catch { metadata = .unavailable(error.comparisonDiagnostic) }
            try WriteDirectory.walk(parentURL).verifyPrefix(parent.identities)
            guard bytes.count == version.size, try parent.handle.entry(name).map(FileVersion.init) == version else { throw staleFile() }
            return WriteBaseline(data: bytes, kind: kind, version: version, ancestry: parent.identities, metadata: metadata)
        }
    }
}

public enum WriteTarget: Sendable {
    case existing(WriteBaseline)
    case absent
}

public struct WriteAbsence: Sendable {
    fileprivate let path: Data
    fileprivate let ancestry: [DiskIdentity]
}

private struct CreatedDirectory: Hashable {
    let parent: DiskIdentity
    let name: Data
    let child: DiskIdentity
}

/// Share one value across the files approved in a single preview.
public struct WriteBatch: Sendable {
    fileprivate let directories = OSAllocatedUnfairLock(initialState: Set<CreatedDirectory>())
    public init() {}
}

/// The existing portion of each ancestry when the user previewed the copy.
public struct WriteObservation: Sendable {
    fileprivate let sourcePath: Data
    fileprivate let destinationPath: Data
    fileprivate let source: [DiskIdentity]
    fileprivate let destination: [DiskIdentity]
}

private enum Payload {
    case buffer(Data)
    case copy(WriteHandle)

    func stage(into file: WriteHandle) throws {
        switch self {
        case let .buffer(data): try data.withUnsafeBytes { try writeBytes($0, to: file) }
        case let .copy(source): try forWriteChunks(source) { bytes, _ in try writeBytes(bytes, to: file) }
        }
    }

    func equals(_ file: WriteHandle) throws -> Bool {
        switch self {
        case let .buffer(data): return try matches(file, data)
        case let .copy(source): return try TextEligibility.sameBytes(source.fd, file.fd)
        }
    }
}

private struct ExistingTarget {
    let file: WriteHandle
    let metadata: WriteFileMetadata

    init(_ directory: WriteDirectory, url: URL, version: FileVersion) throws {
        let name = url.lastPathComponent
        let file = try directory.handle.regular(url, writable: true)
        let info = try file.info()
        guard FileVersion(info) == version, info.st_dev == directory.identities.last?.device else { throw staleFile() }
        var volume = statfs()
        try checked(fstatfs(file.fd, &volume), .init("Inspect destination ownership policy", "检查目标的所有权策略"))
        guard volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            throw WriteFailure(.init("Enable ownership on the destination volume to preserve its owner and group.", "请在目标卷上启用所有权以保留文件的所有者和群组。"))
        }
        let metadata = try WriteFileMetadata(file)
        try metadata.protectOverwrite(info)
        guard try TextEligibility.check(descriptor: file.fd, name: name) != nil else { throw WriteFailure(.init("The destination is not eligible text.", "目标文件不是支持的文本。")) }
        self.file = file
        self.metadata = metadata
    }
}

private func requireTarget(_ dir: WriteDirectory, at url: URL, expected: FileVersion?) throws -> ExistingTarget? {
    if !dir.missing.isEmpty {
        guard expected == nil else { throw staleFile() }
        return nil
    }
    if let expected { return try ExistingTarget(dir, url: url, version: expected) }
    guard try dir.handle.entry(url.lastPathComponent) == nil else { throw WriteFailure(.init("The proposed new file already exists.", "要创建的文件已经存在。")) }
    return nil
}

private struct CopyInputs {
    let source: URL
    let destination: URL
    let sourceDirectory: WriteDirectory
    let destinationDirectory: WriteDirectory
    let file: WriteHandle
    let target: ExistingTarget?

    init(_ sourceURL: URL, _ version: FileVersion, _ sourceRoot: URL, _ destinationURL: URL, _ destinationVersion: FileVersion?, _ destinationRoot: URL, observation: WriteObservation?, batch: WriteBatch?) throws {
        source = try validateEndpoint(sourceURL, under: sourceRoot)
        destination = try validateEndpoint(destinationURL, under: destinationRoot)
        let left = try WriteDirectory.walk(sourceRoot)
        let right = try WriteDirectory.walk(destinationRoot)
        guard !left.identities.contains(right.identities.last!), !right.identities.contains(left.identities.last!) else {
            throw WriteFailure(.init("Overlapping folder roots cannot be used for copying.", "无法在相互重叠的根目录间复制。"))
        }
        sourceDirectory = try WriteDirectory.walk(source.deletingLastPathComponent())
        destinationDirectory = try WriteDirectory.walk(destination.deletingLastPathComponent(), allowMissing: true)
        try sourceDirectory.requireAncestor(left)
        try destinationDirectory.requireAncestor(right)
        if let observation {
            guard observation.sourcePath.elementsEqual(source.path.utf8),
                  observation.destinationPath.elementsEqual(destination.path.utf8),
                  sourceDirectory.identities == observation.source else { throw staleFile() }
            try destinationDirectory.verifyPrefix(observation.destination)
            let names = destination.deletingLastPathComponent().pathComponents
            let identities = destinationDirectory.identities
            for i in observation.destination.count..<identities.count {
                let entry = CreatedDirectory(parent: identities[i - 1], name: Data(names[i].utf8), child: identities[i])
                guard batch?.directories.withLock({ $0.contains(entry) }) == true else { throw staleFile() }
            }
        }
        guard !TextEligibility.isOpaqueName(destination.lastPathComponent) else { throw WriteFailure(.init("Unsupported destination file name.", "不支持此目标文件名。")) }
        file = try sourceDirectory.handle.regular(source)
        let sourceInfo = try file.info()
        guard FileVersion(sourceInfo) == version, sourceInfo.st_dev == left.identities.last?.device else { throw staleFile() }
        guard try TextEligibility.check(descriptor: file.fd, name: source.lastPathComponent) != nil else { throw WriteFailure(.init("The source is not eligible text.", "源文件不是支持的文本。")) }
        try WriteFileMetadata(file).protectCopySource()
        target = try requireTarget(destinationDirectory, at: destination, expected: destinationVersion)
        if let target, try DiskIdentity(target.file.info()) == DiskIdentity(sourceInfo) {
            throw WriteFailure(.init("Source and destination refer to the same file.", "源和目标指向同一文件。"))
        }
        try checked(faccessat(destinationDirectory.handle.fd, ".", W_OK | X_OK, AT_EACCESS), .init("Check destination folder access", "检查目标文件夹访问权限"))
    }

    var observation: WriteObservation {
        WriteObservation(sourcePath: Data(source.path.utf8), destinationPath: Data(destination.path.utf8), source: sourceDirectory.identities, destination: destinationDirectory.identities)
    }

    func verifySource(_ version: FileVersion) throws {
        let actual = try WriteDirectory.walk(source.deletingLastPathComponent())
        try actual.verifyPrefix(sourceDirectory.identities)
        guard try actual.handle.entry(source.lastPathComponent).map(FileVersion.init) == version else { throw staleFile() }
    }
}

public actor FileWriter {
    public init() {}

    /// Use each prefix of this key to find collisions between planned path components.
    public static func destinationKey(_ url: URL, root: URL) throws -> [String] {
        let url = try validateEndpoint(url, under: root)
        let root = try LocalAccess.canonicalURL(root)
        guard let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames else {
            throw WriteFailure(.init("Cannot determine destination name equivalence.", "无法判断目标文件名是否等价。"))
        }
        return url.pathComponents.dropFirst(root.pathComponents.count).map {
            let name = $0.decomposedStringWithCanonicalMapping
            return caseSensitive ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    @discardableResult
    public static func checkCopy(from source: URL, version: FileVersion, sourceRoot: URL, to destination: URL, destinationVersion: FileVersion?, destinationRoot: URL) throws -> WriteObservation {
        try LocalAccess.withoutMaterializing {
            try CopyInputs(source, version, sourceRoot, destination, destinationVersion, destinationRoot, observation: nil, batch: nil).observation
        }
    }

    public static func checkAbsence(at url: URL, root: URL? = nil) throws -> WriteAbsence {
        try LocalAccess.withoutMaterializing {
            let path = try validateEndpoint(url, under: root)
            let parent = try WriteDirectory.walk(path.deletingLastPathComponent(), allowMissing: root != nil)
            if let root { try parent.requireAncestor(WriteDirectory.walk(root)) }
            _ = try requireTarget(parent, at: path, expected: nil)
            return WriteAbsence(path: Data(path.path.utf8), ancestry: parent.identities)
        }
    }

    public func save(_ data: Data, to url: URL, expecting: WriteTarget, root: URL? = nil, absence: WriteAbsence? = nil) throws {
        let destination = try validateEndpoint(url, under: root)
        guard TextEligibility.check(data, name: destination.lastPathComponent) != nil else {
            throw WriteFailure(.init("The output name or bytes cannot be reopened as supported text.", "输出文件名或字节内容无法作为支持的文本重新打开。"))
        }
        let baseline: WriteBaseline?
        let approved: WriteAbsence?
        switch expecting {
        case .absent:
            baseline = nil
            approved = try absence ?? Self.checkAbsence(at: destination, root: root)
        case let .existing(existing):
            baseline = existing
            approved = nil
        }
        try coordinated(source: nil, destination: destination) {
            let parent = try WriteDirectory.walk(destination.deletingLastPathComponent(), allowMissing: approved != nil && root != nil)
            if let root { try parent.requireAncestor(WriteDirectory.walk(root)) }
            if let baseline { try parent.verifyPrefix(baseline.ancestry) }
            if let approved {
                guard approved.path.elementsEqual(destination.path.utf8) else { throw staleFile() }
                guard parent.identities == approved.ancestry else { throw staleFile() }
            }
            let existing = try requireTarget(parent, at: destination, expected: baseline?.version)
            if let baseline, let existing {
                switch baseline.metadata {
                case let .observed(metadata):
                    guard metadata == existing.metadata else { throw staleFile() }
                case let .unavailable(reason): throw WriteFailure(reason)
                }
            }
            try self.withParent(of: destination, observed: parent) { directory in
                try self.install(.buffer(data), at: destination, parent: directory, target: existing, version: baseline?.version) {
                    if let baseline, let existing, try !matches(existing.file, baseline.data) { throw staleFile() }
                }
            }
        }
    }

    public func copy(from source: URL, version: FileVersion, sourceRoot: URL, to destination: URL, destinationVersion: FileVersion?, destinationRoot: URL, observation: WriteObservation? = nil, batch: WriteBatch? = nil) throws {
        let source = try validateEndpoint(source, under: sourceRoot)
        let destination = try validateEndpoint(destination, under: destinationRoot)
        try coordinated(source: source, destination: destination) {
            let inputs = try CopyInputs(source, version, sourceRoot, destination, destinationVersion, destinationRoot, observation: observation, batch: batch)
            try self.withParent(of: destination, observed: inputs.destinationDirectory, batch: batch) { parent in
                try self.install(.copy(inputs.file), at: destination, parent: parent, target: inputs.target, version: destinationVersion) {
                    try inputs.verifySource(version)
                }
            }
        }
    }

    private func withParent(of destination: URL, observed: WriteDirectory, batch: WriteBatch? = nil, perform: (WriteDirectory) throws -> Void) throws {
        var created = [(parent: WriteHandle, name: String, edge: CreatedDirectory)]()
        do {
            var parent = observed
            for name in observed.missing {
                try Task.checkCancellation()
                let directory = parent.handle
                try checked(mkdirat(directory.fd, name, 0o777), .init("Create directory “\(name)”", "创建目录“\(name)”"))
                guard let info = try directory.entry(name), info.st_mode & S_IFMT == S_IFDIR else { throw staleFile() }
                let identity = DiskIdentity(info)
                let edge = CreatedDirectory(parent: parent.identities.last!, name: Data(name.utf8), child: identity)
                created.append((directory, name, edge))
                let child = try WriteHandle(openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC), .init("Open new directory", "打开新目录"))
                try child.requireSpelling(name)
                try LocalAccess.validate(descriptor: child.fd)
                guard try DiskIdentity(child.info()) == identity, identity.device == parent.identities.last?.device else { throw staleFile() }
                parent = WriteDirectory(handle: child, identities: parent.identities + [identity], missing: [])
            }
            try WriteDirectory.walk(destination.deletingLastPathComponent()).verifyPrefix(parent.identities)
            try perform(parent)
            if let batch {
                let edges = created.map(\.edge)
                batch.directories.withLock { $0.formUnion(edges) }
            }
        } catch {
            for entry in created.reversed() {
                if let actual = try? entry.parent.entry(entry.name), DiskIdentity(actual) == entry.edge.child {
                    _ = unlinkat(entry.parent.fd, entry.name, AT_REMOVEDIR)
                }
            }
            throw error
        }
    }

    private func coordinated(source: URL?, destination: URL, operation: () throws -> Void) throws {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        func access(_ actualSource: URL?, _ actualDestination: URL) {
            result = Result {
                guard actualDestination.path.utf8.elementsEqual(destination.path.utf8) else { throw staleFile() }
                if let source {
                    guard let actualSource, actualSource.path.utf8.elementsEqual(source.path.utf8) else { throw staleFile() }
                }
                try Task.checkCancellation()
                try LocalAccess.withoutMaterializing(operation)
            }
        }
        try LocalAccess.withoutMaterializing {
            if let source {
                coordinator.coordinate(readingItemAt: source, options: .withoutChanges, writingItemAt: destination, options: .forReplacing, error: &coordinationError) { access($0, $1) }
            } else {
                coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { access(nil, $0) }
            }
        }
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw WriteFailure(.init("File coordination did not grant access.", "文件协调服务未授予访问权限。"))
    }

    private func install(_ payload: Payload, at url: URL, parent: WriteDirectory, target: ExistingTarget?, version: FileVersion?, verifyInput: () throws -> Void) throws {
        let directory = parent.handle
        let name = url.lastPathComponent
        func verify() throws {
            try verifyInput()
            let current = try WriteDirectory.walk(url.deletingLastPathComponent())
            try current.verifyPrefix(parent.identities)
            guard try directory.entry(name).map(FileVersion.init) == version else { throw staleFile() }
        }
        if let target, try payload.equals(target.file) {
            try verify()
            return
        }
        let stagedName = ".tandemdiff-\(UUID().uuidString)"
        let stage = try WriteHandle(openat(directory.fd, stagedName, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, target == nil ? 0o666 : 0o600), .init("Create staging file", "创建暂存文件"))
        let stageID = DiskIdentity(try stage.info())
        defer {
            if let actual = try? directory.entry(stagedName), DiskIdentity(actual) == stageID {
                _ = unlinkat(directory.fd, stagedName, 0)
            }
        }
        try payload.stage(into: stage)
        if let target { try target.metadata.apply(to: stage, from: target.file) }
        try checked(fsync(stage.fd), .init("Flush staged file", "同步暂存文件"))
        let staged = try stage.info()
        if let target, try WriteFileMetadata(stage) != target.metadata { throw staleFile() }
        guard try payload.equals(stage) else { throw WriteFailure(.init("Staged bytes differ from the approved source.", "暂存的字节内容与已确认的源文件不同。")) }
        try verify()
        try Task.checkCancellation()
        guard try directory.entry(stagedName).map(FileVersion.init) == FileVersion(staged) else { throw staleFile() }
        let flags = version == nil ? UInt32(RENAME_EXCL) : 0
        try checked(renameatx_np(directory.fd, stagedName, directory.fd, name, flags), .init("Install “\(name)”", "写入“\(name)”"))
        do {
            let current = try WriteDirectory.walk(url.deletingLastPathComponent())
            try current.verifyPrefix(parent.identities)
            guard let final = try current.handle.entry(name), DiskIdentity(final) == stageID,
                  final.st_size == staged.st_size, final.st_mode == staged.st_mode,
                  final.st_mtimespec.tv_sec == staged.st_mtimespec.tv_sec,
                  final.st_mtimespec.tv_nsec == staged.st_mtimespec.tv_nsec else { throw staleFile() }
        } catch {
            throw WriteFailure(.init("The file was installed, then its path or contents changed. Inspect the destination before retrying.", "文件写入后，其路径或内容已变化。请检查目标后再重试。"))
        }
    }
}

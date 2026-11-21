import Darwin
import Foundation
import XCTest
@testable import TandemDiffCore

final class WriteOperationsTests: XCTestCase {
    private var tree: URL!
    private var left: URL!
    private var right: URL!
    private let writer = FileWriter()
    private let old = Data("before\n".utf8)
    private let new = Data("after\r\n".utf8)

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["TANDEMDIFF_TEST_VOLUME"] ?? environment["DIFFNOTCH_TEST_VOLUME"] ?? environment["MARGINDIFF_TEST_VOLUME"]
        let fixture = path.map { URL(fileURLWithPath: $0) }
        let base = fixture ?? FileManager.default.temporaryDirectory
        tree = base.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        left = tree.appendingPathComponent("left")
        right = tree.appendingPathComponent("right")
        for folder in [left!, right!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: tree) }

    private func blocked(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Unexpectedly permitted the write", file: file, line: line)
        } catch {}
    }

    private func names(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testA09ExclusiveCreateSupportsEmptyAndRejectsOpaqueOutput() async throws {
        let target = right.appendingPathComponent("new.txt")
        try await writer.save(Data(), to: target, expecting: .absent)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        XCTAssertEqual(try WriteBaseline.read(target).kind, .utf8)
        await blocked { try await self.writer.save(self.new, to: target, expecting: .absent) }
        let opaque = right.appendingPathComponent("new.zip")
        await blocked { try await self.writer.save(self.new, to: opaque, expecting: .absent) }
        await blocked { try await self.writer.save(Data([65, 0]), to: self.right.appendingPathComponent("bad.txt"), expecting: .absent) }
        XCTAssertEqual(try names(right), ["new.txt"])
        XCTAssertEqual(try Data(contentsOf: target), Data())
    }

    func testA06NoOpSavePreservesOriginalFileAndFormat() async throws {
        let target = right.appendingPathComponent("original")
        let data = Data([0xff, 0xfe, 65, 0, 13, 0, 10, 0, 66, 0])
        try data.write(to: target)
        let baseline = try WriteBaseline.read(target)
        try await writer.save(data, to: target, expecting: .existing(baseline))
        XCTAssertEqual(try FileVersion.read(target), baseline.version)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try WriteBaseline.read(target).kind, .utf16LE)
        XCTAssertThrowsError(try WriteBaseline.read(target, maxBytes: data.count - 1))
    }

    func testA11StaleSaveAsAndHardLinkedDestination() async throws {
        let target = right.appendingPathComponent("existing")
        try old.write(to: target)
        let initial = try WriteBaseline.read(target)
        try new.write(to: target)
        await blocked { try await self.writer.save(self.old, to: target, expecting: .existing(initial)) }
        let linked = right.appendingPathComponent("second")
        try FileManager.default.linkItem(at: target, to: linked)
        let hardLinked = try WriteBaseline.read(target)
        await blocked { try await self.writer.save(self.old, to: target, expecting: .existing(hardLinked)) }
        XCTAssertEqual(try names(right), ["existing", "second"])
        XCTAssertEqual(try Data(contentsOf: linked), new)
        XCTAssertEqual(try Data(contentsOf: target), new)
    }

    func testA11PreservesModeGroupACLAndExtendedAttribute() async throws {
        let target = right.appendingPathComponent("protected")
        try old.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let marker = Data([0, 4, 255, 2])
        let name = "com.tandemdiff.fixture"
        XCTAssertEqual(marker.withUnsafeBytes { setxattr(target.path, name, $0.baseAddress, $0.count, 0, 0) }, 0)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,readattr", target.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        var before = stat()
        XCTAssertEqual(lstat(target.path, &before), 0)
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: Int(max(0, count)))
        if count > 0, getgroups(count, &groups) == count, let group = groups.first(where: { $0 != before.st_gid }) {
            XCTAssertEqual(chown(target.path, uid_t.max, group), 0)
            XCTAssertEqual(lstat(target.path, &before), 0)
            XCTAssertEqual(before.st_gid, group)
        }
        func metadata() throws -> WriteFileMetadata {
            let fd = try WriteHandle(open(target.path, O_RDONLY | O_NOFOLLOW), .init(verbatim: "Read fixture"))
            return try WriteFileMetadata(fd)
        }
        let original = try metadata()
        XCTAssertNotNil(original.acl)
        XCTAssertEqual(original.attributes[Data(name.utf8)], marker)
        let baseline = try WriteBaseline.read(target)
        try await writer.save(new, to: target, expecting: .existing(baseline))
        XCTAssertEqual(try Data(contentsOf: target), new)
        XCTAssertEqual(try metadata(), original)
        var after = stat()
        XCTAssertEqual(lstat(target.path, &after), 0)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_mode, before.st_mode)
        XCTAssertEqual(try names(right), ["protected"])
    }

    func testA11CanonicalEquivalentAttributeNamesRetainDistinctValues() async throws {
        let target = right.appendingPathComponent("attributes")
        try old.write(to: target)
        let names = ["com.tandemdiff.caf\u{00e9}", "com.tandemdiff.cafe\u{0301}"]
        for (index, name) in names.enumerated() {
            var value = UInt8(index + 1)
            XCTAssertEqual(setxattr(target.path, name, &value, 1, 0, XATTR_CREATE), 0)
        }
        try await writer.save(new, to: target, expecting: .existing(try WriteBaseline.read(target)))
        XCTAssertEqual(try Data(contentsOf: target), new)
        for (index, name) in names.enumerated() {
            var value: UInt8 = 0
            XCTAssertEqual(getxattr(target.path, name, &value, 1, 0, 0), 1)
            XCTAssertEqual(value, UInt8(index + 1))
        }
    }

    func testA11ResourceForkBlocksSaveAndCopyWithoutChangingEitherFork() async throws {
        let target = right.appendingPathComponent("protected")
        let source = left.appendingPathComponent("protected")
        try old.write(to: target)
        try new.write(to: source)
        let marker = Data("resource".utf8)
        XCTAssertEqual(marker.withUnsafeBytes { setxattr(target.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }, 0)
        let baseline = try WriteBaseline.read(target)
        await blocked { try await self.writer.save(self.new, to: target, expecting: .existing(baseline)) }
        let version = try FileVersion.read(source)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: baseline.version, destinationRoot: self.right) }
        let absent = left.appendingPathComponent("resource-copy")
        await blocked { try await self.writer.copy(from: target, version: baseline.version, sourceRoot: self.right, to: absent, destinationVersion: nil, destinationRoot: self.left) }
        XCTAssertEqual(try names(right), ["protected"])
        XCTAssertEqual(try names(left), ["protected"])
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("..namedfork/rsrc")), marker)
    }

    func testA10CopyCreatesOnlyApprovedParentsAndVerifiesEachVersion() async throws {
        let source = left.appendingPathComponent("source")
        let destination = right.appendingPathComponent("one/two/file")
        let bytes = Data(repeating: 0x41, count: 350_011)
        try bytes.write(to: source)
        let version = try FileVersion.read(source)
        let observation = try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: destination, destinationVersion: nil, destinationRoot: right)
        XCTAssertEqual(try names(right), [])
        try await writer.copy(from: source, version: version, sourceRoot: left, to: destination, destinationVersion: nil, destinationRoot: right, observation: observation)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try names(destination.deletingLastPathComponent()), ["file"])
        let destinationVersion = try FileVersion.read(destination)
        try new.write(to: source)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: destination, destinationVersion: destinationVersion, destinationRoot: self.right) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let updatedSource = try FileVersion.read(source)
        try await writer.copy(from: source, version: updatedSource, sourceRoot: left, to: destination, destinationVersion: destinationVersion, destinationRoot: right)
        XCTAssertEqual(try Data(contentsOf: destination), new)
        XCTAssertEqual(try Data(contentsOf: source), new)
    }

    func testA10ConcurrentCreateChangedTargetAndUnwritableTargetAreBlocked() async throws {
        let source = left.appendingPathComponent("value")
        let target = right.appendingPathComponent("value")
        try new.write(to: source)
        let version = try FileVersion.read(source)
        let preview = try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: target, destinationVersion: nil, destinationRoot: right)
        try old.write(to: target)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: nil, destinationRoot: self.right, observation: preview) }
        let observed = try FileVersion.read(target)
        try Data("changed".utf8).write(to: target)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: observed, destinationRoot: self.right) }
        XCTAssertEqual(chmod(target.path, 0o444), 0)
        let protected = try FileVersion.read(target)
        if geteuid() != 0 {
            await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: protected, destinationRoot: self.right) }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("changed".utf8))
        XCTAssertEqual(try names(right), ["value"])
    }

    func testA05ProtectsAliasesOverlapsAndReplacedParent() async throws {
        let source = left.appendingPathComponent("source")
        try old.write(to: source)
        let version = try FileVersion.read(source)
        let sub = right.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let target = sub.appendingPathComponent("target")
        let preview = try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: target, destinationVersion: nil, destinationRoot: right)
        let previous = right.appendingPathComponent("original")
        try FileManager.default.moveItem(at: sub, to: previous)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: nil, destinationRoot: self.right, observation: preview) }
        XCTAssertEqual(try names(sub), [])
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: left)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: nil, destinationRoot: self.right) }
        await blocked { try await self.writer.save(self.new, to: target, expecting: .absent) }
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.tree, to: self.right.appendingPathComponent("target"), destinationVersion: nil, destinationRoot: self.right) }
        await blocked { try await self.writer.save(self.new, to: previous, expecting: .absent) }
        XCTAssertEqual(try names(left), ["source"])
        XCTAssertEqual(try names(previous), [])
        XCTAssertEqual(try names(right), ["original", "sub"])
    }

    func testA10SharedAncestorCreatedByEarlierApprovedFile() async throws {
        let batch = WriteBatch()
        let folder = right.appendingPathComponent("missing/inner")
        let first = left.appendingPathComponent("one")
        let second = left.appendingPathComponent("two")
        try old.write(to: first)
        try new.write(to: second)
        let items = try [first, second].map { source in
            let version = try FileVersion.read(source)
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let observation = try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: destination, destinationVersion: nil, destinationRoot: right)
            return (source, version, destination, observation)
        }
        for (source, version, destination, observation) in items {
            try await writer.copy(from: source, version: version, sourceRoot: left, to: destination, destinationVersion: nil, destinationRoot: right, observation: observation, batch: batch)
        }
        XCTAssertEqual(try names(folder), ["one", "two"])
        XCTAssertEqual(try Data(contentsOf: items[0].2), old)
        XCTAssertEqual(try Data(contentsOf: items[1].2), new)
    }

    func testA10ExternallyCreatedDirectoryCannotJoinApprovedBatch() async throws {
        let source = left.appendingPathComponent("one")
        let folder = right.appendingPathComponent("missing")
        let target = folder.appendingPathComponent("create")
        try old.write(to: source)
        let version = try FileVersion.read(source)
        let observation = try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: target, destinationVersion: nil, destinationRoot: right)
        let absence = try FileWriter.checkAbsence(at: target, root: right)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: nil, destinationRoot: self.right, observation: observation, batch: WriteBatch()) }
        await blocked { try await self.writer.save(self.new, to: target, expecting: .absent, root: self.right, absence: absence) }
        XCTAssertEqual(try names(folder), [])
    }

    func testA09ExplicitVirtualSaveCreatesOnlyItsAncestors() async throws {
        let target = right.appendingPathComponent("missing/nested/empty")
        let absence = try FileWriter.checkAbsence(at: target, root: right)
        XCTAssertEqual(try names(right), [])
        try await writer.save(Data(), to: target, expecting: .absent, root: right, absence: absence)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        XCTAssertEqual(try names(target.deletingLastPathComponent()), ["empty"])
    }

    func testA10CancellationBetweenFilesKeepsCompletedDestination() async throws {
        let source = left.appendingPathComponent("source")
        let completed = right.appendingPathComponent("first")
        let pending = right.appendingPathComponent("nested/second")
        try new.write(to: source)
        let version = try FileVersion.read(source)
        let task = Task {
            try await writer.copy(from: source, version: version, sourceRoot: left, to: completed, destinationVersion: nil, destinationRoot: right)
            withUnsafeCurrentTask { $0?.cancel() }
            try await writer.copy(from: source, version: version, sourceRoot: left, to: pending, destinationVersion: nil, destinationRoot: right)
        }
        do {
            try await task.value
            XCTFail("Cancelled batch performed its second copy")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: completed), new)
        XCTAssertEqual(try names(right), ["first"])
    }

    func testA11ImmutableTargetAndProtectedCopySource() async throws {
        let target = right.appendingPathComponent("existing")
        let source = left.appendingPathComponent("source")
        try old.write(to: target)
        try new.write(to: source)
        XCTAssertEqual(chflags(target.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(target.path, 0) }
        let baseline = try WriteBaseline.read(target)
        await blocked { try await self.writer.save(self.new, to: target, expecting: .existing(baseline)) }
        XCTAssertEqual(try Data(contentsOf: target), old)
        let custom = Data([1])
        XCTAssertEqual(custom.withUnsafeBytes { setxattr(source.path, "com.tandemdiff.protected", $0.baseAddress, $0.count, 0, 0) }, 0)
        let version = try FileVersion.read(source)
        let absent = right.appendingPathComponent("new/child")
        XCTAssertThrowsError(try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: absent, destinationVersion: nil, destinationRoot: right))
        XCTAssertEqual(try names(right), ["existing"])
    }

    func testA11LeafSymlinkIsNotAnAbsentDestination() async throws {
        let original = right.appendingPathComponent("original")
        let target = right.appendingPathComponent("target")
        try old.write(to: original)
        let absence = try FileWriter.checkAbsence(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        await blocked { try await self.writer.save(self.new, to: target, expecting: .absent, absence: absence) }
        XCTAssertEqual(try Data(contentsOf: original), old)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), original.path)
    }

    func testA05CanonicalEquivalenceDoesNotRedirectOverwrite() async throws {
        var components = try XCTUnwrap(URLComponents(url: right, resolvingAgainstBaseURL: false))
        let base = components.percentEncodedPath
        components.percentEncodedPath = base + "/caf%C3%A9"
        let composed = try XCTUnwrap(components.url)
        components.percentEncodedPath = base + "/cafe%CC%81"
        let decomposed = try XCTUnwrap(components.url)
        // Darwin's String-to-filesystem conversion may decompose names. Install the chosen bytes with openat.
        let directory = try WriteHandle(open(right.path, O_DIRECTORY | O_RDONLY), .init(verbatim: "Open fixture directory"))
        let descriptor = try WriteHandle(openat(directory.fd, "caf\u{00e9}", O_CREAT | O_EXCL | O_RDWR, 0o600), .init(verbatim: "Create fixture"))
        try new.withUnsafeBytes { try writeBytes($0, to: descriptor) }
        let storedName = Data("caf\u{00e9}".utf8)
        let row = try XCTUnwrap(try FolderScanner.scan(left: left, right: right, rules: NameRules()).first)
        let scanned = try XCTUnwrap(row.right)
        XCTAssertEqual(Data(row.path.utf8), storedName)
        XCTAssertEqual(Data(scanned.lastPathComponent.utf8), storedName)
        XCTAssertEqual(try WriteBaseline.read(scanned).data, new)
        let nested = LocalAccess.appending("folder/caf\u{00e9}", to: right)
        XCTAssertEqual(Data(nested.lastPathComponent.utf8), storedName)
        XCTAssertEqual(try FileWriter.destinationKey(composed, root: right), try FileWriter.destinationKey(decomposed, root: right))
        if try directory.entry("cafe\u{0301}") != nil {
            let baseline = try WriteBaseline.read(composed)
            await blocked { try await self.writer.save(self.old, to: decomposed, expecting: .existing(baseline)) }
            await blocked { try await self.writer.save(self.old, to: decomposed, expecting: .absent) }
            XCTAssertEqual(try Data(contentsOf: composed), new)
            try await writer.save(old, to: composed, expecting: .existing(baseline))
            XCTAssertEqual(try Data(contentsOf: composed), old)
        }
    }

    func testA14MissingCloudAncestryCannotBeCreated() async throws {
        let source = left.appendingPathComponent("source")
        let target = right.appendingPathComponent("Library/CloudStorage/Account/missing")
        try new.write(to: source)
        let version = try FileVersion.read(source)
        XCTAssertThrowsError(try FileWriter.checkCopy(from: source, version: version, sourceRoot: left, to: target, destinationVersion: nil, destinationRoot: right))
        await blocked { try await self.writer.copy(from: source, version: version, sourceRoot: self.left, to: target, destinationVersion: nil, destinationRoot: self.right) }
        XCTAssertEqual(try names(right), [])
    }

    func testA05DestinationSpellingRespectsMountedCaseMode() async throws {
        let spelled = right.appendingPathComponent("Report")
        let variant = right.appendingPathComponent("report")
        try old.write(to: spelled)
        let caseSensitive = try XCTUnwrap(right.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        let keysEqual = try FileWriter.destinationKey(spelled, root: right) == FileWriter.destinationKey(variant, root: right)
        XCTAssertEqual(keysEqual, !caseSensitive)
        if caseSensitive {
            try await writer.save(new, to: variant, expecting: .absent)
            XCTAssertEqual(try Data(contentsOf: variant), new)
        } else {
            await blocked { try await self.writer.save(self.new, to: variant, expecting: .existing(try WriteBaseline.read(spelled))) }
            XCTAssertEqual(try names(right), ["Report"])
        }
        XCTAssertEqual(try Data(contentsOf: spelled), old)
    }
}

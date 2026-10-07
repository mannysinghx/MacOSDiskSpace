import XCTest
@testable import MacSpaceFinder

/// Temp files go to <package>/.build/test-tmp — not the system temp folder, because the app
/// (deliberately) refuses to move anything under /private, where $TMPDIR lives.
/// Set $MSF_EXFAT_DEST to a folder on an exFAT disk (e.g. a mounted test disk image) to run the exFAT tests.
class TempDirTestCase: XCTestCase {
    var base: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = package.appendingPathComponent(".build/test-tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        base = PathUtil.canonicalDirectory(tmp).appendingPathComponent("msf-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    func write(_ url: URL, bytes: Int) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    }

    func allocated(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }

    func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// root/small.txt, root/big/a.bin, root/big/inner/b.bin (+ optional symlink and xattr)
    @discardableResult
    func makeTree(_ root: URL, symlink: Bool = true) throws -> URL {
        try write(root.appendingPathComponent("small.txt"), bytes: 1_000)
        try write(root.appendingPathComponent("big/a.bin"), bytes: 300_000)
        try write(root.appendingPathComponent("big/inner/b.bin"), bytes: 2_000_000)
        let tagged = root.appendingPathComponent("small.txt").path
        XCTAssertEqual(setxattr(tagged, "com.example.msf", "hello", 5, 0, 0), 0)
        if symlink {
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "small.txt")
        }
        return root
    }

    func run(_ items: [URL], _ mode: TransferMode, to dest: URL, permanent: Bool = true) -> (results: [TransferItemResult], fatal: String?) {
        TransferEngine { _ in }.run(items: items, options: TransferOptions(mode: mode, destination: dest, deletePermanently: permanent))
    }
}

final class ScannerTests: TempDirTestCase {
    func testFolderSizesAndBiggest() throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let result = FolderScanner.scan(root: root) { _ in }

        let a = allocated(root.appendingPathComponent("big/a.bin"))
        let b = allocated(root.appendingPathComponent("big/inner/b.bin"))
        let small = allocated(root.appendingPathComponent("small.txt"))
        let link = allocated(root.appendingPathComponent("link"))

        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.files, 4)
        XCTAssertEqual(result.newSizes[root.path + "/big/inner"], b)
        XCTAssertEqual(result.newSizes[root.path + "/big"], a + b)
        XCTAssertEqual(result.newSizes[root.path], a + b + small + link)

        // inner holds > 80% of big, so big is skipped in favour of inner; the root is never listed.
        let listed = result.biggest.map(\.path)
        XCTAssertTrue(listed.contains(root.path + "/big/inner"))
        XCTAssertFalse(listed.contains(root.path + "/big"))
        XCTAssertFalse(listed.contains(root.path))
    }

    func testPackagesAreListedWholeNotTheirInsides() throws {
        let root = base.appendingPathComponent("root")
        try write(root.appendingPathComponent("Huge.app/Contents/Resources/data.bin"), bytes: 1_000_000)
        try write(root.appendingPathComponent("other/x.bin"), bytes: 10_000)
        let result = FolderScanner.scan(root: root) { _ in }
        let listed = result.biggest.map(\.path)
        XCTAssertTrue(listed.contains(root.path + "/Huge.app"), "\(listed)")
        XCTAssertFalse(listed.contains { $0.contains("Huge.app/") }, "\(listed)")
    }
}

final class TransferTests: TempDirTestCase {
    func testCopyKeepsOriginalAndMetadata() throws {
        let src = try makeTree(base.appendingPathComponent("Project"))
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let out = run([src], .copy, to: dest)
        XCTAssertNil(out.fatal)
        let r = try XCTUnwrap(out.results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertEqual(r.destination?.path, dest.path + "/Project")
        XCTAssertNil(TransferEngine.verify(source: src, copy: dest.appendingPathComponent("Project")))
        XCTAssertTrue(fm.fileExists(atPath: src.path + "/big/inner/b.bin"), "original must remain")
        XCTAssertTrue(isSymlink(dest.appendingPathComponent("Project/link")), "symlink copied as a link")
        var buf = [CChar](repeating: 0, count: 16)
        XCTAssertEqual(getxattr(dest.path + "/Project/small.txt", "com.example.msf", &buf, 16, 0, 0), 5, "xattr preserved")
    }

    func testMoveRemovesOriginalOnlyAfterCopy() throws {
        let src = try makeTree(base.appendingPathComponent("Movies"))
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let out = run([src], .move, to: dest)
        XCTAssertNil(out.fatal)
        let r = try XCTUnwrap(out.results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertTrue(r.originalRemoved)
        XCTAssertFalse(fm.fileExists(atPath: src.path))
        let data = try Data(contentsOf: dest.appendingPathComponent("Movies/big/inner/b.bin"))
        XCTAssertEqual(data.count, 2_000_000)
        XCTAssertEqual(data[1000], UInt8(1000 % 251))
    }

    func testMigrateLeavesWorkingLink() throws {
        let src = try makeTree(base.appendingPathComponent("Cache"))
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let r = try XCTUnwrap(run([src], .migrate, to: dest).results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertTrue(r.linked)
        XCTAssertTrue(isSymlink(src))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: src.path), dest.path + "/Cache")
        XCTAssertEqual(try Data(contentsOf: src.appendingPathComponent("big/a.bin")).count, 300_000, "readable through the link")
    }

    func testNameCollisionGetsNumberedName() throws {
        let src = try makeTree(base.appendingPathComponent("Photos"))
        let file = base.appendingPathComponent("clip.mov")
        try write(file, bytes: 5_000)
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        try write(dest.appendingPathComponent("clip.mov"), bytes: 10)

        let out = run([src, file], .copy, to: dest)
        XCTAssertEqual(out.results.map { $0.destination?.lastPathComponent }, ["Photos 2", "clip 2.mov"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("clip.mov")).count, 10, "existing file untouched")
        XCTAssertTrue(out.results.allSatisfy(\.succeeded))
    }

    func testUnreadableFileBlocksMove() throws {
        let src = try makeTree(base.appendingPathComponent("Docs"))
        let secret = src.appendingPathComponent("big/secret.bin")
        try write(secret, bytes: 100)
        chmod(secret.path, 0o000)
        defer { chmod(secret.path, 0o644) }
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let r = try XCTUnwrap(run([src], .move, to: dest).results.first)
        XCTAssertFalse(r.succeeded)
        XCTAssertFalse(r.originalRemoved)
        XCTAssertTrue(fm.fileExists(atPath: src.path + "/big/inner/b.bin"), "original must be kept")
        XCTAssertTrue(r.errors.contains { $0.contains("secret.bin") }, "\(r.errors)")
    }

    func testVerifyDetectsMissingAndTruncatedFiles() throws {
        let src = try makeTree(base.appendingPathComponent("A"))
        let copy = base.appendingPathComponent("B")
        XCTAssertEqual(copyfile(src.path, copy.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)), 0)
        XCTAssertNil(TransferEngine.verify(source: src, copy: copy))
        truncate(copy.path + "/big/a.bin", 10)
        XCTAssertNotNil(TransferEngine.verify(source: src, copy: copy))
        try fm.removeItem(at: copy.appendingPathComponent("big"))
        XCTAssertNotNil(TransferEngine.verify(source: src, copy: copy))
    }

    func testSafetyChecks() throws {
        let src = try makeTree(base.appendingPathComponent("Proj"))
        let inside = src.appendingPathComponent("big")
        XCTAssertNotNil(run([src], .copy, to: inside).fatal, "can't copy into itself")
        XCTAssertNotNil(run([URL(fileURLWithPath: PathUtil.home)], .move, to: base).fatal, "home can't be moved")
        XCTAssertNotNil(run([URL(fileURLWithPath: "/System")], .move, to: base).fatal)
        XCTAssertNotNil(run([src], .copy, to: base.appendingPathComponent("missing")).fatal)
        XCTAssertTrue(fm.fileExists(atPath: src.path + "/small.txt"))
    }

    // MARK: exFAT (only when MSF_EXFAT_DEST is set)

    private func exfatDest() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MSF_EXFAT_DEST"] else { throw XCTSkip("MSF_EXFAT_DEST not set") }
        let dest = URL(fileURLWithPath: path).appendingPathComponent("msf-\(UUID().uuidString)")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dest) }
        return dest
    }

    func testExFATMoveWithoutLinks() throws {
        let dest = try exfatDest()
        let src = try makeTree(base.appendingPathComponent("Videos"), symlink: false)
        let r = try XCTUnwrap(run([src], .move, to: dest).results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertTrue(r.originalRemoved)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Videos/big/inner/b.bin")).count, 2_000_000)
    }

    func testExFATMigrate() throws {
        let dest = try exfatDest()
        let src = try makeTree(base.appendingPathComponent("Archive"), symlink: false)
        let r = try XCTUnwrap(run([src], .migrate, to: dest).results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertTrue(isSymlink(src))
        XCTAssertEqual(try Data(contentsOf: src.appendingPathComponent("big/a.bin")).count, 300_000)
    }

    func testExFATKeepsSymlinks() throws {
        // macOS's exFAT driver stores symlinks, so a folder containing one moves cleanly.
        let dest = try exfatDest()
        let src = try makeTree(base.appendingPathComponent("Code"), symlink: true)
        let r = try XCTUnwrap(run([src], .move, to: dest).results.first)
        XCTAssertTrue(r.succeeded, "\(r.errors)")
        XCTAssertTrue(isSymlink(dest.appendingPathComponent("Code/link")))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dest.path + "/Code/link"), "small.txt")
    }

    func testExFATIllegalNamesNeverLoseData() throws {
        // exFAT forbids ? * | " < > \ in names. Whatever the driver does, the original must
        // either be verified at the destination or stay put.
        let dest = try exfatDest()
        let src = base.appendingPathComponent("Odd")
        for name in ["what?.txt", "star*.txt", "pipe|.txt", "quote\".txt", "lt<gt>.txt", "back\\slash.txt"] {
            try write(src.appendingPathComponent(name), bytes: 1234)
        }
        let r = try XCTUnwrap(run([src], .move, to: dest).results.first)
        print("exFAT illegal-name result:", r.status, r.errors)
        if r.originalRemoved {
            XCTAssertTrue(r.errors.isEmpty)
            let names = try fm.contentsOfDirectory(atPath: dest.path + "/Odd")
            XCTAssertEqual(names.count, 6, "\(names)")
        } else {
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: src.path).count, 6, "original intact")
        }
    }
}

extension TransferTests {
    func testProgressReachesTotal() throws {
        let src = try makeTree(base.appendingPathComponent("P"))
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var updates: [TransferProgress] = []
        let out = TransferEngine { updates.append($0) }
            .run(items: [src], options: TransferOptions(mode: .copy, destination: dest, deletePermanently: false))
        XCTAssertNil(out.fatal)
        XCTAssertEqual(updates.last?.totalBytes, 1_000 + 300_000 + 2_000_000)
        XCTAssertEqual(updates.last?.doneBytes, updates.last?.totalBytes)
        XCTAssertTrue(updates.contains { $0.phase.hasPrefix("Copying") })
    }

    func testCancelKeepsOriginalAndRemovesPartialCopy() throws {
        let src = base.appendingPathComponent("Many")
        for i in 0..<40 { try write(src.appendingPathComponent("f\(i).bin"), bytes: 50_000) }
        let dest = base.appendingPathComponent("Dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        var engine: TransferEngine!
        engine = TransferEngine { p in if p.phase.hasPrefix("Copying") { engine.cancel() } }
        let out = engine.run(items: [src], options: TransferOptions(mode: .move, destination: dest, deletePermanently: true))
        let r = try XCTUnwrap(out.results.first)
        XCTAssertFalse(r.originalRemoved)
        XCTAssertTrue(r.status.contains("Cancelled"), r.status)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: src.path).count, 40, "original intact")
        XCTAssertFalse(fm.fileExists(atPath: dest.path + "/Many"), "partial copy removed")
    }

    func testVerifyDetectsChangedLinkTarget() throws {
        let src = try makeTree(base.appendingPathComponent("L"))
        let copy = base.appendingPathComponent("L2")
        XCTAssertEqual(copyfile(src.path, copy.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)), 0)
        XCTAssertNil(TransferEngine.verify(source: src, copy: copy))
        try fm.removeItem(at: copy.appendingPathComponent("link"))
        try fm.createSymbolicLink(atPath: copy.path + "/link", withDestinationPath: "elsewhere.txt")
        XCTAssertNotNil(TransferEngine.verify(source: src, copy: copy))
    }
}

@MainActor
final class ModelTests: XCTestCase {
    func testNestedSelectionTravelsWithParent() {
        let model = AppModel()
        model.beginTransfer(.copy, paths: ["/x/a", "/x/a/b", "/x/ab", "/x/c/d"])
        XCTAssertEqual(model.transferRequest?.items.map(\.path), ["/x/a", "/x/ab", "/x/c/d"])
    }
}

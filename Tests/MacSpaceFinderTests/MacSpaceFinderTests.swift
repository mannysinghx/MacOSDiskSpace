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
        let result = FolderTree(root: root).scan()
        let tree = result.tree

        let a = allocated(root.appendingPathComponent("big/a.bin"))
        let b = allocated(root.appendingPathComponent("big/inner/b.bin"))
        let small = allocated(root.appendingPathComponent("small.txt"))
        let link = allocated(root.appendingPathComponent("link"))

        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.stats.files, 4)
        XCTAssertEqual(result.stats.errors, 0)
        XCTAssertEqual(tree.size(of: root.path + "/big/inner"), b)
        XCTAssertEqual(tree.size(of: root.path + "/big"), a + b)
        XCTAssertEqual(tree.size(of: root.path), a + b + small + link)
        XCTAssertEqual(tree.childSizes(of: root.path), ["big": a + b])
        XCTAssertNil(tree.size(of: root.path + "/nope"))
        XCTAssertNil(tree.size(of: base.path), "outside the tree")

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
        let result = FolderTree(root: root).scan()
        let listed = result.biggest.map(\.path)
        XCTAssertTrue(listed.contains(root.path + "/Huge.app"), "\(listed)")
        XCTAssertFalse(listed.contains { $0.contains("Huge.app/") }, "\(listed)")
    }

    func testUnreadableFolderCountsAsErrorAndScanCompletes() throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let locked = root.appendingPathComponent("locked")
        try write(locked.appendingPathComponent("x.bin"), bytes: 50_000)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        let result = FolderTree(root: root).scan()
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.stats.errors, 1)
        XCTAssertEqual(result.tree.size(of: locked.path), 0)
        XCTAssertNotNil(result.tree.size(of: root.path))
    }

    // MARK: New scanner vs the previous (FileManager-based) one

    /// Synthetic tree, then real system folders full of app bundles. Set MSF_COMPARE_ROOT to add
    /// another folder (e.g. /Applications).
    func testMatchesPreviousScannerExactly() throws {
        let synthetic = base.appendingPathComponent("synthetic")
        try makeTree(synthetic)
        try write(synthetic.appendingPathComponent("Tool.app/Contents/MacOS/tool"), bytes: 400_000)
        try write(synthetic.appendingPathComponent("Tool.app/Contents/Resources/r.bin"), bytes: 900_000)
        try write(synthetic.appendingPathComponent("deep/1/2/3/4/5/f.bin"), bytes: 70_000)
        try write(synthetic.appendingPathComponent("wide/x.bin"), bytes: 1)
        for i in 0..<300 { try fm.createDirectory(at: synthetic.appendingPathComponent("wide/d\(i)"), withIntermediateDirectories: true) }
        try write(synthetic.appendingPathComponent("é-unicode/ü.bin"), bytes: 12_345)

        var roots = [synthetic.path, "/System/Library/CoreServices", "/System/Library/PrivateFrameworks/CoreSymbolication.framework"]
        if let extra = ProcessInfo.processInfo.environment["MSF_COMPARE_ROOT"] { roots.append(extra) }
        for path in roots where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let reference = ReferenceScanner.scan(root: url)
            let result = FolderTree(root: url).scan()
            XCTAssertFalse(result.cancelled)
            XCTAssertEqual(result.stats.files, reference.files, path)
            var mismatches = 0
            for (dir, size) in reference.sizes where result.tree.size(of: dir) != size {
                mismatches += 1
                if mismatches <= 5 { XCTFail("\(dir): new \(result.tree.size(of: dir) as Any) vs previous \(size)") }
            }
            XCTAssertEqual(mismatches, 0, path)
            let everyCandidate = result.tree.biggestFolders(limit: .max)
            XCTAssertEqual(Set(everyCandidate), Set(reference.candidates), path)
            XCTAssertEqual(result.biggest, Array(everyCandidate.prefix(FolderTree.biggestLimit)))
            print("compared \(path): \(reference.sizes.count) folders, \(reference.files) files, \(everyCandidate.count) candidates")
        }
    }

    func testSameResultWithOneOrManyWorkers() throws {
        let root = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        let reference = ReferenceScanner.scan(root: root)
        for workers in [1, 3, 8] {
            let tree = FolderTree(root: root).scan(workers: workers).tree
            let wrong = reference.sizes.filter { tree.size(of: $0.key) != $0.value }.count
            XCTAssertEqual(wrong, 0, "workers=\(workers)")
        }
    }

    func testCancelLeavesOnlyCorrectFinishedSizes() throws {
        let root = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        let reference = ReferenceScanner.scan(root: root)
        for delay in [0.0, 0.005, 0.02] {
            let tree = FolderTree(root: root)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { tree.cancel() }
            let result = tree.scan()
            var known = 0
            for (dir, size) in reference.sizes {
                guard let got = tree.size(of: dir) else { continue }
                known += 1
                XCTAssertEqual(got, size, dir)
            }
            if result.cancelled {
                XCTAssertTrue(result.biggest.isEmpty)
                XCTAssertNil(tree.size(of: root.path), "an unfinished root has no size")
            }
            print("cancel after \(delay)s: cancelled=\(result.cancelled), \(known)/\(reference.sizes.count) folders finished")
        }
        let early = FolderTree(root: root)
        early.cancel()
        XCTAssertTrue(early.scan().cancelled)
    }
}

/// The previous scanner (FileManager enumerator, one thread), kept as a reference. The one
/// deliberate difference: sizes come from lstat's st_blocks, like the new scanner and `du`.
/// (FileManager reports 0 bytes for some compressed files that really use one 4 KB block.)
enum ReferenceScanner {
    struct Result { var sizes: [String: Int64] = [:]; var files = 0; var candidates: [BigFolder] = [] }

    static func scan(root: URL) -> Result {
        struct Frame { let path: String; var size: Int64 = 0; var largest: Int64 = 0; let inPackage: Bool; let isPackage: Bool }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .isPackageKey]
        var out = Result()
        var stack = [Frame(path: root.path, inPackage: false, isPackage: false)]
        func pop() {
            let f = stack.removeLast()
            stack[stack.count - 1].size += f.size
            if !f.inPackage { stack[stack.count - 1].largest = max(stack[stack.count - 1].largest, f.size) }
            out.sizes[f.path] = f.size
            let largest = f.isPackage ? 0 : f.largest
            if !f.inPackage && f.size > 0 && Double(largest) < FolderTree.dominanceShare * Double(f.size) {
                out.candidates.append(BigFolder(path: f.path, size: f.size))
            }
        }
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })!
        while let url = en.nextObject() as? URL {
            while stack.count > en.level { pop() }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isSymbolicLink != true {
                if v?.isVolume == true { en.skipDescendants(); continue }
                let parent = stack[stack.count - 1]
                stack.append(Frame(path: url.path, inPackage: parent.inPackage || parent.isPackage, isPackage: v?.isPackage == true))
            } else {
                var st = stat()
                if lstat(url.path, &st) == 0 { stack[stack.count - 1].size += Int64(st.st_blocks) * 512 }
                out.files += 1
            }
        }
        while stack.count > 1 { pop() }
        out.sizes[root.path] = stack[0].size
        return out
    }
}

@MainActor
final class SizeStoreTests: TempDirTestCase {
    func testRescanReplacesSubfolderAndCorrectsParents() throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let big = root.path + "/big"
        let store = SizeStore()
        let first = FolderTree(root: root)
        store.add(first)
        let r1 = first.scan()
        store.finished(first, cancelled: r1.cancelled)
        let oldBig = try XCTUnwrap(store.size(of: big))
        let oldRoot = try XCTUnwrap(store.size(of: root.path))

        try write(root.appendingPathComponent("big/new.bin"), bytes: 1_000_000)
        store.invalidate(big)
        XCTAssertNil(store.size(of: big), "out of date while rescanning")
        XCTAssertNil(store.size(of: big + "/inner"))
        XCTAssertNil(store.childSizes(of: root.path)["big"])

        let second = FolderTree(root: URL(fileURLWithPath: big, isDirectory: true))
        store.add(second)
        store.finished(second, cancelled: second.scan().cancelled)
        let newBig = try XCTUnwrap(store.size(of: big))
        XCTAssertGreaterThan(newBig, oldBig)
        XCTAssertEqual(store.size(of: root.path), oldRoot + (newBig - oldBig), "parent corrected")
        XCTAssertEqual(store.childSizes(of: root.path)["big"], newBig)
        XCTAssertNotNil(store.size(of: big + "/inner"), "answered by the newer scan")
        XCTAssertEqual(store.trees.count, 2)
    }

    func testScanOfParentReplacesScanOfChild() throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let store = SizeStore()
        for url in [root.appendingPathComponent("big"), root] {
            let tree = FolderTree(root: url)
            store.add(tree)
            store.finished(tree, cancelled: tree.scan().cancelled)
        }
        XCTAssertEqual(store.trees.count, 1)
        XCTAssertEqual(store.trees.first?.root, root.path)
    }

    func testRemovedFolderAndFileShrinkParents() throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let store = SizeStore()
        let tree = FolderTree(root: root)
        store.add(tree)
        store.finished(tree, cancelled: tree.scan().cancelled)
        let total = try XCTUnwrap(store.size(of: root.path))
        let inner = try XCTUnwrap(store.size(of: root.path + "/big/inner"))
        let bigBefore = try XCTUnwrap(store.size(of: root.path + "/big"))

        store.removed(root.path + "/big/inner", size: inner)
        XCTAssertNil(store.size(of: root.path + "/big/inner"))
        XCTAssertEqual(store.size(of: root.path + "/big"), bigBefore - inner)
        XCTAssertEqual(store.size(of: root.path), total - inner)

        store.removed(root.path + "/big/a.bin", size: 4096)
        XCTAssertEqual(store.size(of: root.path + "/big"), bigBefore - inner - 4096)
        XCTAssertEqual(store.size(of: root.path), total - inner - 4096)
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

    func testScanSkipsMountedDisks() throws {
        // MSF_EXFAT_DEST is a mounted disk image: scanning the folder that contains the mount
        // point must not count anything on that disk.
        let dest = try exfatDest()
        try write(dest.appendingPathComponent("onDisk.bin"), bytes: 2_000_000)
        let mountPoint = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSF_EXFAT_DEST"]!)
        let parent = mountPoint.deletingLastPathComponent()
        let tree = FolderTree(root: parent).scan().tree
        XCTAssertNil(tree.childSizes(of: parent.path)[mountPoint.lastPathComponent])
        XCTAssertNil(tree.size(of: mountPoint.path))
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

/// Drives the real AppModel (no UI): browse -> scan -> sizes, cached navigation, rescan, biggest.
@MainActor
final class ModelScanTests: TempDirTestCase {
    private func waitForScan(_ model: AppModel) async throws {
        for _ in 0..<500 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isScanning, "scan did not finish")
    }

    func testBrowseRescanAndBiggest() async throws {
        let root = try makeTree(base.appendingPathComponent("root"))
        let big = root.appendingPathComponent("big")
        let model = AppModel()

        model.navigate(to: root)
        XCTAssertTrue(model.isScanning)
        try await waitForScan(model)
        let bigSize = allocated(big.appendingPathComponent("a.bin")) + allocated(big.appendingPathComponent("inner/b.bin"))
        XCTAssertEqual(model.entries.first { $0.name == "big" }?.size, bigSize)
        let rootTotal = try XCTUnwrap(model.currentTotal)

        model.navigate(to: big)
        XCTAssertFalse(model.isScanning, "already measured: no new scan")
        XCTAssertNotNil(model.entries.first { $0.name == "inner" }?.size)

        try write(big.appendingPathComponent("new.bin"), bytes: 3_000_000)
        model.rescan()
        try await waitForScan(model)
        let added = allocated(big.appendingPathComponent("new.bin"))
        XCTAssertEqual(model.currentTotal, bigSize + added)
        model.goUp()
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.currentTotal, rootTotal + added, "parent folder corrected after the rescan")
        XCTAssertEqual(model.entries.first { $0.name == "big" }?.size, bigSize + added)

        model.findBiggest()
        try await waitForScan(model)
        XCTAssertEqual(model.biggestRoot?.path, root.path)
        XCTAssertEqual(model.biggest.first?.path, big.path, "big now holds new.bin + inner, so it is listed itself")
    }
}

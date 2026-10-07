import Foundation

enum TransferMode: String, CaseIterable, Identifiable {
    case copy = "Copy"
    case move = "Move"
    case migrate = "Migrate"

    var id: Self { self }

    var explanation: String {
        switch self {
        case .copy: "Copies the items to the destination. The originals stay where they are."
        case .move: "Copies the items, checks every file arrived intact, then removes the originals to free space."
        case .migrate: "Moves the items like Move, then leaves a link at the old location pointing to the new one, so apps still find them. The destination disk must be connected for the link to work."
        }
    }
}

struct TransferOptions {
    var mode: TransferMode
    var destination: URL
    /// false = originals go to the Trash (space is freed when the Trash is emptied).
    var deletePermanently: Bool
}

struct TransferProgress {
    var phase: String = "Preparing…"
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var currentFile: String = ""
    var itemIndex: Int = 0
    var itemCount: Int = 0
}

struct TransferItemResult: Identifiable {
    let id = UUID()
    let source: URL
    var destination: URL?
    var copied = false
    var originalRemoved = false
    var linked = false
    var errors: [String] = []
    var status: String = ""

    var succeeded: Bool { copied && errors.isEmpty }
}

private let copyStatusCallback: copyfile_callback_t = { what, stage, state, src, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let engine = Unmanaged<TransferEngine>.fromOpaque(ctx).takeUnretainedValue()
    return engine.copyStatus(what: what, stage: stage, state: state, src: src)
}

/// Copies / moves / migrates files and folders using the system `copyfile` (keeps permissions,
/// dates, extended attributes). Originals are only removed after the copy finished without
/// errors and every file was verified at the destination.
final class TransferEngine {
    private let lock = NSLock()
    private var cancelRequested = false
    private let onProgress: (TransferProgress) -> Void

    // Copy state, touched only on the transfer thread.
    private var progress = TransferProgress()
    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var currentErrors: [String] = []
    private var lastPost = Date.distantPast

    init(onProgress: @escaping (TransferProgress) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool { lock.withLock { cancelRequested } }

    func cancel() { lock.withLock { cancelRequested = true } }

    /// Runs synchronously; call from a background thread.
    func run(items: [URL], options: TransferOptions) -> (results: [TransferItemResult], fatal: String?) {
        let fm = FileManager.default
        progress.itemCount = items.count

        // Pre-flight checks.
        let destPath = options.destination.path
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destPath, isDirectory: &isDir), isDir.boolValue else {
            return ([], "The destination folder \(destPath) does not exist.")
        }
        guard fm.isWritableFile(atPath: destPath) else {
            return ([], "The destination folder \(destPath) is not writable.")
        }
        for item in items {
            if PathUtil.isInside(destPath, item.path) {
                return ([], "Can't copy \(item.lastPathComponent) into itself.")
            }
            if options.mode != .copy, let reason = PathUtil.moveBlockReason(item.path) {
                return ([], "Can't move \(item.lastPathComponent): \(reason). Use Copy instead.")
            }
        }

        progress.phase = "Measuring…"
        post(force: true)
        var total: Int64 = 0
        for item in items {
            if isCancelled { return ([], "Cancelled.") }
            total += Self.logicalSize(of: item)
        }
        progress.totalBytes = total
        if let free = VolumeInfo.freeSpace(at: options.destination), free < total {
            return ([], "Not enough space: needs \(Fmt.bytes(total)), but only \(Fmt.bytes(free)) is free at the destination.")
        }

        var results: [TransferItemResult] = []
        for (index, src) in items.enumerated() {
            var r = TransferItemResult(source: src)
            if isCancelled {
                r.status = "Skipped (cancelled)"
                results.append(r)
                continue
            }
            progress.itemIndex = index + 1
            progress.phase = "Copying \(src.lastPathComponent)"
            post(force: true)

            let dst = Self.uniqueDestination(for: src, in: options.destination)
            r.destination = dst
            let copyOK = copyItem(src, to: dst)
            r.errors = currentErrors

            if isCancelled {
                // The destination did not exist before we started, so this only removes our partial copy.
                try? fm.removeItem(at: dst)
                r.destination = nil
                r.status = "Cancelled — partial copy removed"
                results.append(r)
                continue
            }
            r.copied = copyOK || fm.fileExists(atPath: dst.path)

            if options.mode == .copy {
                r.status = r.errors.isEmpty ? "Copied" : "Copied with \(r.errors.count) problem(s)"
                results.append(r)
                continue
            }

            // Move / migrate: never touch the original unless the copy is complete and verified.
            guard r.copied, r.errors.isEmpty else {
                r.status = "Not moved — copy had problems, original kept"
                results.append(r)
                continue
            }
            progress.phase = "Verifying \(src.lastPathComponent)"
            post(force: true)
            if let problem = Self.verify(source: src, copy: dst) {
                r.errors.append(problem)
                r.status = "Not moved — verification failed, original kept"
                results.append(r)
                continue
            }

            progress.phase = "Removing original \(src.lastPathComponent)"
            post(force: true)
            do {
                if options.deletePermanently {
                    try fm.removeItem(at: src)
                } else {
                    try fm.trashItem(at: src, resultingItemURL: nil)
                }
                r.originalRemoved = true
            } catch {
                r.errors.append("Copied and verified, but the original could not be removed: \(error.localizedDescription)")
                r.status = "Copied — original could not be removed"
                results.append(r)
                continue
            }

            if options.mode == .migrate {
                do {
                    try fm.createSymbolicLink(at: src, withDestinationURL: dst)
                    r.linked = true
                    r.status = "Migrated — link left at original location"
                } catch {
                    r.errors.append("Moved, but the link could not be created: \(error.localizedDescription)")
                    r.status = "Moved — link could not be created"
                }
            } else {
                r.status = options.deletePermanently ? "Moved — original deleted" : "Moved — original is in the Trash"
            }
            results.append(r)
        }
        progress.phase = "Done"
        progress.doneBytes = progress.totalBytes
        post(force: true)
        return (results, nil)
    }

    // MARK: - copyfile

    private func copyItem(_ src: URL, to dst: URL) -> Bool {
        currentErrors = []
        currentFileBytes = 0
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyStatusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
        let rc = copyfile(src.path, dst.path, state, flags)
        if rc != 0 && currentErrors.isEmpty && !isCancelled {
            currentErrors.append("Copy failed: \(String(cString: strerror(errno)))")
        }
        completedBytes += currentFileBytes
        currentFileBytes = 0
        return rc == 0
    }

    fileprivate func copyStatus(what: Int32, stage: Int32, state: copyfile_state_t?, src: UnsafePointer<CChar>?) -> Int32 {
        if isCancelled { return COPYFILE_QUIT }
        switch (what, stage) {
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            currentFileBytes = Int64(copied)
            post()
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            currentFileBytes = 0
            if let src { progress.currentFile = String(cString: src) }
            post()
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            var st = stat()
            if let src, lstat(src, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                completedBytes += Int64(st.st_size)
            }
            currentFileBytes = 0
            post()
        case (_, COPYFILE_ERR):
            let path = src.map { String(cString: $0) } ?? "?"
            currentErrors.append("\(path): \(String(cString: strerror(errno)))")
            return COPYFILE_SKIP
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    private func post(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPost) > 0.1 else { return }
        lastPost = now
        progress.doneBytes = min(completedBytes + currentFileBytes, max(progress.totalBytes, 1))
        onProgress(progress)
    }

    // MARK: - Helpers

    /// Sum of the logical sizes of all regular files at `url`.
    static func logicalSize(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return (st.st_mode & S_IFMT) == S_IFREG ? Int64(st.st_size) : 0 }
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        while let item = en?.nextObject() as? URL {
            if let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// "Movies" -> "Movies 2" (or "a.mov" -> "a 2.mov") if the name is already taken.
    static func uniqueDestination(for src: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(src.lastPathComponent)
        let ext = src.pathExtension
        let base = ext.isEmpty ? src.lastPathComponent : String(src.lastPathComponent.dropLast(ext.count + 1))
        var n = 2
        while fm.fileExists(atPath: candidate.path) || isSymlink(candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Checks that every file and folder in `source` exists in `copy`, with identical sizes for
    /// regular files. Returns a description of the first problem, or nil when all is well.
    static func verify(source: URL, copy: URL) -> String? {
        let srcRoot = source.path
        let dstRoot = copy.path

        func check(_ srcPath: String, _ dstPath: String) -> String? {
            var s = stat(), d = stat()
            guard lstat(srcPath, &s) == 0 else { return "Could not read \(srcPath)" }
            guard lstat(dstPath, &d) == 0 else { return "Missing at destination: \(dstPath)" }
            if (s.st_mode & S_IFMT) != (d.st_mode & S_IFMT) {
                return "Wrong kind of item at destination: \(dstPath)"
            }
            if (s.st_mode & S_IFMT) == S_IFREG && s.st_size != d.st_size {
                return "Size differs: \(dstPath) (\(d.st_size) vs \(s.st_size) bytes)"
            }
            if (s.st_mode & S_IFMT) == S_IFLNK,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: srcPath)) != (try? FileManager.default.destinationOfSymbolicLink(atPath: dstPath)) {
                return "Link target differs: \(dstPath)"
            }
            return nil
        }

        if let problem = check(srcRoot, dstRoot) { return problem }
        var s = stat()
        guard lstat(srcRoot, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { return nil }

        var readError: String?
        let en = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
            readError = "Could not read \(url.path): \(error.localizedDescription)"
            return false
        })
        while let item = en?.nextObject() as? URL {
            let path = item.path
            guard path.hasPrefix(srcRoot + "/") else { return "Unexpected path while verifying: \(path)" }
            if let problem = check(path, dstRoot + path.dropFirst(srcRoot.count)) { return problem }
        }
        return readError
    }
}

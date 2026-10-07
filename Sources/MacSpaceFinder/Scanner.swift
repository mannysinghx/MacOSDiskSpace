import Foundation

struct ScanProgress {
    var files: Int
    var bytes: Int64
    var currentPath: String
    var errors: Int
    /// Folders whose size was finalised since the previous report (path -> allocated bytes).
    var newSizes: [String: Int64]
}

struct ScanResult {
    let root: URL
    let files: Int
    let bytes: Int64
    let errors: Int
    let cancelled: Bool
    let newSizes: [String: Int64]
    let biggest: [BigFolder]
}

struct BigFolder: Identifiable, Hashable {
    let path: String
    var size: Int64
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

/// Walks a folder tree once and computes the allocated size of every folder in it.
enum FolderScanner {
    /// A folder whose largest subfolder holds at least this share of its size is left out of the
    /// "biggest folders" list, because that subfolder (listed itself) is where the space really is.
    static let dominanceShare = 0.8
    static let biggestLimit = 100

    private struct Frame {
        let path: String
        var size: Int64 = 0
        var largestSubfolder: Int64 = 0
        /// Inside an app bundle / library package: never suggested on its own.
        let inPackage: Bool
        let isPackage: Bool
    }

    /// Runs synchronously; call from a background task. Stops early when the task is cancelled.
    static func scan(root: URL, progress: (ScanProgress) -> Void) -> ScanResult {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .isPackageKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        let keySet = Set(keys)
        let rootPath = root.path
        // Scanning the startup disk: /System/Volumes/Data mirrors /Users etc. through APFS
        // firmlinks and would count every file twice; /Volumes holds other disks.
        let skipPaths: Set<String> = rootPath == "/" ? ["/System/Volumes", "/Volumes", "/dev"] : []

        var errors = 0
        var files = 0
        var bytes: Int64 = 0
        var stack = [Frame(path: rootPath, inPackage: false, isPackage: false)]
        var pending: [String: Int64] = [:]
        var candidates: [BigFolder] = []
        var cancelled = false
        var lastReport = Date()
        var iterations = 0

        func trimCandidates() {
            candidates.sort { $0.size > $1.size }
            if candidates.count > biggestLimit * 5 { candidates.removeLast(candidates.count - biggestLimit * 5) }
        }

        // Closes the deepest open folder: its size is final, so add it to its parent.
        func popFrame() {
            let f = stack.removeLast()
            stack[stack.count - 1].size += f.size
            if !f.inPackage {
                stack[stack.count - 1].largestSubfolder = max(stack[stack.count - 1].largestSubfolder, f.size)
            }
            pending[f.path] = f.size
            let largest = f.isPackage ? 0 : f.largestSubfolder
            if !f.inPackage && f.size > 0 && Double(largest) < dominanceShare * Double(f.size) {
                candidates.append(BigFolder(path: f.path, size: f.size))
                if candidates.count > biggestLimit * 40 { trimCandidates() }
            }
        }

        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
            errors += 1
            return true
        }) else {
            return ScanResult(root: root, files: 0, bytes: 0, errors: 1, cancelled: false, newSizes: [:], biggest: [])
        }

        while let obj = en.nextObject() {
            guard let url = obj as? URL else { continue }
            iterations += 1
            if iterations % 512 == 0 {
                if Task.isCancelled { cancelled = true; break }
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    progress(ScanProgress(files: files, bytes: bytes, currentPath: stack.last?.path ?? rootPath, errors: errors, newSizes: pending))
                    pending.removeAll(keepingCapacity: true)
                    lastReport = Date()
                }
            }

            // level 1 = direct child of root, whose parent frame is stack[0].
            while stack.count > en.level { popFrame() }

            let v = try? url.resourceValues(forKeys: keySet)
            if v?.isDirectory == true && v?.isSymbolicLink != true {
                let path = url.path
                if v?.isVolume == true || skipPaths.contains(path) {
                    en.skipDescendants()
                    continue
                }
                let parent = stack[stack.count - 1]
                stack.append(Frame(path: path, inPackage: parent.inPackage || parent.isPackage, isPackage: v?.isPackage == true))
            } else {
                let size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                stack[stack.count - 1].size += size
                files += 1
                bytes += size
            }
        }

        // A cancelled scan leaves the open folders incomplete; only report the finished ones.
        if !cancelled {
            while stack.count > 1 { popFrame() }
            pending[rootPath] = stack[0].size
        }
        trimCandidates()
        return ScanResult(
            root: root, files: files, bytes: bytes, errors: errors, cancelled: cancelled,
            newSizes: pending, biggest: cancelled ? [] : Array(candidates.prefix(biggestLimit))
        )
    }
}

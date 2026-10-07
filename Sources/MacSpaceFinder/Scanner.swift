import Foundation

struct BigFolder: Identifiable, Hashable {
    let path: String
    var size: Int64
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

struct ScanStats {
    var files = 0
    var bytes: Int64 = 0
    var errors = 0
    var currentPath = ""
}

struct ScanResult {
    let tree: FolderTree
    let stats: ScanStats
    let cancelled: Bool
    let biggest: [BigFolder]
}

/// The size of one folder and of every folder inside it.
///
/// Scanning reads each directory with `getattrlistbulk` (one system call returns a whole batch of
/// entries together with their allocated sizes) on several threads at once. Measured on an M4 Max,
/// this was ~7x faster than walking with FileManager on a 3M-file folder (78 s -> 11 s): SSDs answer
/// parallel metadata reads far faster than one-at-a-time ones. 6-8 threads was the sweet spot;
/// 12-16 was slower again because the workers queue up on the shared lock.
///
/// Folders are stored as nodes linked by index (parent / first child / next sibling) rather than
/// full path strings. Everything goes through `cond`, so the tree can be read while it is scanned.
final class FolderTree: @unchecked Sendable {
    /// A folder whose largest subfolder holds at least this share of its size is left out of the
    /// "biggest folders" list, because that subfolder (listed itself) is where the space really is.
    static let dominanceShare = 0.8
    static let biggestLimit = 100
    static var defaultWorkers: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    private struct Node {
        var parent: Int32
        var firstChild: Int32 = -1
        var nextSibling: Int32 = -1
        /// Subfolders not finished yet, plus 1 until this folder itself has been read. 0 = size is final.
        var pending: Int32 = 1
        var total: Int64 = 0
        var largestChild: Int64 = 0
        var name: String
        /// Rescanned elsewhere or moved away: this folder's own total can't be trusted…
        var stale = false
        /// …and nothing inside it can either.
        var staleBelow = false
    }

    let root: String
    let rootURL: URL
    private let cond = NSCondition()
    private var nodes: [Node]
    private var queue: [(node: Int32, path: String)] = []
    private var busyWorkers = 0
    private var cancelRequested = false
    private var stats = ScanStats()

    init(root: URL) {
        rootURL = root
        self.root = root.path
        nodes = [Node(parent: -1, name: root.path)]
    }

    // MARK: - Scanning

    /// Blocks until everything is measured or `cancel()` is called. Call from a background queue.
    func scan(workers: Int = FolderTree.defaultWorkers) -> ScanResult {
        // Scanning the startup disk: /System/Volumes/Data mirrors /Users etc. through APFS firmlinks
        // and would count every file twice; /Volumes holds other disks. (Mount points are skipped
        // anyway; the hidden /.vol, /.nofollow, /.resolve list as empty but are skipped to be safe.)
        let skip: Set<String> = root == "/"
            ? ["/System/Volumes", "/Volumes", "/dev", "/.vol", "/.nofollow", "/.resolve"]
            : []
        cond.lock()
        queue = [(0, root)]
        cond.unlock()

        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in work(skip: skip) }

        cond.lock()
        let cancelled = cancelRequested || nodes[0].pending != 0
        let finalStats = stats
        cond.unlock()
        let biggest = cancelled ? [] : biggestFolders()
        return ScanResult(tree: self, stats: finalStats, cancelled: cancelled, biggest: biggest)
    }

    func cancel() {
        cond.lock()
        cancelRequested = true
        cond.broadcast()
        cond.unlock()
    }

    func currentStats() -> ScanStats {
        cond.lock()
        defer { cond.unlock() }
        return stats
    }

    private func work(skip: Set<String>) {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        cond.lock()
        while true {
            while queue.isEmpty && busyWorkers > 0 && !cancelRequested { cond.wait() }
            if cancelRequested || queue.isEmpty { break }
            let job = queue.removeLast()
            busyWorkers += 1
            stats.currentPath = job.path
            cond.unlock()

            let listing = Self.readDirectory(job.path, followSymlink: job.node == 0, buffer: buffer, size: bufferSize)

            cond.lock()
            busyWorkers -= 1
            let id = Int(job.node)
            nodes[id].total += listing.ownBytes
            stats.files += listing.files
            stats.bytes += listing.ownBytes
            stats.errors += listing.errors
            var added: Int32 = 0
            for name in listing.subfolders {
                let path = job.path == "/" ? "/" + name : job.path + "/" + name
                if skip.contains(path) { continue }
                let child = Int32(nodes.count)
                nodes.append(Node(parent: job.node, nextSibling: nodes[id].firstChild, name: name))
                nodes[id].firstChild = child
                queue.append((child, path))
                added += 1
            }
            nodes[id].pending += added - 1
            if nodes[id].pending == 0 { finish(job.node) }
            cond.broadcast()
        }
        cond.broadcast()
        cond.unlock()
    }

    /// A folder's size is final: add it to its parent, and finish the parent too if that was the
    /// last thing it was waiting for. Lock held.
    private func finish(_ index: Int32) {
        var i = Int(index)
        while true {
            let p = Int(nodes[i].parent)
            if p < 0 { return }
            nodes[p].total += nodes[i].total
            nodes[p].largestChild = max(nodes[p].largestChild, nodes[i].total)
            nodes[p].pending -= 1
            if nodes[p].pending != 0 { return }
            i = p
        }
    }

    private struct Listing {
        var ownBytes: Int64 = 0
        var files = 0
        var errors = 0
        var subfolders: [String] = []
    }

    /// Reads one directory: allocated bytes of its files, and the names of its subfolders
    /// (mount points of other disks excluded).
    private static func readDirectory(_ path: String, followSymlink: Bool, buffer: UnsafeMutableRawPointer, size: Int) -> Listing {
        var out = Listing()
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followSymlink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            out.errors = 1
            return out
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_ERROR)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let skipMount = UInt32(DIR_MNTSTATUS_MNTPOINT) | UInt32(DIR_MNTSTATUS_TRIGGER)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, size, 0)
            if count < 0 {
                if errno == EINTR { continue }
                out.errors += 1
                break
            }
            if count == 0 { break }

            // Each entry: length, returned-attribute bitmap, then the attributes in bit order.
            var entry = buffer
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var name: UnsafeRawPointer?
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    name = UnsafeRawPointer(p + Int(ref.attr_dataoffset))
                    p += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    if p.loadUnaligned(as: UInt32.self) != 0 { out.errors += 1 }
                    p += 4
                }
                var mountStatus: UInt32 = 0
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    mountStatus = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = p.loadUnaligned(as: Int64.self)
                }

                if type == VDIR.rawValue {
                    if mountStatus & skipMount == 0, let name {
                        out.subfolders.append(String(cString: name.assumingMemoryBound(to: CChar.self)))
                    }
                } else {
                    out.ownBytes += allocated
                    out.files += 1
                }
                entry += Int(length)
            }
        }
        return out
    }

    // MARK: - Biggest folders

    /// The biggest folders, skipping any folder whose largest subfolder holds most of its space.
    /// App bundles and other packages are listed whole, never their insides. Whether a folder is a
    /// package is only looked up for the few folders that reach this list, which keeps scanning fast.
    func biggestFolders(limit: Int = FolderTree.biggestLimit) -> [BigFolder] {
        cond.lock()
        defer { cond.unlock() }
        guard nodes.count > 1 else { return [] }
        var order = Array(Int32(1)..<Int32(nodes.count))
        order.sort { nodes[Int($0)].total > nodes[Int($1)].total }

        var packageMemo: [Int32: Bool] = [:]
        var insideMemo: [Int32: Bool] = [:]
        func isPackage(_ i: Int32) -> Bool {
            if i == 0 { return false }  // the scanned folder itself never counts as a package
            if let known = packageMemo[i] { return known }
            let url = URL(fileURLWithPath: pathLocked(i), isDirectory: true)
            let value = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            packageMemo[i] = value
            return value
        }
        func insidePackage(_ i: Int32) -> Bool {
            let p = nodes[Int(i)].parent
            if p <= 0 { return false }
            if let known = insideMemo[i] { return known }
            let value = isPackage(p) || insidePackage(p)
            insideMemo[i] = value
            return value
        }

        var out: [BigFolder] = []
        for i in order {
            let n = nodes[Int(i)]
            if n.total <= 0 || out.count >= limit { break }
            if n.pending != 0 || n.stale || insidePackage(i) { continue }
            let dominated = Double(n.largestChild) >= Self.dominanceShare * Double(n.total)
            if dominated && !isPackage(i) { continue }
            out.append(BigFolder(path: pathLocked(i), size: n.total))
        }
        return out
    }

    // MARK: - Lookups (safe while scanning)

    /// Final size of the folder at `path`, or nil if it isn't measured (yet) or is out of date.
    func size(of path: String) -> Int64? {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, trusted) = locate(path), trusted, nodes[i].pending == 0, !nodes[i].stale else { return nil }
        return nodes[i].total
    }

    /// Final sizes of the subfolders of `path` that are measured, by name.
    func childSizes(of path: String) -> [String: Int64] {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, trusted) = locate(path), trusted, !nodes[i].staleBelow else { return [:] }
        var out: [String: Int64] = [:]
        var c = nodes[i].firstChild
        while c >= 0 {
            let n = nodes[Int(c)]
            if n.pending == 0 && !n.stale { out[n.name] = n.total }
            c = n.nextSibling
        }
        return out
    }

    // MARK: - Keeping older measurements honest

    /// `path` is being rescanned: its size here, and everything inside it, is out of date.
    func invalidate(_ path: String) {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, _) = locate(path) else { return }
        nodes[i].stale = true
        nodes[i].staleBelow = true
    }

    /// A newer scan measured `path` at `total`: use it, and correct every folder above it.
    func replaceTotal(of path: String, with total: Int64) {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, _) = locate(path), nodes[i].pending == 0 else { return }
        let delta = total - nodes[i].total
        nodes[i].total = total
        nodes[i].stale = false
        adjustAncestors(of: i, by: delta)
    }

    /// The item at `path` (a folder, or a file of `size` bytes) was moved away or deleted.
    func removeItem(at path: String, size: Int64) {
        cond.lock()
        defer { cond.unlock() }
        if let (i, _) = locate(path) {
            guard nodes[i].pending == 0, !nodes[i].stale else { return }
            nodes[i].stale = true
            nodes[i].staleBelow = true
            adjustAncestors(of: i, by: -nodes[i].total)
        } else if let (parent, _) = locate((path as NSString).deletingLastPathComponent), path != root {
            nodes[parent].total = max(0, nodes[parent].total - size)
            adjustAncestors(of: parent, by: -size)
        }
    }

    private func adjustAncestors(of index: Int, by delta: Int64) {
        var p = Int(nodes[index].parent)
        while p >= 0 {
            nodes[p].total = max(0, nodes[p].total + delta)
            p = Int(nodes[p].parent)
        }
    }

    // MARK: - Paths

    /// Node index for `path`; `trusted` is false when the path lies inside an out-of-date folder.
    private func locate(_ path: String) -> (Int, Bool)? {
        guard PathUtil.isInside(path, root) else { return nil }
        var i = 0
        var trusted = true
        for component in path.dropFirst(root.count).split(separator: "/") {
            if nodes[i].staleBelow { trusted = false }
            var c = nodes[i].firstChild
            while c >= 0 && nodes[Int(c)].name != component { c = nodes[Int(c)].nextSibling }
            if c < 0 { return nil }
            i = Int(c)
        }
        return (i, trusted)
    }

    private func pathLocked(_ index: Int32) -> String {
        var parts: [String] = []
        var i = Int(index)
        while i > 0 {
            parts.append(nodes[i].name)
            i = Int(nodes[i].parent)
        }
        if parts.isEmpty { return root }
        let relative = parts.reversed().joined(separator: "/")
        return root == "/" ? "/" + relative : root + "/" + relative
    }
}

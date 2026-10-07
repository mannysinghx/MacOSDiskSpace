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
/// full path strings. Everything goes through `cond`, so the tree can be read while it is scanned,
/// and updated folder by folder afterwards when change notices arrive.
final class FolderTree: @unchecked Sendable {
    /// A folder whose largest subfolder holds at least this share of its size is left out of the
    /// "biggest folders" list, because that subfolder (listed itself) is where the space really is.
    static let dominanceShare = 0.8
    static let biggestLimit = 100
    static var defaultWorkers: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    /// Whether remembered sizes are known to be current. Main thread only.
    enum History {
        /// Measured during this session.
        case fresh
        /// Loaded from the cache; replaying the changes made since it was saved.
        case checking
        /// Loaded from the cache and every change since has been applied.
        case upToDate
        /// Loaded from the cache, but changes since can't be known (external disk, or the
        /// disk's change history was reset).
        case unverified
    }

    private struct Node {
        var parent: Int32
        var firstChild: Int32 = -1
        var nextSibling: Int32 = -1
        /// Subfolders not finished yet, plus 1 until this folder itself has been read. 0 = size is final.
        var pending: Int32 = 1
        /// Bytes of the files directly inside this folder.
        var own: Int64 = 0
        /// `own` plus every subfolder.
        var total: Int64 = 0
        var name: String
        /// Rescanned elsewhere: this folder's own total can't be trusted…
        var stale = false
        /// …and nothing inside it can either.
        var staleBelow = false
        /// Unlinked from its parent (deleted or moved away). Dropped at the next save.
        var detached = false
    }

    /// One folder in a saved or copied tree; nodes come parent-first and `parent` indexes the list.
    struct ExportedNode {
        var parent: Int32
        var own: Int64
        var total: Int64
        var name: String
        var stale: Bool
        var staleBelow: Bool
    }

    struct Snapshot {
        let id: UUID
        let root: String
        let scanDate: Date
        let eventID: UInt64
        let volumeUUID: String?
        let nodes: [ExportedNode]
    }

    let id: UUID
    let root: String
    let rootURL: URL
    let scanDate: Date
    /// FSEvents id of the disk's change history this tree was measured against.
    let volumeUUID: String?
    /// Loaded from the cache rather than measured in this session.
    let restored: Bool
    var history: History

    private let skipPaths: Set<String>
    private let cond = NSCondition()
    private var nodes: [Node]
    private var queue: [(node: Int32, path: String)] = []
    private var busyWorkers = 0
    private var cancelRequested = false
    private var stats = ScanStats()
    /// Every change up to this FSEvents event id is reflected in the sizes.
    private var eventID: UInt64
    /// Changed since it was last saved.
    private var dirty = false

    init(root: URL) {
        id = UUID()
        rootURL = root
        self.root = root.path
        scanDate = Date()
        // Taken before scanning: changes made during the scan are replayed afterwards.
        eventID = ChangeWatcher.currentEventID
        volumeUUID = ChangeWatcher.volumeUUID(for: root.path)
        restored = false
        history = .fresh
        skipPaths = Self.skipPaths(for: root.path)
        nodes = [Node(parent: -1, name: root.path)]
    }

    init(snapshot s: Snapshot) {
        id = s.id
        root = s.root
        rootURL = URL(fileURLWithPath: s.root, isDirectory: true)
        scanDate = s.scanDate
        eventID = s.eventID
        volumeUUID = s.volumeUUID
        restored = true
        history = .unverified
        skipPaths = Self.skipPaths(for: s.root)
        nodes = []
        nodes.reserveCapacity(s.nodes.count)
        for (k, e) in s.nodes.enumerated() {
            nodes.append(Node(parent: e.parent, pending: 0, own: e.own, total: e.total,
                              name: k == 0 ? s.root : e.name, stale: e.stale, staleBelow: e.staleBelow))
            if e.parent >= 0 { link(Int32(k), under: Int(e.parent)) }
        }
        if nodes.isEmpty { nodes = [Node(parent: -1, pending: 0, name: s.root)] }
        stats.bytes = nodes[0].total
    }

    /// Scanning the startup disk: /System/Volumes/Data mirrors /Users etc. through APFS firmlinks
    /// and would count every file twice; /Volumes holds other disks. (Mount points are skipped
    /// anyway; the hidden /.vol, /.nofollow, /.resolve list as empty but are skipped to be safe.)
    private static func skipPaths(for root: String) -> Set<String> {
        root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/.vol", "/.nofollow", "/.resolve"] : []
    }

    // MARK: - Scanning

    /// Blocks until everything is measured or `cancel()` is called. Call from a background queue.
    func scan(workers: Int = FolderTree.defaultWorkers) -> ScanResult {
        cond.lock()
        queue = [(0, root)]
        cond.unlock()

        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in work() }

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

    /// Measured completely (not cancelled, not still running).
    var isComplete: Bool {
        cond.lock()
        defer { cond.unlock() }
        return nodes[0].pending == 0 && !cancelRequested
    }

    private func work() {
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
            nodes[id].own = listing.ownBytes
            nodes[id].total += listing.ownBytes
            stats.files += listing.files
            stats.bytes += listing.ownBytes
            stats.errors += listing.errors
            var added: Int32 = 0
            for name in listing.subfolders {
                let path = Self.join(job.path, name)
                if skipPaths.contains(path) { continue }
                let child = Int32(nodes.count)
                nodes.append(Node(parent: job.node, name: name))
                link(child, under: id)
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
            nodes[p].pending -= 1
            if nodes[p].pending != 0 { return }
            i = p
        }
    }

    private struct Listing {
        var opened = true
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
            out.opened = false
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

    /// The biggest folders inside `path` (default: the whole tree), skipping any folder whose
    /// largest subfolder holds most of its space. App bundles and other packages are listed whole,
    /// never their insides. Whether a folder is a package is only looked up for the few folders that
    /// reach this list, which keeps scanning fast.
    func biggestFolders(in path: String? = nil, limit: Int = FolderTree.biggestLimit) -> [BigFolder] {
        cond.lock()
        defer { cond.unlock() }
        guard let (start, trusted) = locate(path ?? root), trusted,
              nodes[start].pending == 0, !nodes[start].stale, !nodes[start].staleBelow else { return [] }

        // Everything below `start`, and each folder's largest subfolder.
        var largest = [Int64](repeating: 0, count: nodes.count)
        var order: [Int32] = []
        var stack = [Int32(start)]
        while let n = stack.popLast() {
            if nodes[Int(n)].staleBelow { continue }
            forEachChild(Int(n)) { c in
                largest[Int(n)] = max(largest[Int(n)], nodes[c].total)
                order.append(Int32(c))
                stack.append(Int32(c))
            }
        }
        order.sort { nodes[Int($0)].total > nodes[Int($1)].total }

        var packageMemo: [Int32: Bool] = [:]
        var insideMemo: [Int32: Bool] = [:]
        func isPackage(_ i: Int32) -> Bool {
            if Int(i) == start { return false }  // the folder being listed never counts as a package
            if let known = packageMemo[i] { return known }
            let url = URL(fileURLWithPath: pathLocked(i), isDirectory: true)
            let value = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            packageMemo[i] = value
            return value
        }
        func insidePackage(_ i: Int32) -> Bool {
            let p = nodes[Int(i)].parent
            if p < 0 || Int(p) == start { return false }
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
            let dominated = Double(largest[Int(i)]) >= Self.dominanceShare * Double(n.total)
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
        forEachChild(i) { c in
            if nodes[c].pending == 0 && !nodes[c].stale { out[nodes[c].name] = nodes[c].total }
        }
        return out
    }

    // MARK: - Keeping sizes current

    /// `path` is being rescanned: its size here, and everything inside it, is out of date.
    func invalidate(_ path: String) {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, _) = locate(path) else { return }
        nodes[i].stale = true
        nodes[i].staleBelow = true
        dirty = true
    }

    /// A newer scan measured `path` at `total`: use it, and correct every folder above it.
    func replaceTotal(of path: String, with total: Int64) {
        cond.lock()
        defer { cond.unlock() }
        guard let (i, _) = locate(path), nodes[i].pending == 0 else { return }
        let delta = total - nodes[i].total
        if delta == 0 && !nodes[i].stale { return }
        nodes[i].total = total
        nodes[i].stale = false
        adjustAncestors(of: i, by: delta)
        dirty = true
    }

    /// The item at `path` (a folder, or a file of `size` bytes) was moved away or deleted.
    /// A later change notice for its parent re-reads the folder, so this only has to be close.
    func removeItem(at path: String, size: Int64) {
        cond.lock()
        defer { cond.unlock() }
        if let (i, _) = locate(path) {
            guard i != 0, nodes[i].pending == 0 else { return }
            detach(i)
        } else if path != root, let (p, _) = locate((path as NSString).deletingLastPathComponent), nodes[p].pending == 0 {
            let removed = min(size, nodes[p].own)
            nodes[p].own -= removed
            nodes[p].total -= removed
            adjustAncestors(of: p, by: -removed)
            dirty = true
        }
    }

    /// Applies one batch of change notices: folders whose contents changed are re-read on their
    /// own; `wholeSubtree` paths (the notices were too many to keep) are measured again in full.
    /// Returns true if any size changed.
    func apply(changedFolders: [String], wholeSubtrees: [String]) -> Bool {
        var changed = false
        // A notice above the root covers the whole tree.
        let subtrees = wholeSubtrees.map { PathUtil.isInside(root, $0) ? root : $0 }.filter { PathUtil.isInside($0, root) }
        let tops = Self.topMost(subtrees)
        for path in tops where rescanSubtree(path) { changed = true }
        let folders = Set(changedFolders).filter { p in
            PathUtil.isInside(p, root) && !tops.contains { PathUtil.isInside(p, $0) }
        }
        for path in folders.sorted() where refreshFolder(path) { changed = true }
        return changed
    }

    /// Re-reads just the folder at `path`: the total of its files and the list of its subfolders.
    /// Subfolders that are gone are dropped; new ones are measured in full. Safe to repeat.
    @discardableResult
    func refreshFolder(_ path: String) -> Bool {
        cond.lock()
        guard let (i, trusted) = locate(path), trusted, nodes[i].pending == 0,
              !nodes[i].stale, !nodes[i].staleBelow else {
            cond.unlock()
            return false
        }
        var known = Set<String>()
        forEachChild(i) { known.insert(nodes[$0].name) }
        cond.unlock()

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let listing = Self.readDirectory(path, followSymlink: i == 0, buffer: buffer, size: bufferSize)
        buffer.deallocate()
        // Folder gone: the notice for its parent drops it.
        guard listing.opened else { return false }
        let present = Set(listing.subfolders.filter { !skipPaths.contains(Self.join(path, $0)) })

        var measured: [(name: String, tree: FolderTree)] = []
        for name in present.subtracting(known) {
            let sub = FolderTree(root: URL(fileURLWithPath: Self.join(path, name), isDirectory: true))
            if !sub.scan().cancelled { measured.append((name, sub)) }
        }

        cond.lock()
        defer { cond.unlock() }
        guard let (j, _) = locate(path), j == i else { return false }
        var changed = false
        let delta = listing.ownBytes - nodes[i].own
        if delta != 0 {
            nodes[i].own += delta
            nodes[i].total += delta
            adjustAncestors(of: i, by: delta)
            changed = true
        }
        var gone: [Int] = []
        forEachChild(i) { c in if !present.contains(nodes[c].name) { gone.append(c) } }
        for c in gone { detach(c) }
        for (name, sub) in measured where !hasChild(i, named: name) { attach(sub, under: i, as: name) }
        changed = changed || !gone.isEmpty || !measured.isEmpty
        if changed { dirty = true }
        return changed
    }

    /// Measures the folder at `path` again in full and swaps it in.
    @discardableResult
    func rescanSubtree(_ path: String) -> Bool {
        if path == root {
            let fresh = FolderTree(root: rootURL)
            guard !fresh.scan().cancelled else { return false }
            replaceAll(with: fresh)
            return true
        }
        cond.lock()
        let found = locate(path)
        cond.unlock()
        guard let (i, _) = found else {
            // Not known yet: re-read the nearest folder that is; that picks the new one up.
            var parent = (path as NSString).deletingLastPathComponent
            while PathUtil.isInside(parent, root) {
                if size(of: parent) != nil { return refreshFolder(parent) }
                if parent == root { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        let fresh = FolderTree(root: URL(fileURLWithPath: path, isDirectory: true))
        if exists && fresh.scan().cancelled { return false }

        cond.lock()
        defer { cond.unlock() }
        guard let (j, _) = locate(path), j == i, nodes[i].pending == 0 else { return false }
        let parent = Int(nodes[i].parent)
        let name = nodes[i].name
        detach(i)
        if exists { attach(fresh, under: parent, as: name) }
        dirty = true
        return true
    }

    /// Every change up to this FSEvents event id is reflected in the sizes.
    var appliedEventID: UInt64 {
        cond.lock()
        defer { cond.unlock() }
        return eventID
    }

    /// Records that every change up to `id` has been applied.
    func noteEvents(upTo id: UInt64) {
        cond.lock()
        defer { cond.unlock() }
        if id > eventID { eventID = id }
    }

    var needsSave: Bool {
        cond.lock()
        defer { cond.unlock() }
        return dirty
    }

    // MARK: - Saving and copying

    /// A consistent copy of the whole tree for the cache. Only meaningful once `isComplete`.
    func snapshot(clearingDirty: Bool = false) -> Snapshot {
        cond.lock()
        defer { cond.unlock() }
        if clearingDirty { dirty = false }
        return Snapshot(id: id, root: root, scanDate: scanDate, eventID: eventID, volumeUUID: volumeUUID, nodes: exportLocked())
    }

    func exportNodes() -> [ExportedNode] {
        cond.lock()
        defer { cond.unlock() }
        return exportLocked()
    }

    /// Reachable folders, parent before children. Lock held.
    private func exportLocked() -> [ExportedNode] {
        var out: [ExportedNode] = []
        out.reserveCapacity(nodes.count)
        var stack: [(node: Int, newParent: Int32)] = [(0, -1)]
        while let (n, newParent) = stack.popLast() {
            let node = nodes[n]
            out.append(ExportedNode(parent: newParent, own: node.own, total: node.total, name: node.name,
                                    stale: node.stale, staleBelow: node.staleBelow))
            let me = Int32(out.count - 1)
            forEachChild(n) { stack.append(($0, me)) }
        }
        return out
    }

    /// Lock held on self; `sub` is a finished, private tree.
    private func attach(_ sub: FolderTree, under parent: Int, as name: String) {
        let exported = sub.exportNodes()
        guard !exported.isEmpty else { return }
        let base = Int32(nodes.count)
        for (k, e) in exported.enumerated() {
            let p = k == 0 ? Int32(parent) : base + e.parent
            nodes.append(Node(parent: p, pending: 0, own: e.own, total: e.total, name: k == 0 ? name : e.name,
                              stale: e.stale, staleBelow: e.staleBelow))
            link(base + Int32(k), under: Int(p))
        }
        nodes[parent].total += exported[0].total
        adjustAncestors(of: parent, by: exported[0].total)
        dirty = true
    }

    private func replaceAll(with fresh: FolderTree) {
        let exported = fresh.exportNodes()
        cond.lock()
        defer { cond.unlock() }
        nodes = []
        nodes.reserveCapacity(exported.count)
        for (k, e) in exported.enumerated() {
            nodes.append(Node(parent: e.parent, pending: 0, own: e.own, total: e.total, name: k == 0 ? root : e.name))
            if e.parent >= 0 { link(Int32(k), under: Int(e.parent)) }
        }
        dirty = true
    }

    /// Unlinks a folder from its parent and takes its size off every folder above. Lock held.
    private func detach(_ c: Int) {
        let p = Int(nodes[c].parent)
        guard p >= 0, !nodes[c].detached else { return }
        if Int(nodes[p].firstChild) == c {
            nodes[p].firstChild = nodes[c].nextSibling
        } else {
            var s = Int(nodes[p].firstChild)
            while s >= 0 && Int(nodes[s].nextSibling) != c { s = Int(nodes[s].nextSibling) }
            if s >= 0 { nodes[s].nextSibling = nodes[c].nextSibling }
        }
        nodes[c].detached = true
        nodes[c].nextSibling = -1
        if nodes[c].pending == 0 {
            nodes[p].total = max(0, nodes[p].total - nodes[c].total)
            adjustAncestors(of: p, by: -nodes[c].total)
        }
        dirty = true
    }

    private func adjustAncestors(of index: Int, by delta: Int64) {
        guard delta != 0 else { return }
        var p = Int(nodes[index].parent)
        while p >= 0 {
            nodes[p].total = max(0, nodes[p].total + delta)
            p = Int(nodes[p].parent)
        }
    }

    // MARK: - Paths and links

    private func link(_ child: Int32, under parent: Int) {
        nodes[Int(child)].nextSibling = nodes[parent].firstChild
        nodes[parent].firstChild = child
    }

    private func forEachChild(_ i: Int, _ body: (Int) -> Void) {
        var c = nodes[i].firstChild
        while c >= 0 {
            let next = nodes[Int(c)].nextSibling
            body(Int(c))
            c = next
        }
    }

    private func hasChild(_ i: Int, named name: String) -> Bool {
        var found = false
        forEachChild(i) { if nodes[$0].name == name { found = true } }
        return found
    }

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
        return Self.join(root, parts.reversed().joined(separator: "/"))
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// Drops paths that lie inside another path in the list.
    private static func topMost(_ paths: [String]) -> [String] {
        let unique = Set(paths)
        return unique.filter { p in !unique.contains { $0 != p && PathUtil.isInside(p, $0) } }.sorted()
    }
}

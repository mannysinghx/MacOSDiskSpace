import Foundation

/// Every folder tree measured so far, newest first. Answers "how big is this folder?" with the
/// freshest measurement available, keeps the trees current with FSEvents change notices, and
/// remembers them between launches.
@MainActor
final class SizeStore {
    static let maxTrees = 25

    private(set) var trees: [FolderTree] = []
    /// Sizes changed outside a scan (change notices, remembered sizes caught up).
    var onChange: (() -> Void)?

    private let cache: ScanCache?
    private let watchChanges: Bool
    private var watchers: [UUID: ChangeWatcher] = [:]
    private var saveScheduled = false
    private static let ioQueue = DispatchQueue(label: "MacSpaceFinder.cache", qos: .utility)

    init(cache: ScanCache? = nil, watchChanges: Bool = false) {
        self.cache = cache
        self.watchChanges = watchChanges
    }

    // MARK: - Lookups

    func add(_ tree: FolderTree) {
        trees.insert(tree, at: 0)
    }

    func size(of path: String) -> Int64? {
        for tree in trees where PathUtil.isInside(path, tree.root) {
            if let size = tree.size(of: path) { return size }
        }
        return nil
    }

    /// Sizes of the measured subfolders of `path`, by name; newer scans win.
    func childSizes(of path: String) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for tree in trees.reversed() where PathUtil.isInside(path, tree.root) {
            out.merge(tree.childSizes(of: path)) { _, newer in newer }
        }
        return out
    }

    /// The tree whose size for `path` is being shown.
    func tree(answering path: String) -> FolderTree? {
        trees.first { PathUtil.isInside(path, $0.root) && $0.size(of: path) != nil }
    }

    /// A tree that can list the biggest folders inside `path` without scanning again: it has
    /// measured `path` completely and no newer scan covers part of it.
    func treeForBiggest(in path: String) -> FolderTree? {
        guard let tree = tree(answering: path), let index = trees.firstIndex(where: { $0 === tree }) else { return nil }
        let newerInside = trees[..<index].contains { PathUtil.isInside($0.root, path) }
        return newerInside ? nil : tree
    }

    // MARK: - Scans

    /// `path` is about to be rescanned: drop scans of folders inside it, and mark it out of date
    /// in scans that contain it.
    func invalidate(_ path: String) {
        drop(trees.filter { PathUtil.isInside($0.root, path) })
        for tree in trees { tree.invalidate(path) }
    }

    /// `tree` finished: older scans that contain it take over its total (so their parent folders
    /// are corrected), older scans inside it are replaced by it, and it is saved and watched.
    func finished(_ tree: FolderTree, cancelled: Bool) {
        guard !cancelled, let index = trees.firstIndex(where: { $0 === tree }), tree.size(of: tree.root) != nil else { return }
        syncNested()
        drop(trees[(index + 1)...].filter { PathUtil.isInside($0.root, tree.root) })
        save(tree)
        // Replays anything that changed while the scan was running, then keeps watching.
        startWatching(tree, since: tree.appliedEventID)
        trimToLimit()
    }

    /// The item at `path` (`size` bytes) was moved away or deleted.
    func removed(_ path: String, size: Int64) {
        drop(trees.filter { PathUtil.isInside($0.root, path) })
        for tree in trees { tree.removeItem(at: path, size: size) }
        syncNested()
    }

    // MARK: - Remembering between launches

    /// Takes over the trees loaded from the cache (newest first). On the internal disk, the
    /// changes made since each was saved are replayed from FSEvents; elsewhere that history
    /// can't be trusted (changes made on another computer are never recorded), so those trees
    /// are marked unverified.
    func restore(_ restored: [FolderTree]) {
        for tree in restored {
            let exists = FileManager.default.fileExists(atPath: tree.root)
            if !exists && !Self.diskIsGone(for: tree.root) {
                // The folder was deleted or moved while the app was closed.
                if let cache { Self.ioQueue.async { cache.delete(id: tree.id) } }
                continue
            }
            trees.append(tree)
            let history = exists ? ChangeWatcher.volumeUUID(for: tree.root) : nil
            let trusted = exists && Self.isOnInternalDisk(tree.root) && history != nil && history == tree.volumeUUID
            tree.history = trusted ? .checking : .unverified
            if exists { startWatching(tree, since: trusted ? tree.appliedEventID : ChangeWatcher.sinceNow) }
        }
        trimToLimit()
    }

    /// Saves every tree that changed since it was last saved. Blocks; used when quitting.
    func saveNow() {
        guard let cache else { return }
        Self.ioQueue.sync {}
        for tree in trees where tree.isComplete && tree.needsSave {
            try? cache.save(tree.snapshot(clearingDirty: true))
        }
    }

    /// A disk was plugged in or ejected.
    func volumesChanged() {
        guard watchChanges else { return }
        var changed = false
        for tree in trees where tree.isComplete {
            let exists = FileManager.default.fileExists(atPath: tree.root)
            if exists && watchers[tree.id] == nil {
                // Back again, but it may have been changed elsewhere in the meantime.
                tree.history = .unverified
                startWatching(tree, since: ChangeWatcher.sinceNow)
                changed = true
            } else if !exists && watchers[tree.id] != nil {
                stopWatching(tree)
            }
        }
        if changed { onChange?() }
    }

    // MARK: - Change notices

    private func startWatching(_ tree: FolderTree, since: UInt64) {
        guard watchChanges, watchers[tree.id] == nil else { return }
        watchers[tree.id] = ChangeWatcher(path: tree.root, since: since, handler: Self.makeHandler(tree: tree, store: self))
    }

    private func stopWatching(_ tree: FolderTree) {
        watchers.removeValue(forKey: tree.id)?.stop()
    }

    /// Runs on ChangeWatcher.queue: does the disk reads there, then reports back on main.
    nonisolated private static func makeHandler(tree: FolderTree, store: SizeStore) -> (ChangeWatcher.Batch) -> Void {
        { [weak store] batch in
            if batch.rootChanged && !FileManager.default.fileExists(atPath: tree.root) {
                DispatchQueue.main.async { MainActor.assumeIsolated { store?.rootVanished(tree) } }
                return
            }
            var whole = batch.wholeSubtrees
            if batch.rootChanged { whole.append(tree.root) }
            let changed = tree.apply(changedFolders: batch.changedFolders, wholeSubtrees: whole)
            if batch.lastEventID > 0 { tree.noteEvents(upTo: batch.lastEventID) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store?.changesApplied(to: tree, changed: changed, historyDone: batch.historyDone) }
            }
        }
    }

    private func changesApplied(to tree: FolderTree, changed: Bool, historyDone: Bool) {
        guard trees.contains(where: { $0 === tree }) else { return }
        if historyDone && tree.history == .checking { tree.history = .upToDate }
        if changed {
            syncNested()
            scheduleSave()
        }
        if changed || historyDone { onChange?() }
    }

    private func rootVanished(_ tree: FolderTree) {
        stopWatching(tree)
        if FileManager.default.fileExists(atPath: tree.root) {
            startWatching(tree, since: ChangeWatcher.sinceNow)
        } else if Self.diskIsGone(for: tree.root) {
            // Disk unplugged: keep the sizes for when it comes back.
            tree.history = .unverified
            if tree.needsSave { save(tree) }
        } else {
            drop([tree])
        }
        onChange?()
    }

    // MARK: - Housekeeping

    /// A newer scan inside an older one: the older one takes over its current total.
    private func syncNested() {
        for (i, inner) in trees.enumerated() {
            guard let total = inner.size(of: inner.root) else { continue }
            for outer in trees[(i + 1)...] where outer.root != inner.root && PathUtil.isInside(inner.root, outer.root) {
                outer.replaceTotal(of: inner.root, with: total)
            }
        }
    }

    private func drop<S: Sequence>(_ dropped: S) where S.Element == FolderTree {
        let gone = Array(dropped)
        guard !gone.isEmpty else { return }
        trees.removeAll { tree in gone.contains { $0 === tree } }
        for tree in gone {
            stopWatching(tree)
            if let cache { Self.ioQueue.async { cache.delete(id: tree.id) } }
        }
    }

    private func trimToLimit() {
        if trees.count > Self.maxTrees { drop(trees[Self.maxTrees...]) }
    }

    private func save(_ tree: FolderTree) {
        guard let cache else { return }
        Self.ioQueue.async { try? cache.save(tree.snapshot(clearingDirty: true)) }
    }

    /// Saves changed trees half a minute after the first change, so the saved position in the
    /// change history keeps moving forward without writing on every notice.
    private func scheduleSave() {
        guard cache != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                for tree in self.trees where tree.isComplete && tree.needsSave { self.save(tree) }
            }
        }
    }

    private static func isOnInternalDisk(_ path: String) -> Bool {
        guard let volume = VolumeInfo.volumeURL(of: URL(fileURLWithPath: path)), let info = VolumeInfo.load(volume) else { return false }
        return !info.isExternal
    }

    /// True when `path` is on a disk under /Volumes that is no longer mounted.
    private static func diskIsGone(for path: String) -> Bool {
        let parts = path.split(separator: "/", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }
}

import Foundation

/// Every folder tree measured so far, newest first. Answers "how big is this folder?" with the
/// freshest measurement available, and keeps older, larger scans consistent when part of them is
/// rescanned or moved away.
@MainActor
final class SizeStore {
    private(set) var trees: [FolderTree] = []

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

    /// `path` is about to be rescanned: drop scans of folders inside it, and mark it out of date
    /// in scans that contain it.
    func invalidate(_ path: String) {
        trees.removeAll { PathUtil.isInside($0.root, path) }
        for tree in trees { tree.invalidate(path) }
    }

    /// `tree` finished: older scans that contain it take over its total (so their parent folders
    /// are corrected), and older scans inside it are replaced by it.
    func finished(_ tree: FolderTree, cancelled: Bool) {
        guard !cancelled, let index = trees.firstIndex(where: { $0 === tree }), let total = tree.size(of: tree.root) else { return }
        let older = trees[(index + 1)...]
        for other in older where other.root != tree.root && PathUtil.isInside(tree.root, other.root) {
            other.replaceTotal(of: tree.root, with: total)
        }
        let replaced = Set(older.filter { PathUtil.isInside($0.root, tree.root) }.map(ObjectIdentifier.init))
        trees.removeAll { replaced.contains(ObjectIdentifier($0)) }
    }

    /// The item at `path` (`size` bytes) was moved away or deleted.
    func removed(_ path: String, size: Int64) {
        trees.removeAll { PathUtil.isInside($0.root, path) }
        for tree in trees { tree.removeItem(at: path, size: size) }
    }
}

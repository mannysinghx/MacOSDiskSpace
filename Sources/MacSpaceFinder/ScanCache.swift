import Foundation

/// Saves finished folder trees between launches, one file per tree, in
/// ~/Library/Caches/local.macspacefinder/Scans (a folder only this user can read).
/// Unreadable or outdated files are deleted and simply measured again.
struct ScanCache {
    let directory: URL

    static let standard = ScanCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.macspacefinder/Scans", isDirectory: true))

    private static let magic: UInt32 = 0x5346_534D  // "MSFS"
    private static let version: UInt32 = 1

    private struct Meta: Codable {
        let id: UUID
        let root: String
        let scanDate: Date
        let eventID: UInt64
        let volumeUUID: String?
    }

    private struct Corrupt: Error {}

    func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".msfscan")
    }

    func save(_ s: FolderTree.Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var out: [UInt8] = []
        out.reserveCapacity(64 + s.nodes.count * 40)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        let meta = try JSONEncoder().encode(Meta(id: s.id, root: s.root, scanDate: s.scanDate, eventID: s.eventID, volumeUUID: s.volumeUUID))
        put(Self.magic)
        put(Self.version)
        put(UInt32(meta.count))
        out.append(contentsOf: meta)
        put(UInt32(s.nodes.count))
        for n in s.nodes {
            let name = Array(n.name.utf8)
            put(n.parent)
            put(n.own)
            put(n.total)
            put(UInt8((n.stale ? 1 : 0) | (n.staleBelow ? 2 : 0)))
            put(UInt16(min(name.count, Int(UInt16.max))))
            out.append(contentsOf: name.prefix(Int(UInt16.max)))
        }
        try Data(out).write(to: file(for: s.id), options: .atomic)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Every saved tree, newest first.
    func loadAll() -> [FolderTree] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var trees: [FolderTree] = []
        for url in files where url.pathExtension == "msfscan" {
            if let snapshot = try? load(url) {
                trees.append(FolderTree(snapshot: snapshot))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return trees.sorted { $0.scanDate > $1.scanDate }
    }

    func load(_ url: URL) throws -> FolderTree.Snapshot {
        let data = try Data(contentsOf: url)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> FolderTree.Snapshot in
            var offset = 0
            func get<T>(_: T.Type) throws -> T {
                guard offset + MemoryLayout<T>.size <= raw.count else { throw Corrupt() }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            func bytes(_ n: Int) throws -> UnsafeRawBufferPointer {
                guard n >= 0, offset + n <= raw.count else { throw Corrupt() }
                defer { offset += n }
                return UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n])
            }
            guard try get(UInt32.self) == Self.magic, try get(UInt32.self) == Self.version else { throw Corrupt() }
            let meta = try JSONDecoder().decode(Meta.self, from: Data(try bytes(Int(try get(UInt32.self)))))
            guard url.lastPathComponent == meta.id.uuidString + ".msfscan" else { throw Corrupt() }
            let count = Int(try get(UInt32.self))
            var nodes: [FolderTree.ExportedNode] = []
            nodes.reserveCapacity(count)
            for k in 0..<count {
                let parent = try get(Int32.self)
                let own = try get(Int64.self)
                let total = try get(Int64.self)
                let flags = try get(UInt8.self)
                let name = String(decoding: try bytes(Int(try get(UInt16.self))), as: UTF8.self)
                // Parents always come first; anything else means the file is damaged.
                guard (k == 0) == (parent < 0), parent < Int32(k) else { throw Corrupt() }
                nodes.append(.init(parent: parent, own: own, total: total, name: name,
                                   stale: flags & 1 != 0, staleBelow: flags & 2 != 0))
            }
            guard offset == raw.count, !nodes.isEmpty else { throw Corrupt() }
            return FolderTree.Snapshot(id: meta.id, root: meta.root, scanDate: meta.scanDate, eventID: meta.eventID,
                                       volumeUUID: meta.volumeUUID, nodes: nodes)
        }
    }
}

import Foundation

struct VolumeInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isRoot: Bool
    let isReadOnly: Bool
    let format: String

    var id: String { url.path }
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var isExternal: Bool { !isRoot && (!isInternal || isRemovable || isEjectable) }
    var canBeDestination: Bool { !isRoot && !isReadOnly }
    var symbol: String { isRoot ? "internaldrive.fill" : isExternal ? "externaldrive.fill" : "internaldrive" }

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    static func loadAll() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(load).sorted { a, b in
            a.isRoot != b.isRoot ? a.isRoot : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func load(_ url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
        // "Important usage" matches what Finder shows (it counts purgeable space as free); it is
        // only reported for some volumes, so fall back to the plain figure.
        var free = Int64(v.volumeAvailableCapacity ?? 0)
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { free = important }
        return VolumeInfo(
            url: url,
            name: v.volumeLocalizedName ?? url.lastPathComponent,
            total: Int64(total),
            free: free,
            isInternal: v.volumeIsInternal ?? false,
            isRemovable: v.volumeIsRemovable ?? false,
            isEjectable: v.volumeIsEjectable ?? false,
            isRoot: v.volumeIsRootFileSystem ?? false,
            isReadOnly: v.volumeIsReadOnly ?? false,
            format: v.volumeLocalizedFormatDescription ?? ""
        )
    }

    /// Free bytes on the volume that holds `url`.
    static func freeSpace(at url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v.volumeAvailableCapacity.map(Int64.init)
    }

    static func volumeURL(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }
}

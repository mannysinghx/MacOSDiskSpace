import CoreServices
import Foundation

/// Watches a folder with FSEvents. Notices are per folder ("something in this folder changed"),
/// which is exactly the granularity a size tree needs. Given a saved event id it first replays
/// every change since then — on the internal disk this works across app launches and reboots.
///
/// Verified on this Mac: replay after relaunch works on the internal APFS disk and paths come in
/// the /Users/... form the scanner uses. On exFAT, live notices arrive but there is no history.
final class ChangeWatcher {
    struct Batch {
        var changedFolders: [String] = []
        /// Too many changes to report one by one: measure these folders again in full.
        var wholeSubtrees: [String] = []
        /// The watched folder itself was moved, deleted or created.
        var rootChanged = false
        /// The replay of past changes is complete (only when started from a saved id).
        var historyDone = false
        var lastEventID: UInt64 = 0
    }

    /// All watchers deliver here, one batch at a time, so tree updates never overlap.
    static let queue = DispatchQueue(label: "MacSpaceFinder.changes", qos: .utility)
    static let sinceNow = UInt64(kFSEventStreamEventIdSinceNow)

    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the change history of the disk holding `path`; nil when it has none.
    static func volumeUUID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private var stream: FSEventStreamRef?
    private var stopped = false
    private let handler: (Batch) -> Void

    /// `handler` runs on `ChangeWatcher.queue`.
    init?(path: String, since: UInt64, handler: @escaping (Batch) -> Void) {
        self.handler = handler
        // The stream keeps the watcher alive (retain/release below) until `stop()` releases it.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: watcherRetain, release: watcherRelease, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, eventCallback, &context, [path] as CFArray, since, 1.0, flags) else { return nil }
        FSEventStreamSetDispatchQueue(s, Self.queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return nil
        }
        stream = s
    }

    func stop() {
        Self.queue.async { [self] in
            guard !stopped, let s = stream else { return }
            stopped = true
            stream = nil
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    fileprivate func deliver(count: Int, paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        guard !stopped else { return }
        var batch = Batch()
        for i in 0..<min(count, paths.count) {
            let f = Int(flags[i])
            if f & kFSEventStreamEventFlagHistoryDone != 0 { batch.historyDone = true; continue }
            if f & kFSEventStreamEventFlagRootChanged != 0 { batch.rootChanged = true; continue }
            if f & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { continue }
            var path = paths[i]
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                batch.wholeSubtrees.append(path)
            } else {
                batch.changedFolders.append(path)
            }
            batch.lastEventID = max(batch.lastEventID, ids[i])
        }
        handler(batch)
    }
}

private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info else { return }
    let watcher = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    watcher.deliver(count: count, paths: list, flags: flags, ids: ids)
}

private let watcherRetain: CFAllocatorRetainCallBack = { info in
    guard let info else { return nil }
    _ = Unmanaged<ChangeWatcher>.fromOpaque(info).retain()
    return info
}

private let watcherRelease: CFAllocatorReleaseCallBack = { info in
    guard let info else { return }
    Unmanaged<ChangeWatcher>.fromOpaque(info).release()
}

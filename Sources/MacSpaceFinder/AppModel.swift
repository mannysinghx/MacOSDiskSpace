import AppKit
import Observation
import SwiftUI

struct Entry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    var size: Int64?

    var id: String { url.path }
    var sortSize: Int64 { size ?? -1 }
    var symbol: String {
        isSymlink ? "arrowshape.turn.up.right" : isPackage ? "shippingbox.fill" : isDirectory ? "folder.fill" : "doc"
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case browse = "Folder Contents"
    case biggest = "Biggest Folders"
    var id: Self { self }
}

struct TransferRequest: Identifiable {
    let id = UUID()
    let items: [URL]
    let knownSize: Int64
    let mode: TransferMode
}

enum TransferPhase {
    case setup
    case running(TransferProgress)
    case finished(results: [TransferItemResult], fatal: String?)
}

@MainActor @Observable
final class AppModel {
    var volumes: [VolumeInfo] = []
    var sidebarSelection: String?
    var currentURL = URL(fileURLWithPath: PathUtil.home, isDirectory: true)
    var entries: [Entry] = []
    var listError: String?
    var mode: ViewMode = .browse
    var selection: Set<String> = []
    var sortOrder = [KeyPathComparator(\Entry.sortSize, order: .reverse)]

    // Scanning
    var isScanning = false
    var scanRoot: URL?
    var scanFiles = 0
    var scanBytes: Int64 = 0
    var scanCurrent = ""
    var scanErrors = 0
    var biggest: [BigFolder] = []
    var biggestRoot: URL?

    // Transfer
    var transferRequest: TransferRequest?
    var transferPhase: TransferPhase = .setup

    /// Allocated size of every folder measured so far, keyed by canonical path.
    @ObservationIgnored private var sizes: [String: Int64] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID = 0
    @ObservationIgnored private var transferEngine: TransferEngine?
    @ObservationIgnored private var started = false

    var sortedEntries: [Entry] { entries.sorted(using: sortOrder) }

    var currentTotal: Int64? {
        sizes[currentURL.path] ?? (isScanning ? nil : entries.reduce(0) { $0 + ($1.size ?? 0) })
    }

    var selectionSize: Int64 {
        selection.reduce(0) { total, id in total + (size(of: id) ?? 0) }
    }

    func size(of path: String) -> Int64? {
        sizes[path] ?? entries.first { $0.id == path }?.size
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
        // `-StartPath /some/folder` on the command line opens that folder instead of Home.
        let start = UserDefaults.standard.string(forKey: "StartPath") ?? PathUtil.home
        sidebarSelection = start == PathUtil.home ? PathUtil.home : nil
        navigate(to: URL(fileURLWithPath: start, isDirectory: true))
    }

    func refreshVolumes() {
        volumes = VolumeInfo.loadAll()
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        currentURL = PathUtil.canonicalDirectory(url)
        selection = []
        loadEntries()
        if needsScan(currentURL) { startScan(root: currentURL) }
    }

    func goUp() {
        guard currentURL.path != "/" else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
           (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
            mode = .browse
            navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealInFinder(_ paths: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Show Sizes"
        panel.directoryURL = currentURL
        if panel.runModal() == .OK, let url = panel.url {
            sidebarSelection = nil
            mode = .browse
            navigate(to: url)
        }
    }

    private func loadEntries() {
        listError = nil
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: keys, options: [])
            entries = urls.map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isSymlink = v?.isSymbolicLink == true
                let isDir = v?.isDirectory == true && !isSymlink
                let fileSize = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                return Entry(url: url, name: url.lastPathComponent, isDirectory: isDir, isPackage: v?.isPackage == true,
                             isSymlink: isSymlink, size: isDir ? sizes[url.path] : fileSize)
            }
        } catch {
            entries = []
            listError = "Can't open this folder: \(error.localizedDescription)\n\nIf it is a protected folder, give Mac Space Finder Full Disk Access in System Settings › Privacy & Security."
        }
    }

    private func refreshEntrySizes() {
        for i in entries.indices where entries[i].isDirectory {
            let s = sizes[entries[i].id]
            if entries[i].size != s { entries[i].size = s }
        }
    }

    // MARK: - Scanning

    private func needsScan(_ url: URL) -> Bool {
        if sizes[url.path] != nil { return false }
        if isScanning, let root = scanRoot, PathUtil.isInside(url.path, root.path) { return false }
        return true
    }

    func rescan() {
        let root = currentURL.path
        sizes = sizes.filter { !PathUtil.isInside($0.key, root) }
        loadEntries()
        startScan(root: currentURL)
    }

    func findBiggest() {
        mode = .biggest
        selection = []
        if biggestRoot?.path == currentURL.path { return }
        if isScanning, scanRoot?.path == currentURL.path { return }
        startScan(root: currentURL)
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func startScan(root: URL) {
        scanTask?.cancel()
        scanID += 1
        let id = scanID
        isScanning = true
        scanRoot = root
        scanFiles = 0
        scanBytes = 0
        scanErrors = 0
        scanCurrent = root.path
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = FolderScanner.scan(root: root) { progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyScanProgress(progress, id: id) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishScan(result, id: id) } }
        }
    }

    private func applyScanProgress(_ p: ScanProgress, id: Int) {
        guard id == scanID else { return }
        sizes.merge(p.newSizes) { _, new in new }
        scanFiles = p.files
        scanBytes = p.bytes
        scanErrors = p.errors
        scanCurrent = p.currentPath
        refreshEntrySizes()
    }

    private func finishScan(_ r: ScanResult, id: Int) {
        sizes.merge(r.newSizes) { _, new in new }
        refreshEntrySizes()
        guard id == scanID else { return }
        isScanning = false
        scanFiles = r.files
        scanBytes = r.bytes
        scanErrors = r.errors
        if !r.cancelled {
            biggest = r.biggest
            biggestRoot = r.root
        }
    }

    // MARK: - Transfers

    func beginTransfer(_ mode: TransferMode, paths: Set<String>? = nil) {
        let chosen = paths ?? selection
        guard !chosen.isEmpty else { return }
        if let paths { selection = paths }
        // A folder and one of its subfolders both selected: the subfolder travels with its parent.
        let items = chosen.filter { path in !chosen.contains { $0 != path && PathUtil.isInside(path, $0) } }
            .sorted().map { URL(fileURLWithPath: $0) }
        let known = items.reduce(Int64(0)) { $0 + (size(of: $1.path) ?? 0) }
        transferPhase = .setup
        transferRequest = TransferRequest(items: items, knownSize: known, mode: mode)
    }

    func startTransfer(items: [URL], options: TransferOptions) {
        transferPhase = .running(TransferProgress(itemCount: items.count))
        let engine = TransferEngine { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .running = self.transferPhase else { return }
                    self.transferPhase = .running(progress)
                }
            }
        }
        transferEngine = engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = engine.run(items: items, options: options)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTransfer(outcome.results, fatal: outcome.fatal) }
            }
        }
    }

    func cancelTransfer() {
        transferEngine?.cancel()
    }

    private func finishTransfer(_ results: [TransferItemResult], fatal: String?) {
        transferEngine = nil
        transferPhase = .finished(results: results, fatal: fatal)
        // Originals that were moved away no longer take space here: drop them from the
        // measurements and shrink every folder that contained them.
        for r in results where r.originalRemoved {
            let path = r.source.path
            let removed = size(of: path) ?? 0
            sizes = sizes.filter { !PathUtil.isInside($0.key, path) }
            var parent = (path as NSString).deletingLastPathComponent
            while true {
                if let s = sizes[parent] { sizes[parent] = max(0, s - removed) }
                if parent == "/" || parent.isEmpty { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            biggest.removeAll { PathUtil.isInside($0.path, path) }
            for i in biggest.indices where PathUtil.isInside(path, biggest[i].path) {
                biggest[i].size = max(0, biggest[i].size - removed)
            }
        }
        biggest.sort { $0.size > $1.size }
        selection = []
        loadEntries()
        refreshVolumes()
    }

    func closeTransfer() {
        if case .running = transferPhase { return }
        transferRequest = nil
        transferPhase = .setup
    }
}

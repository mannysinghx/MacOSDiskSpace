import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .sheet(item: $model.transferRequest) { request in
            TransferSheet(request: request)
                .environment(model)
                .interactiveDismissDisabled()
        }
        .onAppear { model.start() }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<String?>(
            get: { model.sidebarSelection },
            set: { path in
                model.sidebarSelection = path
                if let path {
                    model.mode = .browse
                    model.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
                }
            }
        )
        List(selection: selection) {
            Section("Disks") {
                ForEach(model.volumes) { volume in
                    VolumeRow(volume: volume).tag(volume.url.path)
                }
            }
            Section("Places") {
                Label("Home", systemImage: "house").tag(PathUtil.home)
                Label("Downloads", systemImage: "arrow.down.circle").tag(PathUtil.home + "/Downloads")
                Label("Documents", systemImage: "doc.text").tag(PathUtil.home + "/Documents")
                Label("Applications", systemImage: "square.grid.2x2").tag("/Applications")
                Label("User Library", systemImage: "building.columns").tag(PathUtil.home + "/Library")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button {
                    model.refreshVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh disk list")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(volume.name, systemImage: volume.symbol)
                .fontWeight(.medium)
            ProgressView(value: volume.usedFraction)
                .tint(volume.usedFraction > 0.9 ? .red : volume.usedFraction > 0.75 ? .orange : .accentColor)
            Text("\(Fmt.bytes(volume.free)) free of \(Fmt.bytes(volume.total))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .help("\(volume.url.path) · \(volume.format) · \(Fmt.bytes(volume.used)) used")
    }
}

// MARK: - Detail

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $model.mode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(PathUtil.abbreviate(model.currentURL.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if let total = model.currentTotal {
                    Text("Total: \(Fmt.bytes(total))").fontWeight(.semibold).monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Group {
                switch model.mode {
                case .browse: BrowseTable()
                case .biggest: BiggestTable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ScanStatusBar()
            ActionBar()
        }
        .navigationTitle(model.currentURL.path == "/" ? "Macintosh HD" : model.currentURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.goUp() } label: { Label("Up", systemImage: "chevron.up") }
                    .help("Go to the enclosing folder")
                    .disabled(model.currentURL.path == "/")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Measure this folder again")
                Button { model.findBiggest() } label: {
                    Label("Find Biggest Folders", systemImage: "chart.bar.xaxis")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Scan this folder and list the folders using the most space")
            }
        }
    }
}

private struct SizeBar: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.gradient)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 7)
            Text(Fmt.percent(fraction))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

private struct BrowseTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let total = max(model.currentTotal ?? model.entries.reduce(0) { $0 + ($1.size ?? 0) }, 1)
        if let error = model.listError {
            ContentUnavailableView("Can't Read Folder", systemImage: "lock.fill", description: Text(error))
        } else if model.entries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            Table(model.sortedEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("Name", value: \.name) { e in
                    Label {
                        Text(e.name).lineLimit(1)
                    } icon: {
                        Image(systemName: e.symbol).foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                    }
                }
                TableColumn("Size", value: \.sortSize) { e in
                    Text(e.size.map(Fmt.bytes) ?? (model.isScanning ? "…" : "—"))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Share of Folder") { e in
                    SizeBar(fraction: Double(e.size ?? 0) / Double(total))
                }
                .width(min: 120, ideal: 180)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                ItemMenu(ids: ids)
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.open(id) }
            }
        }
    }
}

private struct BiggestTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let root = model.biggestRoot, root.path != model.currentURL.path, !model.biggest.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Showing results for \(PathUtil.abbreviate(root.path)).")
                    Button("Scan \(model.currentURL.lastPathComponent.isEmpty ? "/" : model.currentURL.lastPathComponent) Instead") {
                        model.findBiggest()
                    }
                    .buttonStyle(.link)
                    Spacer()
                }
                .font(.callout)
                .padding(8)
                .background(.yellow.opacity(0.12))
            }
            if model.biggest.isEmpty {
                if model.isScanning {
                    ContentUnavailableView {
                        Label("Scanning…", systemImage: "magnifyingglass")
                    } description: {
                        Text("The biggest folders will be listed when the scan finishes.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Find the Biggest Folders", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Scans \(PathUtil.abbreviate(model.currentURL.path)) and every folder inside it.")
                    } actions: {
                        Button("Find Biggest Folders") { model.findBiggest() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                let maxSize = max(model.biggest.first?.size ?? 1, 1)
                Table(model.biggest, selection: $model.selection) {
                    TableColumn("Folder") { b in
                        Label(b.name, systemImage: "folder.fill").lineLimit(1)
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn("Size") { b in
                        Text(Fmt.bytes(b.size))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 90, max: 120)
                    TableColumn("") { b in
                        SizeBar(fraction: Double(b.size) / Double(maxSize))
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("Location") { b in
                        Text(PathUtil.abbreviate(b.parent))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 320)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    ItemMenu(ids: ids)
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { model.open(id) }
                }
                Text("Folders are left out when one of their subfolders holds most of their space — that subfolder is listed instead. Double-click a folder to open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }
}

private struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<String>

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Open") { model.open(id) }
        }
        Button("Reveal in Finder") { model.revealInFinder(ids) }
        Divider()
        Button("Copy to External Disk…") { model.beginTransfer(.copy, paths: ids) }
        Button("Move to External Disk…") { model.beginTransfer(.move, paths: ids) }
        Button("Migrate to External Disk (leave link)…") { model.beginTransfer(.migrate, paths: ids) }
    }
}

private struct ScanStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning \(model.scanFiles.formatted()) files · \(Fmt.bytes(model.scanBytes))")
                    .monospacedDigit()
                Text(PathUtil.abbreviate(model.scanCurrent))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Stop") { model.cancelScan() }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        } else if model.scanErrors > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(model.scanErrors) item(s) couldn't be read, so sizes may be lower than actual.")
                Button("Grant Full Disk Access…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        } else if let note = model.rememberedNote {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(note.offerRescan ? .orange : .secondary)
                Text(note.text).foregroundStyle(.secondary)
                if note.offerRescan {
                    Button("Rescan") { model.rescan() }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

private struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.selection.isEmpty {
                Text("Select folders or files to copy, move or migrate them to another disk.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.selection.count) selected · \(Fmt.bytes(model.selectionSize))")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            Spacer()
            Group {
                Button { model.revealInFinder(model.selection) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                Button { model.beginTransfer(.copy) } label: { Label("Copy To…", systemImage: "doc.on.doc") }
                Button { model.beginTransfer(.move) } label: { Label("Move To…", systemImage: "arrow.right.doc.on.clipboard") }
                Button { model.beginTransfer(.migrate) } label: { Label("Migrate…", systemImage: "externaldrive.badge.plus") }
                    .help("Move to another disk and leave a link behind so apps still find the files")
            }
            .disabled(model.selection.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

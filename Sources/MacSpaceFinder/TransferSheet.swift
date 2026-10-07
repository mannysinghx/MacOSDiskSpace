import AppKit
import SwiftUI

struct TransferSheet: View {
    @Environment(AppModel.self) private var model
    let request: TransferRequest

    var body: some View {
        Group {
            switch model.transferPhase {
            case .setup:
                TransferSetupView(request: request)
            case .running(let progress):
                TransferRunningView(progress: progress)
            case .finished(let results, let fatal):
                TransferFinishedView(results: results, fatal: fatal)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Setup

private struct TransferSetupView: View {
    @Environment(AppModel.self) private var model
    let request: TransferRequest

    @State private var mode: TransferMode
    @State private var destination: URL?
    @State private var deletePermanently = false
    @State private var confirmPermanent = false

    init(request: TransferRequest) {
        self.request = request
        _mode = State(initialValue: request.mode)
    }

    private var destinations: [VolumeInfo] { model.volumes.filter(\.canBeDestination) }

    private var destinationVolume: VolumeInfo? {
        guard let destination, let vol = VolumeInfo.volumeURL(of: destination) else { return nil }
        return VolumeInfo.load(vol)
    }

    private var problems: [String] {
        var list: [String] = []
        if let destination {
            for item in request.items where PathUtil.isInside(destination.path, item.path) {
                list.append("The destination is inside \(item.lastPathComponent).")
            }
        }
        if mode != .copy {
            for item in request.items {
                if let reason = PathUtil.moveBlockReason(item.path) { list.append("\(item.lastPathComponent) can't be moved: \(reason).") }
            }
        }
        return list
    }

    private var warnings: [String] {
        var list: [String] = []
        guard let destination, let vol = destinationVolume else { return list }
        if request.knownSize > 0, vol.free < request.knownSize {
            list.append("The destination has only \(Fmt.bytes(vol.free)) free; about \(Fmt.bytes(request.knownSize)) is needed.")
        }
        let format = vol.format.lowercased()
        if format.contains("ms-dos") || format.contains("fat32") {
            list.append("\(vol.name) is FAT32: files larger than 4 GB can't be stored on it.")
        }
        if mode != .copy, request.items.contains(where: { $0.path.contains("/Library/Mobile Documents/") || $0.path.contains("/Library/CloudStorage/") }) {
            list.append("Some items are in iCloud Drive or another cloud folder. Moving them removes them from the cloud on all your devices.")
        }
        if mode != .copy, let src = request.items.first, VolumeInfo.volumeURL(of: src) == VolumeInfo.volumeURL(of: destination) {
            list.append("The destination is on the same disk, so moving won't free any space.")
        }
        return list
    }

    private var canStart: Bool { destination != nil && problems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(mode.rawValue) \(request.items.count == 1 ? request.items[0].lastPathComponent : "\(request.items.count) items")")
                    .font(.title2.bold())
                    .lineLimit(1)
                Spacer()
                if request.knownSize > 0 {
                    Text(Fmt.bytes(request.knownSize)).font(.title3).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if request.items.count > 1 {
                Text(request.items.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (request.items.count > 4 ? " and \(request.items.count - 4) more" : ""))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }

            Picker("Action", selection: $mode) {
                ForEach(TransferMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(mode.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Destination") {
                VStack(alignment: .leading, spacing: 6) {
                    if destinations.isEmpty {
                        Text("No external disk is connected. Plug one in, or choose a folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(destinations) { vol in
                        let selected = destination?.path == vol.url.path
                        Button {
                            destination = vol.url
                        } label: {
                            HStack {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                Label(vol.name, systemImage: vol.symbol)
                                Text(vol.format).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Fmt.bytes(vol.free)) free").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    HStack {
                        if let destination {
                            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                            Text(destination.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        } else {
                            Text("Pick a disk above, or a specific folder:").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose Folder…") { chooseFolder() }
                    }
                }
                .padding(4)
            }

            if mode != .copy {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Delete originals permanently (instead of moving them to the Trash)", isOn: $deletePermanently)
                    Text(deletePermanently
                         ? "Space is freed immediately. Originals are deleted only after every file is verified on the destination."
                         : "Safer: originals go to the Trash after the copy is verified. Empty the Trash to actually free the space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.closeTransfer() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.rawValue) {
                    if mode != .copy && deletePermanently { confirmPermanent = true } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .onAppear {
            if destination == nil { destination = destinations.first(where: \.isExternal)?.url ?? destinations.first?.url }
        }
        .confirmationDialog("Permanently delete the originals?", isPresented: $confirmPermanent) {
            Button("\(mode.rawValue) and Delete Originals", role: .destructive) { start() }
        } message: {
            Text("After each item is copied and verified on the destination, the original is deleted from this Mac. This can't be undone.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Destination"
        panel.directoryURL = destination ?? URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    private func start() {
        guard let destination else { return }
        model.startTransfer(items: request.items, options: TransferOptions(mode: mode, destination: destination, deletePermanently: deletePermanently))
    }
}

// MARK: - Running

private struct TransferRunningView: View {
    @Environment(AppModel.self) private var model
    let progress: TransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.phase).font(.title3.bold()).lineLimit(1)
            if progress.totalBytes > 0 {
                ProgressView(value: Double(progress.doneBytes), total: Double(max(progress.totalBytes, 1)))
                HStack {
                    Text("\(Fmt.bytes(progress.doneBytes)) of \(Fmt.bytes(progress.totalBytes))").monospacedDigit()
                    Spacer()
                    if progress.itemCount > 1 { Text("Item \(progress.itemIndex) of \(progress.itemCount)") }
                }
                .font(.callout)
            } else {
                ProgressView()
            }
            Text(PathUtil.abbreviate(progress.currentFile))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelTransfer() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Finished

private struct TransferFinishedView: View {
    @Environment(AppModel.self) private var model
    let results: [TransferItemResult]
    let fatal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fatal {
                Label("Nothing was transferred", systemImage: "xmark.octagon.fill").font(.title3.bold()).foregroundStyle(.red)
                Text(fatal).fixedSize(horizontal: false, vertical: true)
            } else {
                let ok = results.filter(\.succeeded).count
                Label(ok == results.count ? "Finished" : "Finished with problems",
                      systemImage: ok == results.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(ok == results.count ? .green : .orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(results) { r in ResultRow(result: r) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            HStack {
                if let dst = results.compactMap(\.destination).first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dst]) }
                }
                Spacer()
                Button("Done") { model.closeTransfer() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ResultRow: View {
    let result: TransferItemResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? .green : .orange)
                Text(result.source.lastPathComponent).fontWeight(.medium)
                Text("— \(result.status)").foregroundStyle(.secondary)
            }
            if let dst = result.destination {
                Text("→ \(dst.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !result.errors.isEmpty {
                DisclosureGroup("\(result.errors.count) problem(s)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.errors.prefix(50).enumerated()), id: \.offset) { _, e in
                            Text(e).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if result.errors.count > 50 {
                            Text("…and \(result.errors.count - 50) more").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }
}

import KveikurCore
import SwiftUI

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published private(set) var albums: [DuplicateGroup] = []
    @Published private(set) var tracks: [DuplicateGroup] = []
    @Published private(set) var loading = false

    let app: AppModel
    var onShow: ((URL) -> Void)?
    var onTrash: (([URL], @escaping ([URL]) -> Void) -> Void)?

    init(app: AppModel) {
        self.app = app
    }

    func load() {
        guard !loading else { return }
        loading = true
        let library = app.library
        Task {
            let groups = await Task.detached(priority: .userInitiated) { DuplicateFinder.find(library.allTracks()) }.value
            albums = groups.filter { $0.kind == .album }
            tracks = groups.filter { $0.kind == .track }
            loading = false
        }
    }

    func trash(_ v: DuplicateVersion) {
        onTrash?([v.url]) { [weak self] moved in
            guard let self, !moved.isEmpty else { return }
            let gone = Set(moved.map(\.path))
            func prune(_ gs: [DuplicateGroup]) -> [DuplicateGroup] {
                gs.compactMap { g in
                    var g = g
                    g.versions.removeAll { gone.contains($0.path) }
                    return g.versions.count > 1 ? g : nil
                }
            }
            albums = prune(albums)
            tracks = prune(tracks)
        }
    }

    func relative(_ path: String) -> String {
        guard let root = app.root(containing: URL(fileURLWithPath: path)) else { return path }
        return root.lastPathComponent + path.dropFirst(root.path.count)
    }

    var reclaimable: Int64 { albums.reduce(0) { $0 + $1.reclaimable } }
}

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @State private var showTracks = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.loading && model.albums.isEmpty {
                ProgressView("Comparing \(model.app.library.trackCount()) tracks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.albums.isEmpty && model.tracks.isEmpty {
                Text("No duplicates found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.albums) { group($0) }
                    if !model.tracks.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showTracks) {
                                ForEach(model.tracks) { group($0) }
                            } label: {
                                Text("Same track in different folders (\(model.tracks.count))").font(.system(size: 12, weight: .semibold))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: Theme.inspectorBackground))
        .environment(\.colorScheme, .dark)
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.albums.count) albums stored more than once").font(.headline)
                Text("★ marks the copy to keep: lossless first, then bit depth and sample rate, then the most complete edition. Other copies take \(Format.bytes(model.reclaimable)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { model.load() }.disabled(model.loading)
        }
        .padding(14)
    }

    private func group(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let a = g.artist { Text(a).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text(Format.bytes(g.reclaimable)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(g.versions) { version($0, kind: g.kind) }
        }
        .padding(.vertical, 4)
    }

    private func version(_ v: DuplicateVersion, kind: DuplicateGroup.Kind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: v.isBest ? "star.fill" : "circle")
                .font(.system(size: v.isBest ? 10 : 6))
                .foregroundStyle(v.isBest ? Color(nsColor: Theme.nord13) : .secondary)
                .frame(width: 14)
            let rel = model.relative(v.path) as NSString
            Text(rel.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(v.isBest ? .primary : .secondary)
                .layoutPriority(1)
            Text(rel.deletingLastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.head)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Group {
                if kind == .album { Text("\(v.tracks.count) tr").frame(width: 44, alignment: .trailing) }
                Text(quality(v)).frame(width: 118, alignment: .leading)
                Text(Format.bytes(v.bytes)).frame(width: 76, alignment: .trailing)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.onShow?(v.url) }
        .contextMenu {
            Button("Show in Kveikur") { model.onShow?(v.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CueTrackRef.audioFile(v.url)]) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.trash(v) }
                .disabled(CueTrackRef.isCue(v.url) || CueFolders.isSheet(v.url))
        }
    }

    private func quality(_ v: DuplicateVersion) -> String {
        guard let f = v.format else { return "" }
        return !f.lossless && v.bitrate > 0 ? "\(f.shortLabel) \(v.bitrate)k" : f.shortLabel
    }
}

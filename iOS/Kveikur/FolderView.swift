import KveikurCore
import SwiftUI

struct FolderView: View {
    let folder: URL
    @EnvironmentObject var model: MobileModel
    @EnvironmentObject var player: PlayerController
    @State private var items: [FolderItem]?
    @State private var filter = ""

    private var shown: [FolderItem] {
        guard let items else { return [] }
        guard !filter.isEmpty else { return items }
        return items.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            ForEach(shown) { item in
                if item.isFolder {
                    NavigationLink(value: item.url) {
                        Label(item.name, systemImage: "folder.fill")
                            .foregroundStyle(Nord.folder)
                            .lineLimit(2)
                    }
                    .listRowBackground(Nord.background)
                    .contextMenu { folderMenu(item.url) }
                    .swipeActions(edge: .leading) { queueButtons(item) }
                } else {
                    TrackRow(item: item, playing: player.currentURL == item.url)
                        .contentShape(Rectangle())
                        .onTapGesture { model.play(shown, from: item) }
                        .listRowBackground(player.currentURL == item.url ? Nord.raised : Nord.background)
                        .swipeActions(edge: .leading) { queueButtons(item) }
                }
            }
        }
        .listStyle(.plain)
        .nordList()
        .overlay {
            if items == nil {
                ProgressView()
            } else if items?.isEmpty == true {
                ContentUnavailableView("Empty folder", systemImage: "music.note.list",
                                       description: Text("No folders or audio files here."))
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic))
        .navigationTitle(folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { folderMenu(folder) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: folder) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let f = folder
        items = await Task.detached { MobileModel.list(f) }.value
    }

    @ViewBuilder
    private func folderMenu(_ url: URL) -> some View {
        Button { model.playFolder(url, shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
        Button { model.playFolder(url, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
        Button { model.enqueue(FolderItem(url: url, isFolder: true), next: true) } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { model.enqueue(FolderItem(url: url, isFolder: true), next: false) } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    @ViewBuilder
    private func queueButtons(_ item: FolderItem) -> some View {
        Button { model.enqueue(item, next: true) } label: { Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            .tint(Nord.n10)
        Button { model.enqueue(item, next: false) } label: { Label("Queue", systemImage: "text.append") }
            .tint(Nord.n15)
    }
}

struct TrackRow: View {
    let item: FolderItem
    let playing: Bool
    @EnvironmentObject var model: MobileModel
    @State private var meta: TrackMetadata?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playing ? "speaker.wave.2.fill" : (item.inCloud ? "icloud.and.arrow.down" : "music.note"))
                .foregroundStyle(playing ? Nord.playing : Nord.n7)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(playing ? Nord.playing : Nord.text)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(Nord.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let d = meta?.duration, d > 0 {
                Text(Format.duration(d)).font(.caption.monospacedDigit()).foregroundStyle(Nord.secondary)
            }
        }
        .task(id: item.url) {
            meta = model.metadata.cached(item.url.path)
            if meta == nil, !item.inCloud { meta = await model.metadata.metadata(for: item.url) }
        }
    }

    private var title: String {
        guard let t = meta?.title else { return item.name }
        return meta?.trackNumber.map { "\($0). \(t)" } ?? t
    }

    private var subtitle: String? {
        guard let m = meta else { return nil }
        let parts = [m.artist, m.format?.shortLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

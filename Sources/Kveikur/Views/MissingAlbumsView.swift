import KveikurCore
import SwiftUI

@MainActor
final class MissingAlbumsModel: ObservableObject {
    struct Gap: Identifiable {
        var id: String { local.folder }
        var local: LocalArtist
        var discography: ArtistDiscography
        var missing: [StudioAlbum]
        var owned: Int { discography.albums.count - missing.count }
    }

    @Published private(set) var gaps: [Gap] = []
    @Published private(set) var unknown: [LocalArtist] = []
    @Published private(set) var progress: (done: Int, total: Int, name: String)?
    /// Artists MusicBrainz didn't answer for this time; they aren't cached, so the next check retries them.
    @Published private(set) var skipped = 0

    let app: AppModel
    var onShow: ((URL) -> Void)?
    private let musicBrainz = MusicBrainz()
    private var task: Task<Void, Never>?
    private var results: [(LocalArtist, ArtistDiscography)] = []

    private var ignoredAlbums: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "missingIgnoredAlbums") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "missingIgnoredAlbums") }
    }
    private var ignoredArtists: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "missingIgnoredArtists") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "missingIgnoredArtists") }
    }

    init(app: AppModel) {
        self.app = app
    }

    var missingCount: Int { gaps.reduce(0) { $0 + $1.missing.count } }

    func load(refresh: Bool = false) {
        guard task == nil else { return }
        skipped = 0
        let library = app.library, roots = app.roots
        task = Task {
            let artists = await Task.detached(priority: .userInitiated) {
                Discography.localArtists(library.allTracks(), roots: roots)
            }.value
            results = []
            rebuild()
            let ignored = ignoredArtists
            let todo = artists.filter { !ignored.contains(($0.folder as NSString).lastPathComponent) }
            for (i, a) in todo.enumerated() {
                if Task.isCancelled { break }
                progress = (i, todo.count, a.name)
                do {
                    results.append((a, try await musicBrainz.discography(for: a, refresh: refresh)))
                    rebuild()
                } catch {
                    skipped += 1
                }
            }
            progress = nil
            task = nil
        }
    }

    func ignore(_ album: StudioAlbum) {
        ignoredAlbums.insert(album.id)
        rebuild()
    }

    func ignore(_ gap: Gap) {
        ignoredArtists.insert((gap.local.folder as NSString).lastPathComponent)
        results.removeAll { $0.0.folder == gap.local.folder }
        rebuild()
    }

    private func rebuild() {
        let skip = ignoredAlbums
        gaps = results.compactMap { local, d in
            let missing = d.albums.filter { !local.owns($0) && !skip.contains($0.id) }
            return missing.isEmpty ? nil : Gap(local: local, discography: d, missing: missing)
        }
        unknown = results.filter { $0.1.mbid == nil }.map(\.0)
    }
}

struct MissingAlbumsView: View {
    @ObservedObject var model: MissingAlbumsModel
    @State private var showUnknown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.gaps.isEmpty && model.unknown.isEmpty {
                Group {
                    if let p = model.progress {
                        ProgressView("Checking \(p.name)…", value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 320)
                    } else {
                        Text(model.skipped > 0 ? "MusicBrainz didn't answer. Try again later." : "Every studio album is here.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.gaps) { artist($0) }
                    if !model.unknown.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showUnknown) {
                                ForEach(model.unknown, id: \.folder) { a in
                                    Text(a.name).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { model.onShow?(URL(fileURLWithPath: a.folder)) }
                                }
                            } label: {
                                Text("Not found on MusicBrainz (\(model.unknown.count))").font(.system(size: 12, weight: .semibold))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: Theme.inspectorBackground))
        .environment(\.colorScheme, .dark)
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.missingCount) studio albums missing").font(.headline)
                Text("Studio albums from MusicBrainz, without live albums, compilations, soundtracks or EPs. The OST folder is skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.skipped > 0, model.progress == nil {
                    Text("MusicBrainz was busy for \(model.skipped) artists; open this window again later to check them.")
                        .font(.caption).foregroundStyle(Color(nsColor: Theme.nord13))
                }
            }
            Spacer()
            if let p = model.progress {
                Text("\(p.done)/\(p.total)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { model.load(refresh: true) }.disabled(model.progress != nil)
        }
        .padding(14)
    }

    private func artist(_ g: MissingAlbumsModel.Gap) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.local.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(g.owned) of \(g.discography.albums.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.onShow?(URL(fileURLWithPath: g.local.folder)) }
            .contextMenu {
                Button("Show in Kveikur") { model.onShow?(URL(fileURLWithPath: g.local.folder)) }
                if let u = g.discography.url { Button("Open in MusicBrainz") { NSWorkspace.shared.open(u) } }
                Divider()
                Button("Ignore Artist") { model.ignore(g) }
            }
            ForEach(g.missing) { album($0, artist: g.local.name) }
        }
        .padding(.vertical, 4)
    }

    private func album(_ a: StudioAlbum, artist: String) -> some View {
        HStack(spacing: 10) {
            Text(a.year ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
            Text(a.title).font(.system(size: 12)).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(a.url) }
        .contextMenu {
            Button("Open in MusicBrainz") { NSWorkspace.shared.open(a.url) }
            Button("Copy “\(artist) – \(a.title)”") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(artist) – \(a.title)", forType: .string)
            }
            Divider()
            Button("Ignore Album") { model.ignore(a) }
        }
    }
}

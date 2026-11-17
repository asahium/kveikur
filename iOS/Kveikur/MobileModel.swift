import KveikurCore
import SwiftUI
import UIKit

/// A folder the app may read: the app's own Documents ("On My iPhone") or one picked in Files.
struct LibraryRoot: Identifiable, Hashable {
    var url: URL
    var name: String
    var bookmark: Data?

    var id: String { url.path }
    var isLocal: Bool { bookmark == nil }
}

struct FolderItem: Identifiable, Hashable {
    var url: URL
    var isFolder: Bool
    var inCloud = false

    var id: String { url.path }
    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class MobileModel: ObservableObject {
    let library: LibraryStore
    let metadata: MetadataStore
    let player: PlayerController
    let lyrics = LyricsService()
    let scrobbler: ScrobbleController

    @Published private(set) var roots: [LibraryRoot] = []
    @Published var lyricsAutoFetch: Bool { didSet { defaults.set(lyricsAutoFetch, forKey: "lyricsAutoFetch") } }
    @Published var message: String?

    private let defaults = UserDefaults.standard
    private var accessing: [URL] = []
    private var lastSaved: Data?

    init() {
        let store = (try? LibraryStore())
            ?? (try! LibraryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("kveikur-\(UUID()).sqlite")))
        library = store
        metadata = MetadataStore(library: store)
        player = PlayerController(metadata: metadata)
        scrobbler = ScrobbleController(player: player, metadata: metadata)
        lyricsAutoFetch = defaults.object(forKey: "lyricsAutoFetch") as? Bool ?? true
        scrobbler.openURL = { UIApplication.shared.open($0) }
        scrobbler.onListen = { m, at in Task.detached { store.recordPlay(m, at: at) } }
        loadRoots()
        restore()
        let saver = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        saver.tolerance = 5
    }

    // MARK: Roots

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func loadRoots() {
        var list = [LibraryRoot(url: Self.documents, name: "On My iPhone")]
        var fresh: [Data] = []
        for data in defaults.array(forKey: "rootBookmarks") as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { accessing.append(url) }
            let bm = stale ? ((try? url.bookmarkData()) ?? data) : data
            fresh.append(bm)
            list.append(LibraryRoot(url: url, name: url.lastPathComponent, bookmark: bm))
        }
        defaults.set(fresh, forKey: "rootBookmarks")
        roots = list
    }

    func addRoot(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            message = "No access to \(url.lastPathComponent)"
            return
        }
        accessing.append(url)
        guard !roots.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              let bm = try? url.bookmarkData() else { return }
        roots.append(LibraryRoot(url: url, name: url.lastPathComponent, bookmark: bm))
        persistRoots()
    }

    func removeRoot(_ root: LibraryRoot) {
        guard !root.isLocal else { return }
        roots.removeAll { $0.id == root.id }
        if let i = accessing.firstIndex(of: root.url) {
            accessing[i].stopAccessingSecurityScopedResource()
            accessing.remove(at: i)
        }
        persistRoots()
    }

    private func persistRoots() {
        defaults.set(roots.compactMap(\.bookmark), forKey: "rootBookmarks")
    }

    // MARK: Listing

    nonisolated static func list(_ folder: URL) -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .ubiquitousItemDownloadingStatusKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        var items: [FolderItem] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                items.append(FolderItem(url: u, isFolder: true))
            } else if AudioFiles.isAudio(u) {
                let status = v?.ubiquitousItemDownloadingStatus
                items.append(FolderItem(url: u, isFolder: false, inCloud: status != nil && status != .current))
            }
        }
        return items.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    /// Tracks under `folder`, depth first in name order.
    nonisolated static func tracks(under folder: URL) -> [URL] {
        list(folder).flatMap { $0.isFolder ? tracks(under: $0.url) : [$0.url] }
    }

    func play(_ items: [FolderItem], from item: FolderItem) {
        let tracks = items.filter { !$0.isFolder }
        guard let i = tracks.firstIndex(of: item) else { return }
        download(tracks.map(\.url))
        player.play(tracks.map(\.url), startAt: i)
    }

    func playFolder(_ folder: URL, shuffle: Bool) {
        Task {
            let urls = await Task.detached { Self.tracks(under: folder) }.value
            guard !urls.isEmpty else { message = "No tracks in \(folder.lastPathComponent)"; return }
            download(urls)
            player.shuffle = shuffle
            player.play(urls, startAt: shuffle ? Int.random(in: urls.indices) : 0)
        }
    }

    func enqueue(_ item: FolderItem, next: Bool) {
        Task {
            let urls = item.isFolder ? await Task.detached { Self.tracks(under: item.url) }.value : [item.url]
            download(urls)
            if next { player.playNext(urls) } else { player.enqueue(urls) }
            message = next ? "Playing next" : "Added to queue"
        }
    }

    /// Asks iCloud Drive to fetch files that are only placeholders.
    func download(_ urls: [URL]) {
        for u in urls.prefix(50) {
            let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if let s = status, s != .current { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
        }
    }

    func lyricsProviders() -> [LyricsProvider] { [LRCLibProvider()] }

    // MARK: State

    /// The app container moves between installs and updates, so Documents paths are saved relative to it.
    private static let documentsToken = "@documents"

    func save() {
        var s = player.snapshot()
        let docs = Self.documents.standardizedFileURL.path
        s.queue = s.queue.map { $0.hasPrefix(docs + "/") ? Self.documentsToken + $0.dropFirst(docs.count) : $0 }
        guard let data = try? JSONEncoder().encode(s), data != lastSaved else { return }
        defaults.set(data, forKey: "playerState")
        lastSaved = data
    }

    private func restore() {
        guard let data = defaults.data(forKey: "playerState"),
              var s = try? JSONDecoder().decode(PlayerSnapshot.self, from: data) else { return }
        let docs = Self.documents.standardizedFileURL.path
        s.queue = s.queue.map { $0.hasPrefix(Self.documentsToken) ? docs + $0.dropFirst(Self.documentsToken.count) : $0 }
        player.restore(s)
    }
}

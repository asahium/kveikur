import AppKit
import Combine
import KveikurCore

@MainActor
final class AppModel: ObservableObject {
    let library: LibraryStore
    let metadata: MetadataStore
    let scanner: LibraryScanner
    let player: PlayerController
    let playlists: PlaylistStore
    let lyrics = LyricsService()
    let scrobbler: ScrobbleController

    @Published private(set) var roots: [URL]
    @Published private(set) var scanStatus = ""
    @Published var showTagTitles: Bool { didSet { defaults.set(showTagTitles, forKey: "showTagTitles") } }
    @Published var lyricsAutoFetch: Bool { didSet { defaults.set(lyricsAutoFetch, forKey: "lyricsAutoFetch") } }
    @Published var geniusToken: String { didSet { defaults.set(geniusToken, forKey: "geniusToken") } }
    @Published var saveLyricsSidecar: Bool {
        didSet { defaults.set(saveLyricsSidecar, forKey: "saveLyricsSidecar"); lyrics.saveSidecar = saveLyricsSidecar }
    }
    @Published var playlistsFolder: URL {
        didSet { defaults.set(playlistsFolder.path, forKey: "playlistsFolder"); playlists.folder = playlistsFolder }
    }

    /// Fired with changed directory paths (FSEvents) so the browser can refresh listings.
    var onFilesChanged: (([String]) -> Void)?
    var onLibraryIndexed: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var watcher: FolderWatcher?

    init() {
        let store: LibraryStore
        do {
            store = try LibraryStore()
        } catch {
            NSLog("Kveikur: library database unavailable (\(error)), using a temporary one")
            store = try! LibraryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("kveikur-\(UUID()).sqlite"))
        }
        library = store
        metadata = MetadataStore(library: store)
        scanner = LibraryScanner(store: store)
        player = PlayerController(metadata: metadata)
        scrobbler = ScrobbleController(player: player, metadata: metadata)
        scrobbler.openURL = { NSWorkspace.shared.open($0) }
        roots = (defaults.stringArray(forKey: "libraryRoots") ?? []).map { URL(fileURLWithPath: $0) }
        showTagTitles = defaults.object(forKey: "showTagTitles") as? Bool ?? true
        lyricsAutoFetch = defaults.object(forKey: "lyricsAutoFetch") as? Bool ?? true
        geniusToken = defaults.string(forKey: "geniusToken") ?? ""
        saveLyricsSidecar = defaults.bool(forKey: "saveLyricsSidecar")
        let pl = defaults.string(forKey: "playlistsFolder").map { URL(fileURLWithPath: $0) } ?? PlaylistStore.defaultFolder()
        playlistsFolder = pl
        playlists = PlaylistStore(folder: pl)
        lyrics.saveSidecar = saveLyricsSidecar

        scanner.onProgress = { [weak self] p in
            self?.scanStatus = p.running ? "Indexing \(p.processed)/\(p.total)" : ""
        }
        scanner.onFinished = { [weak self] in self?.onLibraryIndexed?() }
        watcher = FolderWatcher { [weak self] paths in
            guard let self else { return }
            self.onFilesChanged?(paths)
            self.rescan()
        }
        watcher?.watch(roots.map(\.path))
        rescan()
    }

    func rescan() {
        scanner.scan(roots: roots)
    }

    func addRoot(_ url: URL) {
        let u = url.standardizedFileURL
        guard !roots.contains(u) else { return }
        roots.append(u)
        persistRoots()
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        library.removeRoot(url.path)
        persistRoots()
    }

    private func persistRoots() {
        defaults.set(roots.map(\.path), forKey: "libraryRoots")
        watcher?.watch(roots.map(\.path))
        rescan()
    }

    func root(containing url: URL) -> URL? {
        let p = url.standardizedFileURL.path
        return roots.first { p == $0.path || p.hasPrefix($0.path + "/") }
    }

    func lyricsProviders() -> [LyricsProvider] {
        var p: [LyricsProvider] = [LRCLibProvider()]
        if !geniusToken.isEmpty { p.append(GeniusProvider(token: geniusToken)) }
        return p
    }

    func chooseFolder(title: String, then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { then(u) }
    }
}

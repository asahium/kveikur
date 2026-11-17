import AppKit
import KveikurCore

enum Location: Hashable {
    case home
    case folder(URL)
    case playlists
    case playlist(URL)

    var id: String {
        switch self {
        case .home: return "::home"
        case .folder(let u), .playlist(let u): return u.path
        case .playlists: return "::playlists"
        }
    }
}

struct Entry: Hashable {
    enum Kind: Hashable { case root, folder, track, playlist, playlistsRoot }

    let kind: Kind
    let url: URL?
    let name: String
    var mtime: Double = 0
    var size: Int64 = 0
    /// Position inside a playlist; playlists may contain the same file twice.
    var playlistIndex: Int?

    var id: String {
        if let i = playlistIndex { return "\(i):\(url?.path ?? "")" }
        return url?.path ?? "::playlists"
    }

    var isContainer: Bool { kind != .track }

    var location: Location? {
        switch kind {
        case .root, .folder: return url.map { .folder($0) }
        case .playlist: return url.map { .playlist($0) }
        case .playlistsRoot: return .playlists
        case .track: return nil
        }
    }
}

enum Preview {
    case none
    case entries(Location, [Entry])
    case track(URL)
}

struct BrowserChange: OptionSet {
    let rawValue: Int
    static let current = BrowserChange(rawValue: 1)
    static let parent = BrowserChange(rawValue: 2)
    static let preview = BrowserChange(rawValue: 4)
    static let cursor = BrowserChange(rawValue: 8)
    static let status = BrowserChange(rawValue: 16)
    static let all: BrowserChange = [.current, .parent, .preview, .cursor, .status]
}

/// One column left of the current folder: a listing of `location` with the entry we came through highlighted.
struct AncestorColumn: Equatable {
    var location: Location
    var entries: [Entry]
    var highlight: Int?
}

/// Navigation state for the yazi-style columns: up to `maxAncestors` ancestors, current (with cursor), preview.
@MainActor
final class BrowserModel {
    let app: AppModel

    private(set) var location: Location = .home
    private(set) var entries: [Entry] = []
    private(set) var visible: [Entry] = []
    private(set) var cursor = 0
    static let maxAncestors = 3
    /// Outermost first; the last one is the direct parent.
    private(set) var ancestors: [AncestorColumn] = []
    private(set) var preview: Preview = .none
    private(set) var loading = false

    private(set) var filter = ""
    private(set) var lastFind = ""
    private(set) var visualAnchor: Int?
    private var marks: [String: Entry] = [:]
    private var markOrder: [String] = []

    private var back: [Location] = []
    private var forward: [Location] = []
    private var cursorMemory: [Location: String] = [:]
    private var cache: [Location: [Entry]] = [:]
    private var cacheOrder: [Location] = []
    private var loadGeneration = 0
    private var previewGeneration = 0
    private var metaTasks: [Task<Void, Never>] = []

    var onChange: ((BrowserChange) -> Void)?
    var cursorEntry: Entry? { visible.indices.contains(cursor) ? visible[cursor] : nil }
    var markCount: Int { marks.count + (visualRange?.count ?? 0) }

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Listing

    private func remember(_ loc: Location, _ list: [Entry]) {
        cache[loc] = list
        cacheOrder.removeAll { $0 == loc }
        cacheOrder.append(loc)
        if cacheOrder.count > 48 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func list(_ loc: Location) async -> [Entry] {
        switch loc {
        case .home:
            var out = app.roots.map { Entry(kind: .root, url: $0, name: $0.lastPathComponent) }
            out.append(Entry(kind: .playlistsRoot, url: nil, name: "Playlists"))
            return out
        case .playlists:
            return app.playlists.playlists().map {
                Entry(kind: .playlist, url: $0, name: $0.deletingPathExtension().lastPathComponent)
            }
        case .playlist(let u):
            let store = app.playlists
            return await Task.detached {
                store.entries(u).enumerated().map { i, e in
                    Entry(kind: .track, url: e.url, name: e.url.lastPathComponent, playlistIndex: i)
                }
            }.value
        case .folder(let u):
            return await Task.detached { Self.listFolder(u) }.value
        }
    }

    nonisolated static func listFolder(_ url: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        var folders: [Entry] = []
        var files: [Entry] = []
        for item in items {
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true, v?.isPackage != true {
                folders.append(Entry(kind: .folder, url: item, name: item.lastPathComponent))
            } else if AudioFiles.isAudio(item) {
                files.append(Entry(kind: .track, url: item, name: item.lastPathComponent,
                                   mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                   size: Int64(v?.fileSize ?? 0)))
            } else if AudioFiles.isPlaylist(item) {
                files.append(Entry(kind: .playlist, url: item, name: item.lastPathComponent))
            }
        }
        let cmp: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: cmp) + files.sorted(by: cmp)
    }

    func parentLocation(of loc: Location) -> Location? {
        switch loc {
        case .home:
            return nil
        case .playlists:
            return .home
        case .playlist(let u):
            return u.deletingLastPathComponent().standardizedFileURL == app.playlistsFolder.standardizedFileURL
                ? .playlists : .folder(u.deletingLastPathComponent())
        case .folder(let u):
            if app.roots.contains(u) || u.path == "/" { return .home }
            return .folder(u.deletingLastPathComponent())
        }
    }

    // MARK: Navigation

    func start() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "browserLocation").flatMap(Self.decode), Self.exists(saved) {
            navigate(to: saved, record: false, cursorOn: d.string(forKey: "browserCursor"))
        } else {
            navigate(to: app.roots.count == 1 ? .folder(app.roots[0]) : .home, record: false)
        }
    }

    func saveState() {
        let d = UserDefaults.standard
        d.set(Self.encode(location), forKey: "browserLocation")
        d.set(cursorEntry?.id, forKey: "browserCursor")
    }

    private static func encode(_ loc: Location) -> String {
        switch loc {
        case .home: return "home"
        case .playlists: return "playlists"
        case .folder(let u): return "folder:" + u.path
        case .playlist(let u): return "playlist:" + u.path
        }
    }

    private static func decode(_ s: String) -> Location? {
        if s == "home" { return .home }
        if s == "playlists" { return .playlists }
        if s.hasPrefix("folder:") { return .folder(URL(fileURLWithPath: String(s.dropFirst(7)))) }
        if s.hasPrefix("playlist:") { return .playlist(URL(fileURLWithPath: String(s.dropFirst(9)))) }
        return nil
    }

    private static func exists(_ loc: Location) -> Bool {
        switch loc {
        case .home, .playlists: return true
        case .folder(let u), .playlist(let u): return FileManager.default.fileExists(atPath: u.path)
        }
    }

    func navigate(to loc: Location, record: Bool = true, cursorOn id: String? = nil) {
        if let e = cursorEntry { cursorMemory[location] = e.id }
        if record, loc != location {
            back.append(location)
            forward.removeAll()
        }
        location = loc
        filter = ""
        visualAnchor = nil
        let wanted = id ?? cursorMemory[loc]
        if let cached = cache[loc] {
            apply(cached, cursorOn: wanted)
        } else {
            entries = []
            visible = []
            cursor = 0
            loading = true
            onChange?(.all)
        }
        reload(cursorOn: wanted)
        loadAncestors()
    }

    /// Re-lists the current location, keeping the cursor on the same entry.
    func reload(cursorOn id: String? = nil) {
        loadGeneration += 1
        let gen = loadGeneration
        let loc = location
        Task {
            let fresh = await list(loc)
            guard gen == loadGeneration, loc == location else { return }
            remember(loc, fresh)
            loading = false
            if fresh != entries || entries.isEmpty {
                apply(fresh, cursorOn: id ?? cursorEntry?.id)
            } else {
                onChange?(.status)
            }
        }
    }

    private func apply(_ list: [Entry], cursorOn id: String?) {
        entries = list
        recomputeVisible(keeping: id)
        loadMetadata(for: list)
        onChange?(.all)
        updatePreview()
    }

    private func loadAncestors() {
        var chain: [(Location, Location)] = []
        var child = location
        while chain.count < Self.maxAncestors, let p = parentLocation(of: child) {
            chain.insert((p, child), at: 0)
            child = p
        }
        let current = location
        ancestors = chain.map { loc, child in
            let list = cache[loc] ?? []
            return AncestorColumn(location: loc, entries: list, highlight: list.firstIndex { $0.location == child })
        }
        onChange?(.parent)
        for (i, (loc, child)) in chain.enumerated() {
            Task {
                let fresh = await list(loc)
                remember(loc, fresh)
                guard self.location == current, self.ancestors.indices.contains(i) else { return }
                let col = AncestorColumn(location: loc, entries: fresh, highlight: fresh.firstIndex { $0.location == child })
                guard col != self.ancestors[i] else { return }
                self.ancestors[i] = col
                self.onChange?(.parent)
            }
        }
    }

    func goParent() {
        guard let p = parentLocation(of: location) else { return }
        navigate(to: p, cursorOn: location.id)
    }

    func goBack() {
        guard let l = back.popLast() else { return }
        forward.append(location)
        navigate(to: l, record: false)
    }

    func goForward() {
        guard let l = forward.popLast() else { return }
        back.append(location)
        navigate(to: l, record: false)
    }

    func goHome() {
        navigate(to: app.roots.count == 1 ? .folder(app.roots[0]) : .home)
    }

    /// Opens the folder containing `url` with the cursor on it.
    func reveal(_ url: URL) {
        navigate(to: .folder(url.deletingLastPathComponent()), cursorOn: url.path)
    }

    // MARK: Cursor

    func setCursor(_ i: Int, extendMarks: Bool = false) {
        guard !visible.isEmpty else { return }
        let n = max(0, min(i, visible.count - 1))
        if extendMarks {
            let lo = min(cursor, n), hi = max(cursor, n)
            for j in lo...hi { addMark(visible[j]) }
        }
        guard n != cursor || extendMarks else { return }
        cursor = n
        onChange?(extendMarks ? [.cursor, .current, .status] : [.cursor, .status])
        updatePreview()
    }

    func moveCursor(by d: Int, extendMarks: Bool = false) {
        setCursor(cursor + d, extendMarks: extendMarks)
    }

    // MARK: Preview

    private func updatePreview() {
        previewGeneration += 1
        let gen = previewGeneration
        guard let e = cursorEntry else {
            preview = .none
            onChange?(.preview)
            return
        }
        if e.kind == .track, let u = e.url {
            preview = .track(u)
            onChange?(.preview)
            return
        }
        guard let loc = e.location else { return }
        if let cached = cache[loc] {
            preview = .entries(loc, cached)
            onChange?(.preview)
        }
        Task {
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard gen == previewGeneration else { return }
            let fresh = await list(loc)
            remember(loc, fresh)
            guard gen == previewGeneration else { return }
            preview = .entries(loc, fresh)
            onChange?(.preview)
        }
    }

    // MARK: Metadata

    private func loadMetadata(for list: [Entry]) {
        metaTasks.forEach { $0.cancel() }
        metaTasks = []
        let tracks = list.filter { $0.kind == .track && $0.url != nil }
        guard !tracks.isEmpty else { return }
        var byFolder: [String: [FileStamp]] = [:]
        for t in tracks {
            let u = t.url!
            var stamp = FileStamp(url: u, mtime: t.mtime, size: t.size)
            if t.playlistIndex != nil, let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                stamp = FileStamp(url: u, mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, size: Int64(v.fileSize ?? 0))
            }
            byFolder[u.deletingLastPathComponent().path, default: []].append(stamp)
        }
        for (folder, files) in byFolder {
            metaTasks.append(app.metadata.load(folder: folder, files: files) { [weak self] _ in
                guard let self else { return }
                if !self.filter.isEmpty { self.recomputeVisible(keeping: self.cursorEntry?.id) }
                self.onChange?(.current)
            })
        }
    }

    func metadata(_ e: Entry) -> TrackMetadata? {
        guard e.kind == .track, let u = e.url else { return nil }
        return app.metadata.cached(u.path)
    }

    func displayName(_ e: Entry) -> String {
        guard e.kind == .track else { return e.name }
        if app.showTagTitles, let m = metadata(e), let title = m.title {
            if e.playlistIndex != nil, let artist = m.artist { return "\(artist) — \(title)" }
            if let n = m.trackNumber { return String(format: "%02d  %@", n, title) }
            return title
        }
        return (e.name as NSString).deletingPathExtension
    }

    // MARK: Filter and find

    func setFilter(_ q: String) {
        filter = q
        recomputeVisible(keeping: cursorEntry?.id)
        onChange?(.all)
        updatePreview()
    }

    private func recomputeVisible(keeping id: String?) {
        if filter.isEmpty {
            visible = entries
        } else {
            let m = FuzzyMatcher(filter)
            visible = entries
                .compactMap { e -> (Entry, Int)? in
                    m.score(FuzzyMatcher.prepare(displayName(e) + " " + e.name)).map { (e, $0) }
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        if let id, let i = visible.firstIndex(where: { $0.id == id }) {
            cursor = i
        } else {
            cursor = min(cursor, max(0, visible.count - 1))
            if !filter.isEmpty { cursor = 0 }
        }
    }

    /// Moves the cursor to the next entry matching `q` (wrapping). Returns false when nothing matches.
    @discardableResult
    func find(_ q: String, forward: Bool = true, skipCurrent: Bool = false) -> Bool {
        lastFind = q
        guard !q.isEmpty, !visible.isEmpty else { return false }
        let m = FuzzyMatcher(q)
        let n = visible.count
        let startOffset = skipCurrent ? 1 : 0
        for k in startOffset..<(n + startOffset) {
            let i = forward ? (cursor + k) % n : (cursor - k + n) % n
            if m.score(FuzzyMatcher.prepare(displayName(visible[i]))) != nil {
                setCursor(i)
                return true
            }
        }
        return false
    }

    func findNext(reverse: Bool) {
        find(lastFind, forward: !reverse, skipCurrent: true)
    }

    // MARK: Marks

    var visualRange: ClosedRange<Int>? {
        guard let a = visualAnchor, !visible.isEmpty else { return nil }
        return min(a, cursor)...max(a, cursor)
    }

    func isMarked(_ e: Entry, at row: Int) -> Bool {
        marks[e.id] != nil || (visualRange?.contains(row) ?? false)
    }

    private func addMark(_ e: Entry) {
        if marks[e.id] == nil { markOrder.append(e.id) }
        marks[e.id] = e
    }

    func toggleMark(advance: Bool = true) {
        guard let e = cursorEntry else { return }
        if marks[e.id] != nil {
            marks[e.id] = nil
            markOrder.removeAll { $0 == e.id }
        } else {
            addMark(e)
        }
        onChange?([.current, .status])
        if advance { moveCursor(by: 1) }
    }

    func toggleVisual() {
        if let r = visualRange {
            for i in r { addMark(visible[i]) }
            visualAnchor = nil
        } else {
            visualAnchor = cursor
        }
        onChange?([.current, .status])
    }

    func markAll() {
        for e in visible { addMark(e) }
        onChange?([.current, .status])
    }

    func clearMarks() {
        marks = [:]
        markOrder = []
        visualAnchor = nil
        onChange?([.current, .status])
    }

    /// Marked entries (mark order), the visual range, or the cursor entry.
    func targets() -> [Entry] {
        var out = markOrder.compactMap { marks[$0] }
        if let r = visualRange {
            for i in r where marks[visible[i].id] == nil { out.append(visible[i]) }
        }
        if out.isEmpty, let e = cursorEntry { out = [e] }
        return out
    }

    var isVisual: Bool { visualAnchor != nil }

    // MARK: Track resolution

    func tracks(for targets: [Entry]) async -> [URL] {
        var out: [URL] = []
        let store = app.playlists
        for e in targets {
            switch e.kind {
            case .track:
                if let u = e.url { out.append(u) }
            case .folder, .root:
                if let u = e.url { out += await Task.detached { Self.recursiveTracks(u) }.value }
            case .playlist:
                if let u = e.url { out += store.entries(u).map(\.url) }
            case .playlistsRoot:
                break
            }
        }
        return out
    }

    nonisolated static func recursiveTracks(_ root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        while let u = walker.nextObject() as? URL {
            if AudioFiles.isAudio(u) { out.append(u) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Tracks in the current listing (playlist order or folder order).
    var currentTracks: [Entry] { entries.filter { $0.kind == .track } }

    func clearCache(paths: [String]) {
        let set = Set(paths)
        for loc in cache.keys where set.contains(loc.id) { cache[loc] = nil }
        if set.contains(location.id) { reload() }
        if case .playlist = location { reload() }
    }

    func invalidate(_ loc: Location) {
        cache[loc] = nil
        if loc == location { reload() }
    }
}

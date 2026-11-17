import AppKit
import Combine
import KveikurCore

enum InspectorTab: Int, CaseIterable {
    case info, lyrics, queue, analysis, output

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .lyrics: return "quote.bubble"
        case .queue: return "music.note.list"
        case .analysis: return "waveform.path.ecg.rectangle"
        case .output: return "hifispeaker"
        }
    }

    var title: String {
        switch self {
        case .info: return "Info"
        case .lyrics: return "Lyrics"
        case .queue: return "Queue"
        case .analysis: return "Analysis"
        case .output: return "Output"
        }
    }
}

/// State behind the right-hand inspector. Info follows the cursor; the other tabs follow playback.
@MainActor
final class InspectorModel: ObservableObject {
    enum LyricsState: Equatable { case idle, loading, notFound, loaded }

    @Published var tab: InspectorTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "inspectorTab") }
    }
    @Published var followCursor = false

    @Published private(set) var infoURL: URL?
    @Published private(set) var infoMeta: TrackMetadata?
    @Published private(set) var infoTags: [String: String] = [:]
    @Published private(set) var infoImage: NSImage?
    @Published private(set) var infoContainer = ""

    @Published private(set) var lyricsURL: URL?
    @Published private(set) var lyricsMeta: TrackMetadata?
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsState: LyricsState = .idle

    let app: AppModel
    let analysis: AnalysisModel
    private var infoTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedURL: URL?
    private var bag = Set<AnyCancellable>()

    init(app: AppModel) {
        self.app = app
        analysis = AnalysisModel(player: app.player)
        tab = InspectorTab(rawValue: UserDefaults.standard.integer(forKey: "inspectorTab")) ?? .info
        app.player.$index.combineLatest(app.player.$queue)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateLyricsTarget() } }
            .store(in: &bag)
    }

    func cycleTab(by d: Int) {
        let all = InspectorTab.allCases
        tab = all[(tab.rawValue + d + all.count) % all.count]
    }

    // MARK: Info

    func showInfo(_ u: URL?) {
        guard u != infoURL else { return }
        infoURL = u
        infoMeta = u.flatMap { app.metadata.cached($0.path) }
        infoTags = [:]
        infoImage = nil
        infoContainer = ""
        infoTask?.cancel()
        if app.player.currentURL == nil { updateLyricsTarget() }
        guard let u else { return }
        infoTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled, u == infoURL else { return }
            let m = await app.metadata.metadata(for: u)
            guard u == infoURL else { return }
            infoMeta = m
            infoContainer = await Task.detached { ContainerSniffer.sniff(u).displayName }.value
            let tags = await MetadataReader.allTags(u)
            guard u == infoURL else { return }
            infoTags = tags
            if let cg = await ArtworkCache.shared.image(forTrack: u), u == infoURL {
                infoImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    // MARK: Lyrics

    private func updateLyricsTarget() {
        let target = app.player.currentURL ?? infoURL
        guard target != lyricsURL else { return }
        lyricsURL = target
        lyrics = nil
        lyricsMeta = nil
        lyricsState = .idle
        lyricsTask?.cancel()
        guard let u = target else { return }
        lyricsTask = Task {
            lyricsState = .loading
            lyricsMeta = await app.metadata.metadata(for: u)
            if let l = await app.lyrics.local(for: u), u == lyricsURL {
                lyrics = l
                lyricsState = .loaded
                return
            }
            guard u == lyricsURL else { return }
            if app.lyricsAutoFetch, !app.lyrics.recentlyMissed(u) { fetchOnline() } else { lyricsState = .notFound }
        }
        prefetchNext()
    }

    /// Downloads lyrics for the upcoming queue entry in the background so they are ready when it starts.
    private func prefetchNext() {
        let p = app.player
        guard app.lyricsAutoFetch, let i = p.index, p.queue.indices.contains(i + 1) else { return }
        let next = p.queue[i + 1]
        guard next != prefetchedURL else { return }
        prefetchedURL = next
        prefetchTask?.cancel()
        let service = app.lyrics
        let providers = app.lyricsProviders()
        let store = app.metadata
        prefetchTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, await service.local(for: next) == nil, !service.recentlyMissed(next) else { return }
            let m = await store.metadata(for: next)
            _ = await service.fetchOnline(Self.query(next, m), providers: providers)
        }
    }

    private static func query(_ u: URL, _ m: TrackMetadata?) -> LyricsQuery {
        LyricsQuery(
            url: u,
            title: m?.title ?? u.deletingPathExtension().lastPathComponent,
            artist: m?.artist ?? m?.albumArtist ?? "",
            album: m?.album,
            duration: m?.duration ?? 0
        )
    }

    func fetchOnline() {
        guard let u = lyricsURL else { return }
        lyricsTask?.cancel()
        lyricsState = .loading
        let q = Self.query(u, lyricsMeta ?? app.metadata.cached(u.path))
        let providers = app.lyricsProviders()
        let service = app.lyrics
        lyricsTask = Task {
            let l = await service.fetchOnline(q, providers: providers)
            guard u == lyricsURL else { return }
            lyrics = l ?? lyrics
            lyricsState = lyrics == nil ? .notFound : .loaded
        }
    }

    func adjustOffset(_ delta: TimeInterval) {
        guard var l = lyrics, let u = lyricsURL else { return }
        l.offset += delta
        lyrics = l
        app.lyrics.store(l, for: u)
    }
}

/// Live meters (tap installed only while the Analysis tab is on screen) and cached whole-track analysis.
@MainActor
final class AnalysisModel: ObservableObject {
    @Published private(set) var bands = [Float](repeating: -90, count: LiveAnalyzer.bandCount)
    @Published private(set) var peakDB: [Float] = [-90, -90]
    @Published private(set) var holdDB: [Float] = [-90, -90]
    @Published private(set) var correlation: Float = 0
    @Published private(set) var points: [SIMD2<Float>] = []
    @Published private(set) var track: TrackAnalysis?
    @Published private(set) var trackURL: URL?
    @Published private(set) var analyzing = false

    private let player: PlayerController
    private var active = false
    private var cache: [URL: TrackAnalysis] = [:]
    private var cacheOrder: [URL] = []
    private var task: Task<Void, Never>?
    private var holdAt = [Date.distantPast, Date.distantPast]
    private var bag = Set<AnyCancellable>()

    init(player: PlayerController) {
        self.player = player
        player.$index.combineLatest(player.$queue)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.currentChanged() } }
            .store(in: &bag)
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            let analyzer = LiveAnalyzer { [weak self] frame in
                DispatchQueue.main.async { self?.receive(frame) }
            }
            player.setAnalysisTap { buffer in analyzer.process(buffer) }
            currentChanged()
        } else {
            player.setAnalysisTap(nil)
        }
    }

    private func receive(_ f: LiveFrame) {
        guard active else { return }
        let decay: Float = 2.5
        bands = zip(bands, f.bands).map { old, new in max(new, old - decay) }
        let now = Date()
        var hold = holdDB
        for c in 0..<2 where c < f.peakDB.count {
            if f.peakDB[c] >= hold[c] || now.timeIntervalSince(holdAt[c]) > 1.5 {
                hold[c] = f.peakDB[c]
                holdAt[c] = now
            }
        }
        holdDB = hold
        peakDB = zip(peakDB, f.peakDB).map { old, new in max(new, old - 1.5) }
        correlation = correlation * 0.8 + f.correlation * 0.2
        points = f.points
    }

    private func currentChanged() {
        guard active, let u = player.currentURL, u != trackURL else { return }
        trackURL = u
        if let cached = cache[u] {
            track = cached
            return
        }
        track = nil
        analyzing = true
        task?.cancel()
        task = Task {
            let result = await Task.detached(priority: .utility) { try? TrackAnalyzer.analyze(u) }.value
            guard u == trackURL else { return }
            analyzing = false
            track = result
            if let r = result {
                cache[u] = r
                cacheOrder.append(u)
                if cacheOrder.count > 6 { cache[cacheOrder.removeFirst()] = nil }
            }
        }
    }
}

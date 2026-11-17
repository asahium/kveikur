import AppKit
import Combine
import KveikurCore

/// Watches playback once a second, counts real listening time and submits plays to Last.fm / ListenBrainz.
@MainActor
final class ScrobbleController: ObservableObject {
    @Published var lastfmEnabled: Bool { didSet { defaults.set(lastfmEnabled, forKey: "lastfmEnabled") } }
    @Published var lastfmKey: String { didSet { defaults.set(lastfmKey, forKey: "lastfmKey") } }
    @Published var lastfmSecret: String { didSet { defaults.set(lastfmSecret, forKey: "lastfmSecret") } }
    @Published private(set) var lastfmUser: String { didSet { defaults.set(lastfmUser, forKey: "lastfmUser") } }
    @Published private(set) var lastfmConnecting = false
    @Published var listenbrainzEnabled: Bool { didSet { defaults.set(listenbrainzEnabled, forKey: "listenbrainzEnabled") } }
    @Published var listenbrainzToken: String { didSet { defaults.set(listenbrainzToken, forKey: "listenbrainzToken") } }
    @Published private(set) var listenbrainzUser: String { didSet { defaults.set(listenbrainzUser, forKey: "listenbrainzUser") } }
    @Published private(set) var status = ""
    @Published private(set) var pending = 0

    private var lastfmSession: String { didSet { defaults.set(lastfmSession, forKey: "lastfmSession") } }
    private let player: PlayerController
    private let metadata: MetadataStore
    private let queue = ScrobbleQueue()
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private var trackURL: URL?
    private var track: ScrobbleTrack?
    private var counter = ListenCounter(duration: 0)
    private var listenedBeforeMeta: TimeInterval = 0
    private var startedAt: Date?
    private var sentNowPlaying = false
    private var lastTick = Date()
    private var lastPosition: TimeInterval = 0

    init(player: PlayerController, metadata: MetadataStore) {
        self.player = player
        self.metadata = metadata
        lastfmEnabled = defaults.bool(forKey: "lastfmEnabled")
        lastfmKey = defaults.string(forKey: "lastfmKey") ?? ""
        lastfmSecret = defaults.string(forKey: "lastfmSecret") ?? ""
        lastfmSession = defaults.string(forKey: "lastfmSession") ?? ""
        lastfmUser = defaults.string(forKey: "lastfmUser") ?? ""
        listenbrainzEnabled = defaults.bool(forKey: "listenbrainzEnabled")
        listenbrainzToken = defaults.string(forKey: "listenbrainzToken") ?? ""
        listenbrainzUser = defaults.string(forKey: "listenbrainzUser") ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        flush()
    }

    var lastfmConnected: Bool { !lastfmSession.isEmpty }

    private var services: [any ScrobbleService] {
        var s: [any ScrobbleService] = []
        if lastfmEnabled, lastfmConnected { s.append(LastFMService(apiKey: lastfmKey, secret: lastfmSecret, sessionKey: lastfmSession)) }
        if listenbrainzEnabled, !listenbrainzUser.isEmpty { s.append(ListenBrainzService(token: listenbrainzToken)) }
        return s
    }

    // MARK: Playback tracking

    private func tick() {
        let now = Date()
        let delta = min(now.timeIntervalSince(lastTick), 2)
        lastTick = now
        let url = player.currentURL
        let pos = player.position
        let restarted = url == trackURL && counter.reported && lastPosition > 10 && pos < 3
        if url != trackURL || restarted { begin(url) }
        lastPosition = pos
        guard url != nil, player.isPlaying else { return }
        if startedAt == nil { startedAt = now.addingTimeInterval(-pos) }
        if !sentNowPlaying, let t = track { sendNowPlaying(t) }
        if track == nil {
            listenedBeforeMeta += delta
        } else if counter.add(delta), var t = track {
            t.timestamp = Int((startedAt ?? now).timeIntervalSince1970)
            submit(t)
        }
    }

    private func begin(_ url: URL?) {
        trackURL = url
        track = nil
        counter = ListenCounter(duration: 0)
        listenedBeforeMeta = 0
        startedAt = nil
        sentNowPlaying = false
        guard let url else { return }
        Task {
            guard let m = await metadata.metadata(for: url), url == trackURL else { return }
            track = ScrobbleTrack(m, startedAt: Date())
            counter = ListenCounter(duration: m.duration)
            if listenedBeforeMeta > 0, counter.add(listenedBeforeMeta), var t = track {
                t.timestamp = Int((startedAt ?? Date()).timeIntervalSince1970)
                submit(t)
            }
        }
    }

    private func sendNowPlaying(_ t: ScrobbleTrack) {
        sentNowPlaying = true
        let s = services
        guard !s.isEmpty else { return }
        Task.detached {
            for svc in s { try? await svc.nowPlaying(t) }
        }
    }

    private func submit(_ t: ScrobbleTrack) {
        let ids = services.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            await queue.add(t, for: ids)
            flush()
        }
    }

    func flush() {
        let s = services
        Task {
            await queue.flush(s)
            let ids = s.map(\.id)
            var n = 0
            for id in ids { n += await queue.count(for: id) }
            pending = n
            if let e = await queue.lastError { status = e } else if !ids.isEmpty { status = "Up to date" }
        }
    }

    // MARK: Accounts

    /// Opens the Last.fm approval page, then polls for the session for up to two minutes.
    func connectLastFM() {
        let key = lastfmKey.trimmingCharacters(in: .whitespaces)
        let secret = lastfmSecret.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !secret.isEmpty else { status = "Enter the API key and shared secret first"; return }
        lastfmConnecting = true
        status = "Approve Kveikur in the browser…"
        Task {
            defer { lastfmConnecting = false }
            do {
                let token = try await LastFMService.requestToken(apiKey: key, secret: secret)
                NSWorkspace.shared.open(LastFMService.authURL(apiKey: key, token: token))
                for _ in 0..<60 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if let (name, sk) = try? await LastFMService.session(apiKey: key, secret: secret, token: token) {
                        lastfmSession = sk
                        lastfmUser = name
                        lastfmEnabled = true
                        status = "Connected to Last.fm as \(name)"
                        flush()
                        return
                    }
                }
                status = "Last.fm approval timed out"
            } catch {
                status = "Last.fm: \(error.localizedDescription)"
            }
        }
    }

    func disconnectLastFM() {
        lastfmSession = ""
        lastfmUser = ""
        lastfmEnabled = false
        Task { await queue.discard("lastfm") }
    }

    func connectListenBrainz() {
        let token = listenbrainzToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        status = "Checking ListenBrainz token…"
        Task {
            do {
                listenbrainzUser = try await ListenBrainzService.validate(token: token)
                listenbrainzEnabled = true
                status = "Connected to ListenBrainz as \(listenbrainzUser)"
                flush()
            } catch {
                listenbrainzUser = ""
                status = "ListenBrainz: \(error.localizedDescription)"
            }
        }
    }

    func disconnectListenBrainz() {
        listenbrainzUser = ""
        listenbrainzEnabled = false
        Task { await queue.discard("listenbrainz") }
    }
}

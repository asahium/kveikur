import Foundation
import IOKit.ps
import KveikurCore

let usage = """
    kveikur-lyrics: finds lyrics for the Kveikur library and word-syncs them on-device
    (Demucs vocal separation, then MMS forced alignment; needs uv and ffmpeg).
    Results go to Kveikur's lyrics cache and to <track>.lyricsfile.yaml (LRCGET's format), so they move with the music.

    usage: kveikur-lyrics [options] [folder …]
      folder          limit to these folders or files (default: Kveikur's library roots)
      --no-fetch      don't search online, only word-sync lyrics that are already there
      --no-align      only download lyrics, no word sync
      --exclude NAME  skip folders with this name (repeatable; default: OST)
      --retry         try again tracks that failed before
      --limit N       stop after N tracks that needed work
      --no-sidecar    don't write <track>.lyricsfile.yaml next to the tracks
      --battery       keep going on battery power (default: wait for the charger)
      --fast          normal priority instead of nice 10 / utility
      --dry-run       only list what would be done
    """

struct Options {
    var fetch = true
    var align = true
    var excluded: Set<String> = []
    var retry = false
    var limit = Int.max
    var sidecar = true
    var battery = false
    var fast = false
    var dryRun = false
    var folders: [String] = []
}

func parse() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    func value() -> String {
        guard let v = args.popFirst() else { print(usage); exit(2) }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--no-fetch": o.fetch = false
        case "--no-align": o.align = false
        case "--exclude": o.excluded.insert(value().lowercased())
        case "--retry": o.retry = true
        case "--limit": o.limit = Int(value()) ?? Int.max
        case "--no-sidecar": o.sidecar = false
        case "--battery": o.battery = true
        case "--fast": o.fast = true
        case "--dry-run": o.dryRun = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if a.hasPrefix("-") { print("unknown option \(a)\n"); print(usage); exit(2) }
            o.folders.append(URL(fileURLWithPath: a).standardizedFileURL.path)
        }
    }
    if o.excluded.isEmpty { o.excluded = ["ost"] }
    return o
}

/// Tracks that failed alignment, so reruns skip them.
struct State: Codable {
    var failed: [String: String] = [:]

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kveikur/lyrics-batch.json")

    static func load() -> State {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

func onBattery() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
    return type == kIOPSBatteryPowerValue
}

func line(_ s: String) {
    print(s)
    fflush(stdout)
}

let o = parse()
// A worker that died must surface as an error on write, not kill this process.
signal(SIGPIPE, SIG_IGN)
if !o.fast {
    // Nice, not the Darwin background band: that one is inherited by the worker and makes it 5× slower.
    setpriority(PRIO_PROCESS, 0, 10)
}

let prefs = UserDefaults(suiteName: "dev.kveikur.player")
let roots = o.folders.isEmpty ? (prefs?.stringArray(forKey: "libraryRoots") ?? []) : o.folders
guard !roots.isEmpty else {
    line("No folders: add music folders in Kveikur first, or pass them as arguments.")
    exit(1)
}
guard let store = try? LibraryStore() else {
    line("Can't open Kveikur's library index. Open Kveikur once so it scans the folders.")
    exit(1)
}

func included(_ path: String) -> Bool {
    guard let root = roots.first(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return false }
    let rel = path.dropFirst(root.count).split(separator: "/").dropLast()
    return !rel.contains { o.excluded.contains($0.lowercased()) }
}

let tracks = store.allTracks().filter { included($0.path) }.sorted { $0.path < $1.path }
line("\(tracks.count) tracks in \(roots.joined(separator: ", ")), skipping folders named \(o.excluded.sorted().joined(separator: ", ")).")

var providers: [LyricsProvider] = [LRCLibProvider()]
if prefs?.object(forKey: "lyricsNetEase") as? Bool ?? true { providers.append(NetEaseProvider()) }
if let token = prefs?.string(forKey: "geniusToken"), !token.isEmpty { providers.append(GeniusProvider(token: token)) }

let service = LyricsService()
var state = State.load()
let marker = "kveikur-lyrics"

/// `<track>.lyricsfile.yaml`, so the lyrics move with the music. Files not written by this tool are left alone.
func writeSidecar(_ l: Lyrics, _ t: TrackMetadata) -> Bool {
    guard o.sidecar, !o.dryRun, !CueTrackRef.isCue(t.url), l.source != "Lyricsfile" else { return false }
    let f = t.url.deletingPathExtension().appendingPathExtension("lyricsfile.yaml")
    let old = try? String(contentsOf: f, encoding: .utf8)
    if let old, !old.hasPrefix("# \(marker)") { return false }
    let meta = LyricsfileParser.Metadata(title: t.title ?? t.displayTitle, artist: t.artist ?? t.albumArtist ?? "",
                                         album: t.album, duration: t.duration)
    let text = LyricsfileParser.serialize(l, metadata: meta, comment: "\(marker): \(l.source)")
    guard text != old else { return false }
    return (try? text.write(to: f, atomically: true, encoding: .utf8)) != nil
}

let done = DispatchSemaphore(value: 0)
Task.detached {
    var stats: [String: Int] = [:]
    var aligner: Aligner?
    var worked = 0

    /// The best lyrics this run ends up with for the track.
    func handle(_ n: Int, _ t: TrackMetadata) async -> Lyrics? {
        let url = t.url
        let name = "[\(n + 1)/\(tracks.count)] \(t.artist ?? t.albumArtist ?? "?") — \(t.displayTitle)"

        var lyrics = await service.local(for: url)
        // Word timings from the earlier Whisper version of this tool are redone.
        if let l = lyrics, l.source.hasSuffix(" + Whisper") {
            lyrics?.source = String(l.source.dropLast(" + Whisper".count))
            lyrics = lyrics.map { var x = $0; x.lines = x.lines.map { var y = $0; y.words = nil; return y }; return x }
        }
        if lyrics?.rank == 2 { stats["already word-synced", default: 0] += 1; return lyrics }

        if lyrics == nil {
            guard o.fetch, !service.recentlyMissed(url) else { stats["no lyrics", default: 0] += 1; return nil }
            worked += 1
            if o.dryRun { line("\(name): would search online"); return nil }
            let q = LyricsQuery(url: url, title: t.title ?? t.displayTitle, artist: t.artist ?? t.albumArtist ?? "",
                                album: t.album, duration: t.duration)
            lyrics = await service.fetchOnline(q, providers: providers)
            guard let l = lyrics else { line("\(name): nothing online"); stats["no lyrics", default: 0] += 1; return nil }
            if l.rank == 2 { line("\(name): \(l.source), word-synced"); stats["downloaded word-synced", default: 0] += 1; return l }
            line("\(name): \(l.source), \(l.syncLabel)")
            stats["downloaded", default: 0] += 1
        }

        guard o.align, let l = lyrics else { return lyrics }
        if !o.retry, state.failed[t.path] != nil { stats["failed before", default: 0] += 1; return l }
        worked += 1
        if o.dryRun { line("\(name): would word-sync \(l.source) lyrics"); return nil }
        while !o.battery, onBattery() {
            line("On battery; waiting for the charger (or rerun with --battery).")
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let t0 = Date()
        defer { state.save() }
        do {
            if aligner == nil {
                line("Starting the aligner (the first run downloads about 1.5 GB of models)…")
                aligner = try Aligner(background: !o.fast)
            }
            let synced = try aligner!.align(l, url: url)
            service.store(synced, for: url)
            state.failed[t.path] = nil
            line(String(format: "%@: word-synced in %.0fs", name, Date().timeIntervalSince(t0)))
            stats["word-synced", default: 0] += 1
            return synced
        } catch {
            if error is Aligner.Failure == false || !(aligner?.running ?? false) { aligner = nil }
            state.failed[t.path] = error.localizedDescription
            line("\(name): couldn't word-sync (\(error.localizedDescription))")
            stats["word-sync failed", default: 0] += 1
            return l
        }
    }

    for (n, t) in tracks.enumerated() {
        guard worked < o.limit else { break }
        if let l = await handle(n, t), writeSidecar(l, t) { stats["lyricsfile written", default: 0] += 1 }
    }
    line("\nDone.")
    for (k, v) in stats.sorted(by: { $0.key < $1.key }) { line("  \(k): \(v)") }
    done.signal()
}
signal(SIGINT) { _ in
    print("\nStopped; rerun to continue where it left off.")
    exit(130)
}
done.wait()

import Foundation
import IOKit.ps
import KveikurCore

let usage = """
    kveikur-lyrics: finds lyrics for the Kveikur library and word-syncs them on-device with Whisper.
    Results go to Kveikur's lyrics cache, so the app shows them without any setup.

    usage: kveikur-lyrics [options] [folder …]
      folder          limit to these folders or files (default: Kveikur's library roots)
      --model NAME    small (216 MB, default) or turbo (632 MB, more accurate, slower)
      --no-fetch      don't search online, only word-sync lyrics that are already there
      --no-align      only download lyrics, no Whisper
      --exclude NAME  skip folders with this name (repeatable; default: OST)
      --retry         try again tracks that failed before
      --limit N       stop after N tracks that needed work
      --sidecar       also write a line-synced .lrc next to each track
      --battery       keep going on battery power (default: wait for the charger)
      --fast          normal priority instead of background
      --dry-run       only list what would be done
      --verbose       print what Whisper heard
    """

struct Options {
    var model = SpeechAligner.Model.small
    var fetch = true
    var align = true
    var excluded: Set<String> = []
    var retry = false
    var limit = Int.max
    var sidecar = false
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
        case "--model":
            guard let m = SpeechAligner.Model(rawValue: value()) else { print(usage); exit(2) }
            o.model = m
        case "--no-fetch": o.fetch = false
        case "--no-align": o.align = false
        case "--exclude": o.excluded.insert(value().lowercased())
        case "--retry": o.retry = true
        case "--limit": o.limit = Int(value()) ?? Int.max
        case "--sidecar": o.sidecar = true
        case "--battery": o.battery = true
        case "--fast": o.fast = true
        case "--dry-run": o.dryRun = true
        case "--verbose": SpeechAligner.verbose = true
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
if !o.fast {
    // Darwin background band: throttled CPU and disk, so playback and everything else win.
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
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
service.saveSidecar = o.sidecar
var state = State.load()

let done = DispatchSemaphore(value: 0)
Task.detached {
    var stats: [String: Int] = [:]
    var worked = 0
    for (n, t) in tracks.enumerated() {
        guard worked < o.limit else { break }
        let url = t.url
        let name = "[\(n + 1)/\(tracks.count)] \(t.artist ?? t.albumArtist ?? "?") — \(t.displayTitle)"

        var lyrics = await service.local(for: url)
        if lyrics?.rank == 2 { stats["already word-synced", default: 0] += 1; continue }

        if lyrics == nil {
            guard o.fetch, !service.recentlyMissed(url) else { stats["no lyrics", default: 0] += 1; continue }
            worked += 1
            if o.dryRun { line("\(name): would search online"); continue }
            let q = LyricsQuery(url: url, title: t.title ?? t.displayTitle, artist: t.artist ?? t.albumArtist ?? "",
                                album: t.album, duration: t.duration)
            lyrics = await service.fetchOnline(q, providers: providers)
            guard let l = lyrics else { line("\(name): nothing online"); stats["no lyrics", default: 0] += 1; continue }
            if l.rank == 2 { line("\(name): \(l.source), word-synced"); stats["downloaded word-synced", default: 0] += 1; continue }
            line("\(name): \(l.source), \(l.syncLabel)")
            stats["downloaded", default: 0] += 1
        }

        guard o.align, var l = lyrics else { continue }
        if !o.retry, state.failed[t.path] != nil { stats["failed before", default: 0] += 1; continue }
        worked += 1
        if o.dryRun { line("\(name): would word-sync \(l.source) lyrics"); continue }
        while !o.battery, onBattery() {
            line("On battery; waiting for the charger (or rerun with --battery).")
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let t0 = Date()
        do {
            l = try await SpeechAligner.shared.align(l, url: url, model: o.model) { p in
                line(String(format: "Downloading the %@ model: %.0f%%", o.model.rawValue, p * 100))
            }
            service.store(l, for: url)
            state.failed[t.path] = nil
            line(String(format: "%@: word-synced in %.0fs", name, Date().timeIntervalSince(t0)))
            stats["word-synced with Whisper", default: 0] += 1
        } catch {
            state.failed[t.path] = error.localizedDescription
            line("\(name): couldn't word-sync (\(error.localizedDescription))")
            stats["word-sync failed", default: 0] += 1
        }
        state.save()
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

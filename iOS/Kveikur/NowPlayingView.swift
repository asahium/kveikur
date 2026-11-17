import AVKit
import KveikurCore
import SwiftUI

/// Always on screen below the library, so it never covers the last row; empty until something is loaded.
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController
    let open: () -> Void

    var body: some View {
        let loaded = player.currentURL != nil
        VStack(spacing: 0) {
            ClockProgress(clock: player.clock).frame(height: 2)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? player.currentURL?.deletingPathExtension().lastPathComponent ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Nord.n6)
                    Text(player.current?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(Nord.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
            }
            .foregroundStyle(Nord.n6)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .opacity(loaded ? 1 : 0)
        }
        .background(Nord.bar)
        .contentShape(Rectangle())
        .onTapGesture { if loaded { open() } }
        .allowsHitTesting(loaded)
    }
}

private struct ClockProgress: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Nord.n2)
                Rectangle().fill(Nord.accent)
                    .frame(width: clock.duration > 0 ? g.size.width * min(1, clock.time / clock.duration) : 0)
            }
        }
    }
}

struct NowPlayingView: View {
    enum Tab: String, CaseIterable { case playing = "Playing", lyrics = "Lyrics", queue = "Queue", info = "Info" }

    @EnvironmentObject var model: MobileModel
    @EnvironmentObject var player: PlayerController
    @State private var tab: Tab

    init(tab: Tab = .playing) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
            switch tab {
            case .playing: PlayingTab(clock: player.clock)
            case .lyrics: LyricsTab(lyrics: LyricsModel(model: model), clock: player.clock)
            case .queue: QueueTab()
            case .info: InfoTab()
            }
        }
        .background(Nord.background)
    }
}

// MARK: Playing

private struct PlayingTab: View {
    @EnvironmentObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            if let art = player.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .padding(.horizontal, 32)
                    .layoutPriority(-1)
            }
            VStack(spacing: 6) {
                Text(player.current?.displayTitle ?? player.currentURL?.deletingPathExtension().lastPathComponent ?? "Nothing playing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Nord.n6)
                    .multilineTextAlignment(.center)
                Text(player.current?.artist ?? "")
                    .font(.headline)
                    .foregroundStyle(Nord.accent)
                Text(player.current?.album ?? "")
                    .font(.subheadline)
                    .foregroundStyle(Nord.secondary)
                if let f = player.current?.format {
                    Text(f.shortLabel)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Nord.n2, in: Capsule())
                        .foregroundStyle(Nord.n4)
                        .padding(.top, 4)
                }
            }
            .lineLimit(2)
            .padding(.horizontal, 24)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrub ?? clock.time }, set: { scrub = $0 }),
                       in: 0...max(clock.duration, 1)) { editing in
                    if !editing, let s = scrub {
                        player.seek(to: s)
                        scrub = nil
                    }
                }
                HStack {
                    Text(Format.duration(scrub ?? clock.time))
                    Spacer()
                    Text("-" + Format.duration(max(0, clock.duration - (scrub ?? clock.time))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Nord.secondary)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 44) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            }
            .foregroundStyle(Nord.n6)

            HStack(spacing: 28) {
                Button { player.shuffle.toggle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Nord.accent : Nord.secondary)
                }
                Button { player.repeatMode = next(player.repeatMode) } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Nord.secondary : Nord.accent)
                }
                Menu {
                    Picker("ReplayGain", selection: $player.replayGain.mode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Text("RG").font(.footnote.weight(.bold))
                        .foregroundStyle(player.replayGain.mode == .off ? Nord.secondary : Nord.accent)
                }
                Button { player.equalizer.enabled.toggle() } label: {
                    Text("EQ").font(.footnote.weight(.bold))
                        .foregroundStyle(player.equalizer.enabled ? Nord.accent : Nord.secondary)
                }
                RoutePicker().frame(width: 28, height: 28)
            }
            .font(.title3)
            Spacer()
        }
    }

    private func next(_ m: RepeatMode) -> RepeatMode {
        switch m {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Nord.secondary)
        v.activeTintColor = UIColor(Nord.accent)
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: Lyrics

@MainActor
final class LyricsModel: ObservableObject {
    enum State { case idle, loading, notFound, loaded }

    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var state: State = .idle
    private let model: MobileModel
    private var url: URL?

    init(model: MobileModel) { self.model = model }

    func load(_ u: URL?) async {
        guard u != url else { return }
        url = u
        lyrics = nil
        guard let u else { state = .idle; return }
        state = .loading
        if let l = await model.lyrics.local(for: u) {
            guard u == url else { return }
            lyrics = l
            state = .loaded
            return
        }
        guard model.lyricsAutoFetch, !model.lyrics.recentlyMissed(u) else { state = .notFound; return }
        await fetch(u)
    }

    func fetch(_ u: URL) async {
        state = .loading
        let m = await model.metadata.metadata(for: u)
        let q = LyricsQuery(url: u, title: m?.title ?? u.deletingPathExtension().lastPathComponent,
                            artist: m?.artist ?? m?.albumArtist ?? "", album: m?.album, duration: m?.duration ?? 0)
        let l = await model.lyrics.fetchOnline(q, providers: model.lyricsProviders())
        guard u == url else { return }
        lyrics = l
        state = l == nil ? .notFound : .loaded
    }
}

private struct LyricsTab: View {
    @EnvironmentObject var player: PlayerController
    @StateObject var lyrics: LyricsModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Group {
            switch lyrics.state {
            case .idle:
                Text("Nothing playing").foregroundStyle(Nord.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound:
                VStack(spacing: 12) {
                    Text("No lyrics").foregroundStyle(Nord.secondary)
                    if let u = player.currentURL {
                        Button("Search online") { Task { await lyrics.fetch(u) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let l = lyrics.lyrics { lines(l) }
            }
        }
        .task(id: player.currentURL) { await lyrics.load(player.currentURL) }
    }

    private func lines(_ l: Lyrics) -> some View {
        let active = l.activeIndex(at: clock.time)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(l.lines.indices, id: \.self) { i in
                        let line = l.lines[i]
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: i == active ? 26 : 22, weight: .bold))
                            .foregroundStyle(l.synced ? (i == active ? Nord.n6 : Nord.n4.opacity(0.35)) : Nord.n4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let t = line.time { player.seek(to: max(0, t + l.offset)) }
                            }
                            .id(i)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .animation(.easeOut(duration: 0.25), value: active)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.spring(duration: 0.45)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
            .onAppear { if let a = active { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.35)) } }
        }
    }
}

// MARK: Queue

private struct QueueTitle: View {
    @EnvironmentObject var model: MobileModel
    let url: URL
    let current: Bool
    @State private var meta: TrackMetadata?

    var body: some View {
        Text(meta?.displayTitle ?? url.deletingPathExtension().lastPathComponent)
            .foregroundStyle(current ? Nord.playing : Nord.text)
            .lineLimit(1)
            .task(id: url) {
                meta = model.metadata.cached(url.path)
                if meta == nil { meta = await model.metadata.metadata(for: url) }
            }
    }
}

private struct QueueTab: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: MobileModel

    var body: some View {
        List {
            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, u in
                let current = i == player.index
                HStack(spacing: 10) {
                    Image(systemName: current ? "speaker.wave.2.fill" : "music.note")
                        .foregroundStyle(current ? Nord.playing : Nord.n7)
                        .frame(width: 20)
                    QueueTitle(url: u, current: current)
                }
                .contentShape(Rectangle())
                .onTapGesture { player.jump(toQueueIndex: i) }
                .listRowBackground(current ? Nord.raised : Nord.background)
                .deleteDisabled(current)
            }
            .onDelete { set in set.sorted(by: >).forEach { player.removeFromQueue(at: $0) } }
            .onMove { player.moveQueueItems(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .nordList()
        .environment(\.editMode, .constant(.active))
        .overlay { if player.queue.isEmpty { Text("Queue is empty").foregroundStyle(Nord.secondary) } }
    }
}

// MARK: Info

private struct InfoTab: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        List {
            if let m = player.current {
                Section("File") {
                    row("Format", m.format.map { "\($0.codec) · \($0.shortLabel)" } ?? "–")
                    if m.bitrate > 0 { row("Bitrate", "\(m.bitrate) kbps") }
                    row("Duration", Format.duration(m.duration))
                    row("Size", Format.bytes(m.size))
                    row("File", m.fileName)
                }
                Section("Tags") {
                    row("Artist", m.artist ?? "–")
                    row("Album", m.album ?? "–")
                    if let y = m.year { row("Year", y) }
                    if let g = m.genre { row("Genre", g) }
                }
            }
            Section("Output") {
                row("Route", "\(player.deviceDetails.name) · \(player.deviceDetails.transport)")
                row("Sample rate", player.signalPath.deviceRate > 0 ? "\(SourceFormat.formatRate(player.signalPath.deviceRate)) kHz" : "–")
                row("Path", player.signalPath.label)
                row("ReplayGain", player.signalPath.gainDB != 0 ? String(format: "%+.1f dB", player.signalPath.gainDB) : "none")
                row("Equalizer", player.signalPath.equalizer ? player.equalizer.preset.name : "off")
            }
        }
        .nordList()
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Nord.secondary)
            Spacer(minLength: 16)
            Text(v).foregroundStyle(Nord.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
        .listRowBackground(Nord.raised)
    }
}

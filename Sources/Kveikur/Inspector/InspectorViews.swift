import AppKit
import KveikurCore
import SwiftUI

struct InspectorTabBar: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    model.tab = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(model.tab == tab ? Color(nsColor: Theme.nord0) : Color.secondary)
                        .background(Capsule().fill(model.tab == tab ? Theme.accent : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(tab.title) (\(tab.rawValue + 1))")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: Theme.nord0).opacity(0.6)))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct InspectorContent: View {
    @ObservedObject var model: InspectorModel
    @ObservedObject var player: PlayerController

    var body: some View {
        Group {
            switch model.tab {
            case .info: InfoTab(model: model, player: player)
            case .lyrics: LyricsTab(model: model, player: player, clock: player.clock)
            case .queue: QueueTab(player: player, metadata: model.app.metadata)
            case .analysis: AnalysisTab(model: model.analysis, player: player, clock: player.clock)
            case .output: OutputTab(player: player, metadata: model.app.metadata)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Shared pieces

struct PanelSection<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let help {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary).help(help)
                }
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 14) }
    }
}

struct KVRows: View {
    let rows: [(String, String)]
    var mono = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                    Text(rows[i].1)
                        .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .font(.system(size: 12))
            }
        }
    }
}

struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
    }
}

// MARK: Info

struct InfoTab: View {
    @ObservedObject var model: InspectorModel
    @ObservedObject var player: PlayerController

    var body: some View {
        if model.infoURL == nil {
            Placeholder(text: "Select a track")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    let t = model.infoTags
                    let details = detailRows(t)
                    if !details.isEmpty { PanelSection(title: "Details") { KVRows(rows: details) } }
                    let ids = rows(t, [("Barcode", ["barcode", "upc", "ean"]), ("Catalog #", ["catalognumber", "catalog"]),
                                       ("MB Release", ["musicbrainz_albumid"]), ("MB Track", ["musicbrainz_trackid", "musicbrainz_releasetrackid"]),
                                       ("Copyright", ["copyright"])])
                    if !ids.isEmpty { PanelSection(title: "Release & identifiers") { KVRows(rows: ids) } }
                    let musical = rows(t, [("BPM", ["bpm"]), ("Key", ["initialkey", "key"]),
                                           ("Track Gain", ["replaygain_track_gain"]), ("Track Peak", ["replaygain_track_peak"]),
                                           ("Album Gain", ["replaygain_album_gain"]), ("Album Peak", ["replaygain_album_peak"])])
                    if !musical.isEmpty { PanelSection(title: "Musical & loudness") { KVRows(rows: musical) } }
                    PanelSection(title: "File") { KVRows(rows: fileRows(), mono: true) }
                    let other = otherRows(t)
                    if !other.isEmpty {
                        PanelSection(title: "Other tags") { KVRows(rows: other) }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let img = model.infoImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.tertiary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.infoMeta?.displayTitle ?? model.infoURL?.lastPathComponent ?? "")
                    .font(.system(size: 15, weight: .bold)).textSelection(.enabled)
                if let a = model.infoMeta?.artist { Text(a).font(.system(size: 12)).foregroundStyle(.secondary) }
                if let a = model.infoMeta?.album { Text(a).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
    }

    private static let detailKeys: [(String, [String])] = [
        ("Title", ["title"]), ("Artist", ["artist"]), ("Album Artist", ["albumartist"]), ("Album", ["album"]),
        ("Track", ["tracknumber"]), ("Disc", ["discnumber"]), ("Genre", ["genre"]), ("Composer", ["composer"]),
        ("Released", ["date", "year", "originaldate"]), ("Label", ["label", "organization", "publisher"]), ("ISRC", ["isrc"]),
    ]

    private func detailRows(_ t: [String: String]) -> [(String, String)] {
        var r = rows(t, Self.detailKeys)
        if r.isEmpty, let m = model.infoMeta {
            func add(_ k: String, _ v: String?) { if let v { r.append((k, v)) } }
            add("Title", m.title)
            add("Artist", m.artist)
            add("Album", m.album)
            add("Track", m.trackNumber.map(String.init))
            add("Genre", m.genre)
            add("Released", m.year)
        }
        return r
    }

    private func rows(_ t: [String: String], _ keys: [(String, [String])]) -> [(String, String)] {
        keys.compactMap { label, ks in ks.lazy.compactMap { t[$0] }.first.map { (label, $0) } }
    }

    private static let shown: Set<String> = Set(
        detailKeys.flatMap(\.1) + ["barcode", "upc", "ean", "catalognumber", "catalog", "musicbrainz_albumid", "musicbrainz_trackid",
                                   "musicbrainz_releasetrackid", "copyright", "bpm", "initialkey", "key", "replaygain_track_gain",
                                   "replaygain_track_peak", "replaygain_album_gain", "replaygain_album_peak",
                                   "tracktotal", "totaltracks", "disctotal", "totaldiscs", "encoder", "vendor"]
    )

    private func otherRows(_ t: [String: String]) -> [(String, String)] {
        t.filter { !Self.shown.contains($0.key) && $0.value.count < 300 }
            .sorted { $0.key < $1.key }
            .map { ($0.key.replacingOccurrences(of: "_", with: " ").capitalized, $0.value) }
    }

    private func fileRows() -> [(String, String)] {
        var r: [(String, String)] = []
        if !model.infoContainer.isEmpty { r.append(("Container", model.infoContainer)) }
        if let m = model.infoMeta {
            if let f = m.format {
                r.append(("Codec", f.codec))
                r.append(("Sample Rate", "\(SourceFormat.formatRate(f.sampleRate)) kHz"))
                r.append(("Bit Depth", f.bitDepth > 0 ? "\(f.bitDepth)-bit" : "n/a (lossy)"))
                r.append(("Channels", "\(f.channels)"))
            }
            if m.bitrate > 0 { r.append(("Bitrate", "\(m.bitrate) kbps")) }
            r.append(("Duration", Format.duration(m.duration)))
            r.append(("Size", Format.bytes(m.size)))
        }
        if let u = model.infoURL {
            if let (sheet, t) = CueTrackRef.resolve(u) {
                r.append(("Cue Sheet", sheet.url.lastPathComponent))
                r.append(("Range", Format.duration(t.start) + " – " + (t.end.map(Format.duration) ?? "end")))
            }
            r.append(("Path", CueTrackRef.audioFile(u).path))
        }
        return r
    }
}

// MARK: Lyrics

struct LyricsTab: View {
    @ObservedObject var model: InspectorModel
    @ObservedObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock

    private var isCurrent: Bool { model.lyricsURL != nil && model.lyricsURL == player.currentURL }

    var body: some View {
        VStack(spacing: 0) {
            if let u = model.lyricsURL {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.lyricsMeta?.displayTitle ?? u.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(model.lyricsMeta?.artist ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                Divider()
            }
            switch model.lyricsState {
            case .loading:
                Placeholder(text: "Looking for lyrics…")
            case .notFound, .idle:
                VStack(spacing: 10) {
                    Spacer()
                    Text(model.lyricsURL == nil ? "Nothing playing" : "No lyrics").foregroundStyle(.secondary)
                    if model.lyricsURL != nil { Button("Search online  (gl)") { model.fetchOnline() } }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .loaded:
                if let l = model.lyrics { lines(l) }
            }
        }
    }

    @ViewBuilder
    private func lines(_ l: Lyrics) -> some View {
        let active = isCurrent ? l.activeIndex(at: clock.time) : nil
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(l.lines.indices, id: \.self) { i in
                        let line = l.lines[i]
                        Group {
                            if i == active, line.words != nil {
                                WordSyncText.make(line, at: clock.time - l.offset, sung: Color(nsColor: Theme.nord6),
                                                  unsung: Color(nsColor: Theme.nord4).opacity(0.45))
                            } else {
                                Text(line.text.isEmpty ? "♪" : line.text)
                            }
                        }
                            .font(.system(size: 16, weight: i == active ? .bold : .medium))
                            .foregroundStyle(i == active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(to: line, lyrics: l) }
                            .id(i)
                    }
                }
                .padding(14)
                .textSelection(.enabled)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        Divider()
        HStack(spacing: 8) {
            Text("\(l.source) · \(l.syncLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if l.synced {
                Button { model.adjustOffset(-0.25) } label: { Image(systemName: "minus") }.help("Lyrics earlier")
                Text(String(format: "%+.2fs", l.offset)).font(.system(size: 11).monospacedDigit())
                Button { model.adjustOffset(0.25) } label: { Image(systemName: "plus") }.help("Lyrics later")
            }
            Button { model.fetchOnline() } label: { Image(systemName: "arrow.clockwise") }.help("Search online again")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func seek(to line: LyricLine, lyrics: Lyrics) {
        guard let t = line.time, let u = model.lyricsURL else { return }
        if isCurrent {
            player.seek(to: max(0, t + lyrics.offset))
        } else if let i = player.queue.firstIndex(of: u) {
            player.jump(toQueueIndex: i)
        } else {
            player.play([u])
        }
    }
}

// MARK: Queue

struct QueueTab: View {
    @ObservedObject var player: PlayerController
    let metadata: MetadataStore
    @State private var selection: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                Text("Queue").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(player.queue.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.shuffle ? Theme.accent : Color.secondary).help("Shuffle (S)")
                Button { player.repeatMode = TransportBar.nextRepeat(player.repeatMode) } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .foregroundStyle(player.repeatMode != .off ? Theme.accent : Color.secondary).help("Repeat (r)")
                Button { player.clearQueue() } label: { Image(systemName: "trash") }.help("Clear queue")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if player.queue.isEmpty {
                Placeholder(text: "Queue is empty")
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, u in
                            row(i, u).tag(i).id(i)
                        }
                        .onMove { player.moveQueueItems(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { if let i = player.index { proxy.scrollTo(i, anchor: .center) } }
                    .onChange(of: player.index) { _, i in if let i { withAnimation { proxy.scrollTo(i, anchor: .center) } } }
                }
            }
        }
    }

    private func row(_ i: Int, _ u: URL) -> some View {
        let m = metadata.cached(u.path)
        let current = i == player.index
        return HStack(spacing: 8) {
            Image(systemName: current ? "speaker.wave.2.fill" : "circle")
                .font(.system(size: current ? 11 : 9))
                .foregroundStyle(current ? Theme.accent : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(m?.displayTitle ?? u.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: current ? .bold : .semibold)).lineLimit(1)
                Text(m?.artist ?? u.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(m.map { Format.duration($0.duration) } ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.jump(toQueueIndex: i) }
        .contextMenu {
            Button("Play") { player.jump(toQueueIndex: i) }
            Button("Remove from Queue") { player.removeFromQueue(at: i) }.disabled(current)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CueTrackRef.audioFile(u)]) }
        }
    }
}

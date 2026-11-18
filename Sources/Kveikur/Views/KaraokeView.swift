import AppKit
import KveikurCore
import SwiftUI

/// Full-window synced lyrics; the active line fills left to right as it is sung.
final class KaraokeOverlay: NSHostingView<KaraokeView> {
    private let visibility: KaraokeView.Visibility

    init(inspector: InspectorModel, player: PlayerController) {
        let v = KaraokeView.Visibility()
        visibility = v
        super.init(rootView: KaraokeView(model: inspector, player: player, clock: player.clock, visibility: v))
        sizingOptions = []
        isHidden = true
        alphaValue = 0
    }

    @MainActor required init(rootView: KaraokeView) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }

    var isShown: Bool { !isHidden }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard isHidden else { return }
        isHidden = false
        visibility.shown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        visibility.shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.visibility.shown == false { self?.isHidden = true }
            }
        })
    }
}

struct KaraokeView: View {
    @MainActor final class Visibility: ObservableObject {
        @Published var shown = false
    }

    @ObservedObject var model: InspectorModel
    @ObservedObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var visibility: Visibility

    private var isCurrent: Bool { model.lyricsURL != nil && model.lyricsURL == player.currentURL }

    var body: some View {
        ZStack {
            Color(nsColor: Theme.nord0)
            RadialGradient(colors: [Color(nsColor: Theme.nord10).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.2, y: 0.35), startRadius: 0, endRadius: 700)
            VStack(spacing: 0) {
                header
                content
                footer
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.displayTitle ?? player.currentURL?.deletingPathExtension().lastPathComponent ?? "Nothing playing")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(nsColor: Theme.nord6))
                Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: Theme.secondaryText))
            }
            .lineLimit(1)
            Spacer()
            Text("esc  close    ⌘L  toggle")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: Theme.secondaryText))
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !isCurrent || model.lyricsState == .notFound || model.lyricsState == .idle {
            placeholder(player.currentURL == nil ? "Nothing playing" : "No lyrics for this track")
        } else if model.lyricsState == .loading || model.lyrics == nil {
            placeholder("Looking for lyrics…")
        } else if let l = model.lyrics {
            if l.synced {
                synced(l)
            } else {
                plain(l)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color(nsColor: Theme.secondaryText))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func synced(_ l: Lyrics) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !visibility.shown || !player.isPlaying)) { _ in
            let t = player.position
            let active = l.activeIndex(at: t)
            SyncedLines(lyrics: l, time: t, active: active) { line in
                if let lt = line.time { player.seek(to: max(0, lt + l.offset)) }
            }
        }
    }

    private func plain(_ l: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(l.lines.indices, id: \.self) { i in
                    Text(l.lines[i].text.isEmpty ? " " : l.lines[i].text)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Theme.nord4))
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(Format.duration(clock.time)).monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: Theme.nord2))
                    Capsule().fill(Theme.accent)
                        .frame(width: clock.duration > 0 ? geo.size.width * min(1, clock.time / clock.duration) : 0)
                }
            }
            .frame(height: 3)
            Text(Format.duration(clock.duration)).monospacedDigit()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(nsColor: Theme.secondaryText))
        .padding(.horizontal, 48)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }
}

private struct SyncedLines: View {
    let lyrics: Lyrics
    let time: TimeInterval
    let active: Int?
    let onTap: (LyricLine) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 200)
                    ForEach(lyrics.lines.indices, id: \.self) { i in
                        line(i)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(lyrics.lines[i]) }
                    }
                    Color.clear.frame(height: 300)
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onAppear { if let a = active { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.4)) } }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.spring(duration: 0.45)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.4)) }
            }
        }
    }

    @ViewBuilder
    private func line(_ i: Int) -> some View {
        let text = lyrics.lines[i].text.isEmpty ? "♪" : lyrics.lines[i].text
        let distance = active.map { abs($0 - i) } ?? 3
        if i == active, lyrics.lines[i].words != nil {
            WordSyncText.make(lyrics.lines[i], at: time - lyrics.offset, sung: Color(nsColor: Theme.nord6),
                              unsung: Color(nsColor: Theme.nord4).opacity(0.35))
                .font(.system(size: 38, weight: .bold))
                .shadow(color: Theme.accent.opacity(0.35), radius: 12)
                .fixedSize(horizontal: false, vertical: true)
        } else if i == active {
            let p = progress(i)
            Text(text)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(Color(nsColor: Theme.nord4).opacity(0.35))
                .overlay(alignment: .leading) {
                    Text(text)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Color(nsColor: Theme.nord6))
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                LinearGradient(stops: [.init(color: .black, location: 0),
                                                       .init(color: .black, location: max(0, p - 0.02)),
                                                       .init(color: .clear, location: min(1, p + 0.02))],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width)
                            }
                        }
                        .shadow(color: Theme.accent.opacity(0.35), radius: 12)
                }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.nord4).opacity(distance == 1 ? 0.45 : (distance == 2 ? 0.3 : 0.18)))
                .blur(radius: distance >= 3 ? 0.6 : 0)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 0...1 through line `i`, ending at the next timed line (or 4 s later for the last one).
    private func progress(_ i: Int) -> CGFloat {
        guard let start = lyrics.lines[i].time else { return 1 }
        let next = lyrics.lines[(i + 1)...].first { $0.time != nil }?.time ?? start + 4
        let t = time - lyrics.offset
        let span = max(0.3, min(next - start, 12))
        return CGFloat(min(max((t - start) / span, 0), 1))
    }
}

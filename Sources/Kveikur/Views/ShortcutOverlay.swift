import AppKit
import SwiftUI

/// Cheat sheet shown while ⌘ is held on its own.
final class ShortcutOverlay: NSHostingView<ShortcutSheet> {
    private lazy var naturalSize = NSHostingView(rootView: ShortcutPanel()).fittingSize

    required init() {
        super.init(rootView: ShortcutSheet(scale: 1))
        sizingOptions = []
        alphaValue = 0
        isHidden = true
    }

    @MainActor required init(rootView: ShortcutSheet) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }
        let fit = min(1, (bounds.width - 40) / naturalSize.width, (bounds.height - 40) / naturalSize.height)
        let scale = max(0.4, (fit * 100).rounded(.down) / 100)
        if scale != rootView.scale { rootView = ShortcutSheet(scale: scale) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShown: Bool { !isHidden && alphaValue > 0 }

    func show() {
        guard isHidden else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.alphaValue == 0 { self?.isHidden = true }
            }
        })
    }
}

/// Fires `onHold` after ⌘ alone has been held for `delay`; any other key or modifier cancels it.
@MainActor
final class CommandHoldDetector {
    var onHold: () -> Void = {}
    var onRelease: () -> Void = {}
    private var work: DispatchWorkItem?
    private let delay: TimeInterval = 0.6

    func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        if flags == .command {
            schedule()
        } else {
            cancel()
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        onRelease()
    }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return }
                self.onHold()
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

struct ShortcutSheet: View {
    let scale: CGFloat

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            ShortcutPanel()
                .fixedSize()
                .scaleEffect(scale)
        }
    }
}

struct ShortcutPanel: View {
    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let keys: [String]
    }

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    static let columns: [[Section]] = [
        [
            section("Navigation", [.down, .up, .top, .bottom, .halfDown, .halfUp, .pageDown, .pageUp,
                                   .parent, .open, .back, .forward, .home, .playlists, .revealPlaying]),
            section("Search", [.find, .findBack, .findNext, .findPrev, .filter, .jumpFolder, .searchTracks, .palette]),
        ],
        [
            section("Playback", [.play, .playAll, .enqueue, .playNext, .playPause, .nextTrack, .prevTrack,
                                 .seekForward, .seekBackward, .volumeUp, .volumeDown, .toggleShuffle, .cycleRepeat, .showQueue]),
            section("Selection", [.toggleMark, .toggleVisual, .extendDown, .extendUp, .clearMarks, .selectAll]),
            section("Sound", [.equalizer, .toggleEQ, .cycleReplayGain]),
        ],
        [
            section("Inspector", [.togglePreview, .cycleInspectorTab, .prevInspectorTab, .tabInfo, .tabLyrics,
                                  .tabQueue, .tabAnalysis, .tabOutput, .pinNowPlaying, .fetchLyrics, .karaoke]),
            section("Files & Playlists", [.revealInFinder, .copyPath, .addToPlaylist, .newPlaylist, .removeFromPlaylist,
                                          .moveEntryDown, .moveEntryUp, .rescan, .addFolder, .duplicates, .statistics, .escape]),
            Section(title: "App", rows: [
                Row(title: "Settings", keys: ["⌘,"]),
                Row(title: "Close window", keys: ["⌘W"]),
                Row(title: "Full screen", keys: ["⌃⌘F"]),
                Row(title: "Hide", keys: ["⌘H"]),
                Row(title: "Quit", keys: ["⌘Q"]),
            ]),
        ],
    ]

    private static func section(_ title: String, _ commands: [Command]) -> Section {
        Section(title: title, rows: commands.compactMap { c in
            let keys = Keymap.keys(for: c).prefix(3).map(display)
            return keys.isEmpty ? nil : Row(title: c.title, keys: Array(keys))
        })
    }

    private static let symbols: [String: String] = [
        "Enter": "↩", "Esc": "⎋", "Tab": "⇥", "Space": "Space", "Backspace": "⌫", "Delete": "⌦",
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Home": "↖", "End": "↘",
        "PageUp": "⇞", "PageDown": "⇟",
    ]

    /// "<C-d>" -> "⌃D", "<S-Tab>" -> "⇧⇥", "gg" -> "g g".
    static func display(_ token: String) -> String {
        guard token.hasPrefix("<"), token.hasSuffix(">"), token.count > 2 else {
            return token.map(String.init).joined(separator: " ")
        }
        var body = String(token.dropFirst().dropLast())
        var mods = Set<String>()
        var matched = true
        while matched {
            matched = false
            for p in ["C-", "D-", "A-", "S-"] where body.hasPrefix(p) && body.count > p.count {
                mods.insert(p)
                body.removeFirst(p.count)
                matched = true
            }
        }
        let prefix = [("C-", "⌃"), ("A-", "⌥"), ("S-", "⇧"), ("D-", "⌘")].filter { mods.contains($0.0) }.map(\.1).joined()
        let key = symbols[body] ?? (mods.isEmpty ? body : body.uppercased())
        return prefix + key
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, sections in
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { sectionView($0) }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: Theme.nord0).opacity(0.82))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.nord3).opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func sectionView(_ s: Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(s.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 3)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(s.rows) { row in
                    GridRow {
                        HStack(spacing: 4) {
                            ForEach(row.keys, id: \.self) { keyCap($0) }
                        }
                        .gridColumnAlignment(.trailing)
                        Text(row.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: Theme.text))
                    }
                }
            }
        }
    }

    private func keyCap(_ k: String) -> some View {
        Text(k)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(nsColor: Theme.nord6))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: Theme.nord2).opacity(0.9))
            )
    }
}

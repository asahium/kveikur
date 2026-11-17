import KveikurCore
import SwiftUI

struct TransportBar: View {
    @ObservedObject var player: PlayerController
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            NowPlayingLabel(player: player).onTapGesture(perform: onReveal)
            HStack(spacing: 4) {
                iconButton("backward.fill", help: "Previous ([)") { player.previous() }
                iconButton(player.isPlaying ? "pause.fill" : "play.fill", help: "Play/Pause (c)", size: 20) { player.playPause() }
                iconButton("forward.fill", help: "Next (])") { player.next() }
            }
            PositionSlider(player: player, clock: player.clock)
            HStack(spacing: 6) {
                iconButton("shuffle", help: "Shuffle (S)", tint: player.shuffle) { player.shuffle.toggle() }
                iconButton(player.repeatMode == .one ? "repeat.1" : "repeat", help: "Repeat (r)", tint: player.repeatMode != .off) {
                    player.repeatMode = Self.nextRepeat(player.repeatMode)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary).frame(width: 18)
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)
            }
            DeviceMenu(player: player)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 56)
    }

    static func nextRepeat(_ m: RepeatMode) -> RepeatMode {
        switch m {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func iconButton(_ name: String, help: String, size: CGFloat = 14, tint: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size)).frame(width: 28, height: 28)
                .foregroundStyle(tint ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct NowPlayingLabel: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let img = player.artwork {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.displayTitle ?? player.currentURL?.lastPathComponent ?? "Not playing")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 230, alignment: .leading)
        .contentShape(Rectangle())
        .help("Reveal in browser (gr)")
    }
}

private struct PositionSlider: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.duration(dragging ?? clock.time)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { dragging ?? clock.time }, set: { dragging = $0 }),
                in: 0...max(clock.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let d = dragging {
                        player.seek(to: d)
                        dragging = nil
                    }
                }
            )
            .controlSize(.small)
            Text(Format.duration(clock.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .frame(minWidth: 200)
    }
}

private struct DeviceMenu: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        Menu {
            Button {
                player.selectDevice(uid: nil)
            } label: {
                if player.activeDeviceUID == nil { Image(systemName: "checkmark") }
                Text("System default")
            }
            Divider()
            ForEach(player.devices) { d in
                Button {
                    player.selectDevice(uid: d.uid)
                } label: {
                    if player.activeDeviceUID == d.uid { Image(systemName: "checkmark") }
                    Text(d.name)
                }
            }
            Divider()
            Toggle("Match sample rate", isOn: $player.matchSampleRate)
            Toggle("Exclusive mode (hog)", isOn: $player.exclusiveMode)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker")
                Text(player.signalPath.sourceRate > 0 ? player.signalPath.label : player.signalPath.deviceName)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(player.signalPath.bitPerfect ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Output device and signal path")
    }
}

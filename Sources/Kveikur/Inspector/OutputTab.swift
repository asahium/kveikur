import KveikurCore
import SwiftUI

struct OutputTab: View {
    @ObservedObject var player: PlayerController
    let metadata: MetadataStore
    @State private var container = ""
    @State private var preamp: Float?

    private var d: DeviceDetails { player.deviceDetails }
    private var path: SignalPath { player.signalPath }
    private var source: SourceFormat? { player.current?.format }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PanelSection(title: "Output device", help: "Core Audio device Kveikur renders to. The choice is remembered; Kveikur falls back to the system default when it disappears.") {
                    Picker("", selection: Binding(get: { player.activeDeviceUID ?? "" },
                                                  set: { player.selectDevice(uid: $0.isEmpty ? nil : $0) })) {
                        Text("System default").tag("")
                        ForEach(player.devices) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    KVRows(rows: [
                        ("Device", "\(d.name) — \(d.transport)"),
                        ("Channels", "\(d.channels)"),
                        ("Current SR", "\(SourceFormat.formatRate(d.sampleRate)) kHz"),
                        ("Max SR", d.supportedRates.last.map { "\(SourceFormat.formatRate($0)) kHz" } ?? "–"),
                        ("Max Bit Depth", d.maxBitDepth > 0 ? "\(d.maxBitDepth)-bit" : "–"),
                        ("Supported", d.supportedRates.map { SourceFormat.formatRate($0) }.joined(separator: ", ") + " kHz"),
                        ("HW volume", d.hasHardwareVolume ? "Available" : "None"),
                    ])
                    Toggle("Match sample rate to the file", isOn: $player.matchSampleRate)
                    Toggle("Exclusive mode (hog device)", isOn: $player.exclusiveMode)
                }
                PanelSection(title: "DSP", help: "ReplayGain levels tracks to −18 LUFS using tags, or an EBU R128 measurement for untagged files. A gain is fixed when a track starts, so changes apply from the next track or seek. Any DSP makes playback not bit-perfect.") {
                    Picker("ReplayGain", selection: $player.replayGain.mode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if player.replayGain.mode != .off {
                        HStack {
                            Text("Preamp").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { preamp ?? player.replayGain.preampDB }, set: { preamp = $0 }),
                                   in: -12...12, step: 0.5) { editing in
                                if !editing, let p = preamp {
                                    player.replayGain.preampDB = p
                                    preamp = nil
                                }
                            }
                            Text(String(format: "%+.1f dB", preamp ?? player.replayGain.preampDB))
                                .font(.system(size: 11, design: .monospaced)).frame(width: 64, alignment: .trailing)
                        }
                        Toggle("Prevent clipping (use peak)", isOn: $player.replayGain.preventClipping)
                        Toggle("Measure untagged files", isOn: $player.replayGain.analyzeUntagged)
                        KVRows(rows: [("This track", gainStatus)], mono: true)
                    }
                    HStack {
                        Toggle("Equalizer", isOn: $player.equalizer.enabled)
                        Spacer()
                        Text(player.equalizer.preset.name).foregroundStyle(.secondary)
                        Button("Edit…") { NSApp.sendAction(#selector(AppDelegate.showEqualizer), to: nil, from: nil) }
                    }
                }
                PanelSection(title: "Status", help: "Whether anything between the file and the device changes the samples.") {
                    if player.currentURL == nil {
                        Note(text: "Nothing playing.")
                    } else {
                        statusRows
                    }
                }
                if let m = player.current {
                    PanelSection(title: "Signal path · file") {
                        KVRows(rows: fileRows(m), mono: true)
                    }
                    PanelSection(title: "Decoder") {
                        KVRows(rows: [
                            ("Codec", m.format?.codec ?? "–"),
                            ("Output Format", "32-bit float"),
                            ("Sample Rate", "\(SourceFormat.formatRate(path.sourceRate > 0 ? path.sourceRate : m.format?.sampleRate ?? 0)) kHz"),
                            ("Channels", "\(path.sourceChannels > 0 ? path.sourceChannels : m.format?.channels ?? 0)"),
                            ("Interleaved", "No"),
                        ], mono: true)
                    }
                    PanelSection(title: "Processing") {
                        KVRows(rows: [
                            ("Volume", player.volume >= 1 ? "Unity (0.0 dB)" : String(format: "Software %.1f dB", 20 * log10(max(Double(player.volume), 0.0001)))),
                            ("DSP", dspDescription),
                            ("Resampler", path.resampling
                                ? "Core Audio \(SourceFormat.formatRate(path.sourceRate)) → \(SourceFormat.formatRate(path.deviceRate)) kHz"
                                : "Bypassed"),
                        ], mono: true)
                    }
                    PanelSection(title: "Output") {
                        KVRows(rows: [
                            ("Device", d.name),
                            ("Transport", d.transport),
                            ("Sample Rate", "\(SourceFormat.formatRate(path.deviceRate)) kHz"),
                            ("Stream Format", d.physicalBitDepth > 0 ? "\(d.physicalBitDepth)-bit" : "–"),
                            ("Exclusive", path.exclusive ? "Yes" : "No"),
                        ], mono: true)
                    }
                }
            }
        }
        .task(id: player.currentURL) {
            guard let u = player.currentURL else { container = ""; return }
            container = await Task.detached { ContainerSniffer.sniff(u).displayName }.value
        }
    }

    private enum Level { case ok, warn, neutral }

    @ViewBuilder
    private var statusRows: some View {
        let srcBits = source?.bitDepth ?? 0
        let bitsOK = srcBits == 0 || d.maxBitDepth == 0 || d.maxBitDepth >= srcBits
        let channelsOK = path.sourceChannels == 0 || path.sourceChannels == d.channels
        let volumeOK = player.volume >= 1
        let rows: [(String, String, Level)] = [
            ("Resampling", path.resampling ? "Yes" : "No", path.resampling ? .warn : .ok),
            ("Sample Rate Match", path.resampling ? "No (\(SourceFormat.formatRate(path.sourceRate)) → \(SourceFormat.formatRate(path.deviceRate)))" : "Yes",
             path.resampling ? .warn : .ok),
            ("Channel Mapping", channelsOK ? "Unchanged" : "\(path.sourceChannels) → \(d.channels) ch", channelsOK ? .ok : .warn),
            ("Bit Depth", srcBits == 0 ? "n/a (lossy source)" : (bitsOK ? "Preserved" : "Reduced to \(d.maxBitDepth)-bit"), bitsOK ? .ok : .warn),
            ("DSP", dspDescription, path.processing ? .warn : .ok),
            ("Volume", volumeOK ? "Unity" : "Software \(Int(player.volume * 100))%", volumeOK ? .ok : .warn),
            ("Exclusive", path.exclusive ? "Yes" : "No", .neutral),
        ]
        let intact = rows.allSatisfy { $0.2 != .warn }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    statusValue(rows[i].1, rows[i].2)
                }
            }
            GridRow {
                Text("Signal Integrity").foregroundStyle(.secondary)
                statusValue(intact ? "No Changes Detected" : "Altered", intact ? .ok : .warn, bold: true)
            }
        }
        .font(.system(size: 12))
    }

    private func statusValue(_ text: String, _ level: Level, bold: Bool = false) -> some View {
        HStack(spacing: 5) {
            switch level {
            case .ok: Image(systemName: bold ? "checkmark.seal.fill" : "checkmark.circle").foregroundStyle(.green)
            case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .neutral: Image(systemName: "lock.open").foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12, weight: bold ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(level == .ok ? Color.green : (level == .warn ? Color.orange : Color.primary))
        }
    }

    private var dspDescription: String {
        var parts: [String] = []
        if path.gainDB != 0 { parts.append(String(format: "ReplayGain %+.1f dB", path.gainDB)) }
        if path.equalizer { parts.append("EQ \(player.equalizer.preset.name)") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private var gainStatus: String {
        guard let u = player.currentURL else { return "–" }
        let applied = path.gainDB != 0 ? String(format: "%+.1f dB applied", path.gainDB) : "unity"
        guard let info = player.gains.info(for: u) else {
            return player.gains.isMeasuring ? "measuring…" : "no ReplayGain data (\(applied))"
        }
        let source = info.source == .tags ? "tags" : "measured"
        if let want = info.gainDB(player.replayGain), abs(want - path.gainDB) > 0.05 {
            return String(format: "%+.1f dB (%@), applies on next start", want, source)
        }
        return "\(applied) (\(source))"
    }

    private func fileRows(_ m: TrackMetadata) -> [(String, String)] {
        var r: [(String, String)] = []
        if !container.isEmpty { r.append(("Container", container)) }
        if let f = m.format {
            r.append(("Sample Rate", "\(SourceFormat.formatRate(f.sampleRate)) kHz"))
            r.append(("Bit Depth", f.bitDepth > 0 ? "\(f.bitDepth)-bit" : "n/a"))
            r.append(("Channels", f.channels == 2 ? "Stereo" : (f.channels == 1 ? "Mono" : "\(f.channels)")))
        }
        r.append(("Duration", Format.duration(m.duration)))
        if m.bitrate > 0 { r.append(("Bitrate", "\(m.bitrate) kbps")) }
        r.append(("File Size", Format.bytes(m.size)))
        r.append(("Path", m.path))
        return r
    }
}

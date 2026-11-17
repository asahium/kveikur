import KveikurCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: MobileModel
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Folders") {
                    ForEach(model.roots) { r in
                        Label(r.name, systemImage: r.isLocal ? "iphone" : "folder")
                            .swipeActions { if !r.isLocal { Button("Remove", role: .destructive) { model.removeRoot(r) } } }
                    }
                }
                .listRowBackground(Nord.raised)

                Section {
                    Picker("ReplayGain", selection: $player.replayGain.mode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if player.replayGain.mode != .off {
                        Stepper(String(format: "Preamp %+.1f dB", player.replayGain.preampDB),
                                value: $player.replayGain.preampDB, in: -12...12, step: 0.5)
                        Toggle("Prevent clipping", isOn: $player.replayGain.preventClipping)
                        Toggle("Measure untagged files", isOn: $player.replayGain.analyzeUntagged)
                    }
                    NavigationLink("Equalizer — \(player.equalizer.enabled ? player.equalizer.preset.name : "Off")") {
                        MobileEqualizer()
                    }
                    Toggle("Match sample rate to the file", isOn: $player.matchSampleRate)
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Sample-rate matching asks iOS for the file's rate; USB DACs follow it, the built-in output and Bluetooth may not.")
                }
                .listRowBackground(Nord.raised)

                Section("Lyrics") {
                    Toggle("Search LRCLIB automatically", isOn: $model.lyricsAutoFetch)
                }
                .listRowBackground(Nord.raised)

                ScrobbleSection(s: model.scrobbler)

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
                .listRowBackground(Nord.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Nord.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ScrobbleSection: View {
    @ObservedObject var s: ScrobbleController

    var body: some View {
        Section {
            if !s.listenbrainzUser.isEmpty {
                Toggle("ListenBrainz · \(s.listenbrainzUser)", isOn: $s.listenbrainzEnabled)
                Button("Disconnect ListenBrainz", role: .destructive) { s.disconnectListenBrainz() }
            } else {
                SecureField("ListenBrainz token", text: $s.listenbrainzToken)
                Button("Connect ListenBrainz") { s.connectListenBrainz() }
            }
            if s.lastfmConnected {
                Toggle("Last.fm · \(s.lastfmUser)", isOn: $s.lastfmEnabled)
                Button("Disconnect Last.fm", role: .destructive) { s.disconnectLastFM() }
            } else {
                TextField("Last.fm API key", text: $s.lastfmKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Last.fm shared secret", text: $s.lastfmSecret)
                Button(s.lastfmConnecting ? "Waiting for approval…" : "Connect Last.fm") { s.connectLastFM() }
                    .disabled(s.lastfmConnecting)
            }
        } header: {
            Text("Scrobbling")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !s.status.isEmpty { Text(s.status) }
                if s.pending > 0 { Text("\(s.pending) plays waiting to be sent") }
                Text("Last.fm opens Safari for approval; come back to Kveikur within two minutes.")
            }
        }
        .listRowBackground(Nord.raised)
    }
}

private struct MobileEqualizer: View {
    @EnvironmentObject var player: PlayerController

    private var preset: EQPreset { player.equalizer.preset }

    var body: some View {
        Form {
            Section {
                Toggle("Equalizer", isOn: $player.equalizer.enabled)
                Picker("Preset", selection: Binding(get: { preset.name }, set: { name in
                    if let p = (EQPreset.builtIn + player.customPresets).first(where: { $0.name == name }) {
                        player.equalizer.preset = p
                        if p != .flat { player.equalizer.enabled = true }
                    }
                })) {
                    ForEach(EQPreset.builtIn) { Text($0.name).tag($0.name) }
                    ForEach(player.customPresets) { Text($0.name).tag($0.name) }
                    if !(EQPreset.builtIn + player.customPresets).contains(where: { $0.name == preset.name }) {
                        Text(preset.name).tag(preset.name)
                    }
                }
            }
            .listRowBackground(Nord.raised)

            Section {
                band("Preamp", value: preset.preamp) { v in edit { $0.preamp = v } }
                if preset.isGraphic {
                    ForEach(preset.bands.indices, id: \.self) { i in
                        band(label(preset.bands[i].frequency), value: preset.bands[i].gain) { v in edit { $0.bands[i].gain = v } }
                    }
                }
            } footer: {
                Text(preset.isGraphic ? "Ten bands, ±12 dB." : "Parametric profile with \(preset.bands.count) filters; only the preamp is editable.")
            }
            .listRowBackground(Nord.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Nord.background)
        .navigationTitle("Equalizer")
    }

    private func band(_ title: String, value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(title).font(.caption.monospaced()).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 * 2).rounded() / 2) }), in: -12...12)
            Text(String(format: "%+.1f", value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    private func edit(_ change: (inout EQPreset) -> Void) {
        var p = player.equalizer.preset
        change(&p)
        if EQPreset.builtIn.contains(where: { $0.name == p.name }) { p.name = "Custom" }
        player.equalizer.preset = p
        player.equalizer.enabled = true
    }

    private func label(_ f: Float) -> String {
        f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz"
    }
}

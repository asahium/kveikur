import KveikurCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var player: PlayerController

    var body: some View {
        Form {
            Section("Library folders") {
                ForEach(app.roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { app.removeRoot(root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…") { app.chooseFolder(title: "Add music folder") { app.addRoot($0) } }
                    Button("Rescan") { app.rescan() }
                    Spacer()
                    Text(app.scanStatus).foregroundStyle(.secondary).font(.caption)
                }
            }
            Section("Output") {
                Picker("Device", selection: Binding(get: { player.activeDeviceUID ?? "" },
                                                   set: { player.selectDevice(uid: $0.isEmpty ? nil : $0) })) {
                    Text("System default").tag("")
                    ForEach(player.devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("Match device sample rate to the file", isOn: $player.matchSampleRate)
                Toggle("Exclusive mode (hog the device while playing)", isOn: $player.exclusiveMode)
            }
            Section("Sound") {
                Picker("ReplayGain", selection: $player.replayGain.mode) {
                    ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Prevent clipping", isOn: $player.replayGain.preventClipping)
                Toggle("Measure loudness of untagged files (EBU R128)", isOn: $player.replayGain.analyzeUntagged)
                HStack {
                    Toggle("Equalizer", isOn: $player.equalizer.enabled)
                    Spacer()
                    Button("Open Equalizer…") { NSApp.sendAction(#selector(AppDelegate.showEqualizer), to: nil, from: nil) }
                }
            }
            Section("Browser") {
                Toggle("Show tag titles instead of file names", isOn: $app.showTagTitles)
            }
            Section("Lyrics") {
                Toggle("Search online automatically when no local lyrics", isOn: $app.lyricsAutoFetch)
                Toggle("Save .lrc next to the track", isOn: $app.saveLyricsSidecar)
                SecureField("Genius API token (optional)", text: $app.geniusToken)
                Text("LRCLIB provides synced lyrics without a key. Genius adds plain lyrics when a token is set (genius.com/api-clients).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrobbleSettings(s: app.scrobbler)
            UpdateSettings(u: app.updater)
            Section("Playlists") {
                HStack {
                    Text(app.playlistsFolder.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { app.chooseFolder(title: "Playlists folder") { app.playlistsFolder = $0 } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 760)
    }
}

private struct UpdateSettings: View {
    @ObservedObject var u: Updater

    var body: some View {
        Section("Updates") {
            Toggle("Check for new releases daily", isOn: $u.automatic)
            SecureField("GitHub token (needed while the repository is private)", text: $u.token)
            HStack {
                Text(u.status.isEmpty ? "Version \(Updater.currentVersion)" : u.status)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { u.check(interactive: true) }.disabled(u.checking)
            }
        }
    }
}

private struct ScrobbleSettings: View {
    @ObservedObject var s: ScrobbleController

    var body: some View {
        Section("Scrobbling") {
            if s.lastfmConnected {
                HStack {
                    Toggle("Last.fm", isOn: $s.lastfmEnabled)
                    Spacer()
                    Text(s.lastfmUser).foregroundStyle(.secondary)
                    Button("Disconnect") { s.disconnectLastFM() }
                }
            } else {
                TextField("Last.fm API key", text: $s.lastfmKey)
                SecureField("Last.fm shared secret", text: $s.lastfmSecret)
                HStack {
                    Text("Create an API account at last.fm/api/account/create, then connect.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(s.lastfmConnecting ? "Waiting…" : "Connect Last.fm") { s.connectLastFM() }
                        .disabled(s.lastfmConnecting)
                }
            }
            if !s.listenbrainzUser.isEmpty {
                HStack {
                    Toggle("ListenBrainz", isOn: $s.listenbrainzEnabled)
                    Spacer()
                    Text(s.listenbrainzUser).foregroundStyle(.secondary)
                    Button("Disconnect") { s.disconnectListenBrainz() }
                }
            } else {
                HStack {
                    SecureField("ListenBrainz user token", text: $s.listenbrainzToken)
                    Button("Connect") { s.connectListenBrainz() }
                }
                Text("Token from listenbrainz.org/settings.").font(.caption).foregroundStyle(.secondary)
            }
            if !s.status.isEmpty || s.pending > 0 {
                HStack {
                    Text(s.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if s.pending > 0 {
                        Text("\(s.pending) waiting").font(.caption)
                        Button("Retry") { s.flush() }
                    }
                }
            }
            Text("A play counts after half the track or 4 minutes of actual listening; tracks under 30 s and files without artist and title tags are skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

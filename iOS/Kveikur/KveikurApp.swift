import KveikurCore
import SwiftUI

@main
struct KveikurApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
                .preferredColorScheme(.dark)
                .tint(Nord.accent)
        }
        .onChange(of: phase) { _, p in
            if p != .active { model.save() }
            model.player.clockSuspended = p == .background
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: MobileModel
    @EnvironmentObject var player: PlayerController
    @State private var showPlayer = false
    @State private var showSettings = false
    @State private var showStats = false
    @State private var picking = false
    @State private var path: [URL] = []
    @State private var playerTab: NowPlayingView.Tab = .playing

    var body: some View {
        VStack(spacing: 0) {
            library
            MiniPlayer { showPlayer = true }
        }
        .background(Nord.bar.ignoresSafeArea(edges: .bottom))
    }

    private var library: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(model.roots) { root in
                        NavigationLink(value: root.url) {
                            Label(root.name, systemImage: root.isLocal ? "iphone" : "folder")
                                .foregroundStyle(Nord.folder)
                        }
                        .listRowBackground(Nord.background)
                        .swipeActions {
                            if !root.isLocal {
                                Button("Remove", role: .destructive) { model.removeRoot(root) }
                            }
                        }
                    }
                } footer: {
                    Text("Copy music to Files › On My iPhone › Kveikur, or add any folder from Files, iCloud Drive or an external drive.")
                        .foregroundStyle(Nord.secondary)
                }
                Section {
                    Button { picking = true } label: { Label("Add Folder…", systemImage: "plus") }
                        .listRowBackground(Nord.background)
                }
            }
            .nordList()
            .navigationTitle("Library")
            .navigationDestination(for: URL.self) { FolderView(folder: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showStats = true } label: { Image(systemName: "chart.bar") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addRoot(url) }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView(tab: playerTab)
                .environmentObject(model)
                .environmentObject(player)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showStats) {
            StatsView(scrobbler: model.scrobbler).environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(player)
        }
        .overlay(alignment: .top) {
            if let m = model.message {
                Text(m)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Nord.n2, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: m) {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation { model.message = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: model.message)
        .task { debugLaunch() }
    }

    /// KVEIKUR_OPEN=relative/path (from Documents), KVEIKUR_PLAY=1, KVEIKUR_SHEET=playing|lyrics|queue|info|settings.
    private func debugLaunch() {
        let env = ProcessInfo.processInfo.environment
        if let rel = env["KVEIKUR_OPEN"] {
            var u = MobileModel.documents
            path = rel.split(separator: "/").map { u.appendPathComponent(String($0)); return u }
            if env["KVEIKUR_PLAY"] != nil, let last = path.last { model.playFolder(last, shuffle: false) }
        }
        if let sheet = env["KVEIKUR_SHEET"] {
            if sheet == "settings" {
                showSettings = true
            } else if let t = NowPlayingView.Tab(rawValue: sheet.capitalized) {
                playerTab = t
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showPlayer = true
                }
            }
        }
    }
}

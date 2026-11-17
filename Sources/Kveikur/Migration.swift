import Foundation

/// One-time move of settings and data from the app's former name (Riff, `dev.riff.player`).
enum LegacyMigration {
    private static let doneKey = "migratedFromRiff"
    private static let oldDomain = "dev.riff.player"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldPlaylists = home.appendingPathComponent("Music/Riff Playlists")
        let newPlaylists = home.appendingPathComponent("Music/Kveikur Playlists")

        if let old = d.persistentDomain(forName: oldDomain) {
            for (key, value) in old where d.object(forKey: key) == nil {
                let renamed = key.replacingOccurrences(of: "RiffMain", with: "KveikurMain")
                guard !key.hasPrefix("NSSplitView") else { continue }
                d.set(value, forKey: renamed)
            }
            if d.string(forKey: "playlistsFolder") == oldPlaylists.path {
                d.set(newPlaylists.path, forKey: "playlistsFolder")
            }
        }

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for (from, to) in [
            (support.appendingPathComponent("Riff"), support.appendingPathComponent("Kveikur")),
            (caches.appendingPathComponent("Riff"), caches.appendingPathComponent("Kveikur")),
            (oldPlaylists, newPlaylists),
        ] where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.moveItem(at: from, to: to)
        }
    }
}

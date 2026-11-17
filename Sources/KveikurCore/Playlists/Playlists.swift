import Foundation

public struct PlaylistEntry: Hashable, Sendable {
    public var url: URL
    public var title: String?
    public var duration: Int?

    public init(url: URL, title: String? = nil, duration: Int? = nil) {
        self.url = url
        self.title = title
        self.duration = duration
    }
}

public enum M3U8 {
    public static func parse(_ text: String, relativeTo base: URL) -> [PlaylistEntry] {
        var out: [PlaylistEntry] = []
        var pendingTitle: String?
        var pendingDuration: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "#EXTM3U" { continue }
            if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst(8)
                let parts = body.split(separator: ",", maxSplits: 1)
                pendingDuration = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                pendingTitle = parts.count > 1 ? String(parts[1]) : nil
                continue
            }
            if line.hasPrefix("#") { continue }
            let url: URL
            if line.hasPrefix("file://"), let u = URL(string: line) {
                url = u
            } else if line.hasPrefix("/") {
                url = URL(fileURLWithPath: line)
            } else {
                url = base.appendingPathComponent(line).standardizedFileURL
            }
            out.append(PlaylistEntry(url: url, title: pendingTitle, duration: pendingDuration))
            pendingTitle = nil
            pendingDuration = nil
        }
        return out
    }

    public static func serialize(_ entries: [PlaylistEntry], relativeTo base: URL) -> String {
        var lines = ["#EXTM3U"]
        let basePath = base.standardizedFileURL.path + "/"
        for e in entries {
            lines.append("#EXTINF:\(e.duration ?? -1),\(e.title ?? e.url.deletingPathExtension().lastPathComponent)")
            let p = e.url.standardizedFileURL.path
            lines.append(p.hasPrefix(basePath) ? String(p.dropFirst(basePath.count)) : p)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Playlists are plain .m3u8 files in one folder.
public final class PlaylistStore: @unchecked Sendable {
    public var folder: URL {
        didSet { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    public static func defaultFolder() -> URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Kveikur Playlists", isDirectory: true)
    }

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func playlists() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)) ?? []
        return urls.filter(AudioFiles.isPlaylist).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    public func entries(_ playlist: URL) -> [PlaylistEntry] {
        guard let text = (try? String(contentsOf: playlist, encoding: .utf8))
            ?? (try? String(contentsOf: playlist, encoding: .isoLatin1)) else { return [] }
        return M3U8.parse(text, relativeTo: playlist.deletingLastPathComponent())
    }

    public func write(_ entries: [PlaylistEntry], to playlist: URL) throws {
        try M3U8.serialize(entries, relativeTo: playlist.deletingLastPathComponent())
            .write(to: playlist, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func create(named name: String, with entries: [PlaylistEntry] = []) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = folder.appendingPathComponent(safe.isEmpty ? "Untitled" : safe).appendingPathExtension("m3u8")
        try write(entries, to: url)
        return url
    }

    /// Rewrites entries that point at renamed files or folders; returns the playlists that changed.
    @discardableResult
    public func followMoves(_ moves: [(URL, URL)]) -> [URL] {
        var changed: [URL] = []
        for p in playlists() {
            var e = entries(p)
            var dirty = false
            for i in e.indices {
                if let u = FileOperations.remap(e[i].url, moves) { e[i].url = u; dirty = true }
            }
            if dirty, (try? write(e, to: p)) != nil { changed.append(p) }
        }
        return changed
    }

    public func append(_ new: [PlaylistEntry], to playlist: URL) throws {
        try write(entries(playlist) + new, to: playlist)
    }

    public func remove(at offsets: IndexSet, from playlist: URL) throws {
        var e = entries(playlist)
        for i in offsets.sorted(by: >) where i < e.count { e.remove(at: i) }
        try write(e, to: playlist)
    }

    public func move(from: Int, to: Int, in playlist: URL) throws {
        var e = entries(playlist)
        guard from >= 0, from < e.count, to >= 0, to < e.count, from != to else { return }
        let item = e.remove(at: from)
        e.insert(item, at: to)
        try write(e, to: playlist)
    }
}

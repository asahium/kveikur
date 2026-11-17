import Foundation

/// One copy of a duplicated album (a folder) or track (a file).
public struct DuplicateVersion: Sendable, Identifiable, Hashable {
    public var id: String { path }
    /// Folder for album groups, file for track groups.
    public var path: String
    public var tracks: [TrackMetadata]
    public var isBest = false

    public var format: SourceFormat? { tracks.compactMap(\.format).max { DuplicateFinder.rank($0, 0) < DuplicateFinder.rank($1, 0) } }
    /// Cue tracks of one image share its size; count each audio file once.
    public var bytes: Int64 {
        var files: [String: Int64] = [:]
        for t in tracks { files[CueTrackRef.audioFile(t.url).path] = t.size }
        return files.values.reduce(0, +)
    }
    public var bitrate: Int { tracks.isEmpty ? 0 : tracks.map(\.bitrate).reduce(0, +) / tracks.count }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable { case album, track }
    public var id: String { versions.map(\.path).joined(separator: "|") }
    public var kind: Kind
    public var title: String
    public var artist: String?
    public var versions: [DuplicateVersion]
    /// Bytes held by every version except the best one.
    public var reclaimable: Int64 { versions.filter { !$0.isBest }.reduce(0) { $0 + $1.bytes } }
}

/// Finds the same album or track stored more than once (e.g. FLAC and MP3 rips, or two copies of a folder).
public enum DuplicateFinder {
    /// Folders sharing at least this share of the smaller folder's tracks are versions of one album.
    static let albumOverlap = 0.6
    /// …and at least half of the larger one, so a single or a best-of doesn't pull in whole albums.
    static let supersetOverlap = 0.5
    static let durationTolerance: TimeInterval = 3

    public static func find(_ tracks: [TrackMetadata]) -> [DuplicateGroup] {
        let clusters = cluster(tracks.filter { $0.duration > 0 })

        var folderTracks: [String: [TrackMetadata]] = [:]
        for t in tracks { folderTracks[folder(t), default: []].append(t) }
        var shared: [Pair: Int] = [:]
        for c in clusters {
            let folders = Array(Set(c.map(folder))).sorted()
            guard folders.count > 1 else { continue }
            for i in 0..<folders.count {
                for j in i + 1..<folders.count { shared[Pair(folders[i], folders[j]), default: 0] += 1 }
            }
        }

        var uf = UnionFind()
        for (p, n) in shared {
            let a = folderTracks[p.a]?.count ?? 0, b = folderTracks[p.b]?.count ?? 0
            if n >= 2, Double(n) >= albumOverlap * Double(min(a, b)), Double(n) >= supersetOverlap * Double(max(a, b)) {
                uf.union(p.a, p.b)
            }
        }

        var groups: [DuplicateGroup] = []
        var albumFolders = Set<String>()
        for members in uf.sets() where members.count > 1 {
            albumFolders.formUnion(members)
            var versions = members.sorted().map { DuplicateVersion(path: $0, tracks: folderTracks[$0] ?? []) }
            markBest(&versions)
            let sample = versions.flatMap(\.tracks)
            let album = mostCommon(sample.compactMap(\.album)) ?? (members.first.map { ($0 as NSString).lastPathComponent } ?? "")
            groups.append(DuplicateGroup(kind: .album, title: album,
                                         artist: mostCommon(sample.compactMap { $0.albumArtist ?? $0.artist }), versions: versions))
        }

        for c in clusters {
            let outside = c.filter { !albumFolders.contains(folder($0)) }
            guard outside.count > 1, Set(outside.map(\.path)).count > 1 else { continue }
            var versions = outside.sorted { $0.path < $1.path }.map { DuplicateVersion(path: $0.path, tracks: [$0]) }
            markBest(&versions)
            groups.append(DuplicateGroup(kind: .track, title: outside[0].displayTitle, artist: outside[0].artist, versions: versions))
        }
        return groups.sorted { ($0.reclaimable, $0.title) > ($1.reclaimable, $1.title) }
    }

    // MARK: Matching

    static func folder(_ t: TrackMetadata) -> String { (t.path as NSString).deletingLastPathComponent }

    /// "Artist|title" from tags, or the file name without its track number when untagged.
    static func key(_ t: TrackMetadata) -> String {
        if let title = t.title, !title.isEmpty {
            return normalize(t.artist ?? t.albumArtist ?? "") + "|" + normalize(title)
        }
        let base = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let stripped = base.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-_.)\s]\s*"#, with: "", options: .regularExpression)
        return "|" + normalize(stripped)
    }

    /// Case, accents, punctuation and "(Remastered)"-style suffixes don't distinguish recordings here.
    static func normalize(_ s: String) -> String {
        let noBrackets = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(remaster|deluxe|version|edition|bonus)[^\)\]]*[\)\]]"#,
                                                with: "", options: [.regularExpression, .caseInsensitive])
        let folded = noBrackets.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Same key and durations within the tolerance.
    static func cluster(_ tracks: [TrackMetadata]) -> [[TrackMetadata]] {
        var out: [[TrackMetadata]] = []
        for (k, list) in Dictionary(grouping: tracks, by: key) where list.count > 1 && k != "|" {
            var current: [TrackMetadata] = []
            for t in list.sorted(by: { $0.duration < $1.duration }) {
                if let last = current.last, t.duration - last.duration > durationTolerance {
                    if current.count > 1 { out.append(current) }
                    current = []
                }
                current.append(t)
            }
            if current.count > 1 { out.append(current) }
        }
        return out
    }

    // MARK: Quality

    /// Lossless beats lossy, then bit depth and sample rate; bitrate only separates lossy files
    /// (a FLAC's bitrate says how well it compressed, not how good it is).
    static func rank(_ f: SourceFormat, _ bitrate: Int) -> Double {
        (f.lossless ? 1e9 : Double(bitrate)) + Double(f.bitDepth) * 1e6 + f.sampleRate
    }

    /// Equal quality: the most complete edition wins.
    static func markBest(_ versions: inout [DuplicateVersion]) {
        let scores = versions.map { v in (v.format.map { rank($0, v.bitrate) } ?? 0, v.tracks.count) }
        if let i = scores.indices.max(by: { scores[$0] < scores[$1] }) { versions[i].isBest = true }
    }

    static func mostCommon(_ values: [String]) -> String? {
        Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    struct Pair: Hashable {
        let a: String, b: String
        init(_ a: String, _ b: String) { self.a = a; self.b = b }
    }

    struct UnionFind {
        var parent: [String: String] = [:]

        mutating func find(_ x: String) -> String {
            let p = parent[x] ?? x
            if p == x { parent[x] = x; return x }
            let r = find(p)
            parent[x] = r
            return r
        }

        mutating func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        mutating func sets() -> [Set<String>] {
            var out: [String: Set<String>] = [:]
            for k in Array(parent.keys) { out[find(k), default: []].insert(k) }
            return Array(out.values)
        }
    }
}

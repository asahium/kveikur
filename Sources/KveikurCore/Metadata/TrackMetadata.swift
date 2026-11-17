import Foundation

public struct TrackMetadata: Hashable, Codable, Sendable {
    public var path: String
    public var mtime: Double
    public var size: Int64
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var year: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var duration: Double
    public var format: SourceFormat?
    public var bitrate: Int

    public init(path: String, mtime: Double, size: Int64) {
        self.path = path
        self.mtime = mtime
        self.size = size
        duration = 0
        bitrate = 0
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var displayTitle: String { title ?? ((fileName as NSString).deletingPathExtension) }
}

/// Raw tag bag with normalized keys, shared by all tag parsers.
struct TagBag {
    var values: [String: String] = [:]
    var lyrics: String?
    var picture: Data?

    mutating func set(_ key: String, _ value: String?) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        if values[key] == nil { values[key] = v }
    }

    func apply(to m: inout TrackMetadata) {
        m.title = values["title"] ?? m.title
        m.artist = values["artist"] ?? m.artist
        m.album = values["album"] ?? m.album
        m.albumArtist = values["albumartist"] ?? m.albumArtist
        m.genre = values["genre"] ?? m.genre
        m.composer = values["composer"] ?? m.composer
        if let y = values["date"] ?? values["year"] { m.year = String(y.prefix(4)) }
        if let t = values["tracknumber"] {
            let (n, total) = TagBag.parsePair(t)
            m.trackNumber = n ?? m.trackNumber
            m.trackTotal = total ?? m.trackTotal
        }
        if let t = values["tracktotal"] ?? values["totaltracks"] { m.trackTotal = Int(t) ?? m.trackTotal }
        if let d = values["discnumber"] {
            let (n, total) = TagBag.parsePair(d)
            m.discNumber = n ?? m.discNumber
            m.discTotal = total ?? m.discTotal
        }
        if let t = values["disctotal"] ?? values["totaldiscs"] { m.discTotal = Int(t) ?? m.discTotal }
    }

    /// "3/10" -> (3, 10)
    static func parsePair(_ s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first.flatMap { Int($0) }, parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// Vorbis comment field names mapped onto TagBag keys.
    static func vorbisKey(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": return "albumartist"
        case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS": return "lyrics"
        default: return raw.lowercased()
        }
    }
}

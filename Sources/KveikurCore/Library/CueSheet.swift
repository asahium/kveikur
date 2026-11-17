import Foundation

/// A cue sheet that splits one or more audio files ("images") into tracks.
public struct CueSheet: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        public var number: Int
        public var title: String?
        public var performer: String?
        public var songwriter: String?
        public var isrc: String?
        /// Audio file this track lives in (resolved on disk) and its INDEX 01 / next track boundaries in seconds.
        public var file: URL
        public var start: TimeInterval
        public var end: TimeInterval?
    }

    public var url: URL
    public var title: String?
    public var performer: String?
    public var genre: String?
    public var date: String?
    public var disc: Int?
    public var discTotal: Int?
    public var tracks: [Track]

    /// Audio files that are split by this sheet (files with a single track at 0:00 are left alone).
    public var splitFiles: [URL] {
        var seen: [URL] = []
        for t in tracks where !seen.contains(t.file) { seen.append(t.file) }
        return seen
    }

    // MARK: Parsing

    public static func load(_ url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20 else { return nil }
        return parse(decode(data), at: url)
    }

    /// UTF-8 (with or without BOM), UTF-16, then the legacy encodings rippers commonly used.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        // Single-byte code pages decode anything, so each must also look like its script.
        func count(_ s: String?, _ ranges: [ClosedRange<UInt32>]) -> Int {
            s?.unicodeScalars.filter { u in ranges.contains { $0.contains(u.value) } }.count ?? 0
        }
        let cp1251 = String(data: data, encoding: .windowsCP1251)
        if count(cp1251, [0x410...0x44F]) > 3 { return cp1251! }
        let sjis = String(data: data, encoding: .shiftJIS)
        if count(sjis, [0x3040...0x30FF, 0x4E00...0x9FFF]) > 3 { return sjis! }
        return String(data: data, encoding: .windowsCP1252) ?? cp1251 ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String, at url: URL) -> CueSheet? {
        struct Raw { var number: Int; var file: String; var title, performer, songwriter, isrc: String?; var index: TimeInterval? }
        var sheet = CueSheet(url: url, tracks: [])
        var raws: [Raw] = []
        var file: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let words = tokens(String(line))
            guard let cmd = words.first?.uppercased() else { continue }
            let arg = words.count > 1 ? words[1] : nil
            switch cmd {
            case "FILE":
                file = arg
            case "TRACK":
                guard let f = file, let n = arg.flatMap({ Int($0) }) else { continue }
                let audio = words.count > 2 ? words[2].uppercased() == "AUDIO" : true
                if audio { raws.append(Raw(number: n, file: f)) }
            case "TITLE":
                if raws.isEmpty { sheet.title = arg } else { raws[raws.count - 1].title = arg }
            case "PERFORMER":
                if raws.isEmpty { sheet.performer = arg } else { raws[raws.count - 1].performer = arg }
            case "SONGWRITER":
                if !raws.isEmpty { raws[raws.count - 1].songwriter = arg }
            case "ISRC":
                if !raws.isEmpty { raws[raws.count - 1].isrc = arg }
            case "INDEX":
                guard !raws.isEmpty, words.count > 2, Int(words[1]) == 1, let t = time(words[2]) else { continue }
                if raws[raws.count - 1].file == file { raws[raws.count - 1].index = t }
            case "REM":
                guard raws.isEmpty, let key = arg?.uppercased(), words.count > 2 else { continue }
                let value = words[2...].joined(separator: " ")
                switch key {
                case "GENRE": sheet.genre = value
                case "DATE": sheet.date = String(value.prefix(4))
                case "DISCNUMBER": sheet.disc = Int(value)
                case "TOTALDISCS": sheet.discTotal = Int(value)
                default: break
                }
            default:
                continue
            }
        }

        let byFile = Dictionary(grouping: raws.filter { $0.index != nil }, by: \.file)
        var resolved: [String: URL] = [:]
        for (name, list) in byFile {
            guard list.count > 1 || (list.first?.index ?? 0) > 0,
                  let u = resolve(name, sheet: url, onlyFile: byFile.count == 1) else { continue }
            resolved[name] = u
        }
        for (i, r) in raws.enumerated() {
            guard let f = resolved[r.file], let start = r.index else { continue }
            let next = raws[(i + 1)...].first { $0.file == r.file && $0.index != nil }
            sheet.tracks.append(Track(number: r.number, title: r.title, performer: r.performer, songwriter: r.songwriter,
                                      isrc: r.isrc, file: f, start: start, end: next?.index))
        }
        return sheet.tracks.isEmpty ? nil : sheet
    }

    /// Splits a cue line into words, keeping "quoted strings" whole.
    static func tokens(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var started = false
        for ch in line {
            if ch == "\"" {
                if quoted { out.append(cur); cur = ""; started = false }
                quoted.toggle()
            } else if ch.isWhitespace, !quoted {
                if started { out.append(cur); cur = ""; started = false }
            } else {
                cur.append(ch)
                started = true
            }
        }
        if started || quoted { out.append(cur) }
        return out
    }

    /// "mm:ss:ff" with 75 frames per second.
    static func time(_ s: String) -> TimeInterval? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Double(p[0]) * 60 + Double(p[1]) + Double(p[2]) / 75
    }

    /// The file as named; else one with the same base name ignoring case, accents and extension (rippers leave
    /// "image.wav" next to "image.flac", or strip "ó" to "o"); else the audio file named like the sheet;
    /// else, for single-image sheets, the only audio file in the folder.
    static func resolve(_ name: String, sheet: URL, onlyFile: Bool) -> URL? {
        let fm = FileManager.default
        let dir = sheet.deletingLastPathComponent()
        let direct = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path), AudioFiles.isAudio(direct) { return direct }
        func key(_ s: String) -> String {
            (s as NSString).deletingPathExtension.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let audio = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .map { dir.appendingPathComponent($0) }
            .filter(AudioFiles.isAudio)
        if let u = audio.first(where: { key($0.lastPathComponent) == key(name) }) { return u }
        let sheetBase = key(sheet.deletingPathExtension().lastPathComponent)
        if let u = audio.first(where: { key($0.lastPathComponent) == sheetBase }) { return u }
        if let u = audio.first(where: { key($0.lastPathComponent) == key(sheet.deletingPathExtension().deletingPathExtension().lastPathComponent) }) { return u }
        return onlyFile && audio.count == 1 ? audio[0] : nil
    }
}

/// Cue tracks travel through the queue, index and caches as "<sheet>.cue/<NN>" paths.
public enum CueTrackRef {
    public static func url(_ sheet: URL, _ number: Int) -> URL {
        sheet.appendingPathComponent(String(format: "%02d", number), isDirectory: false)
    }

    public static func isCue(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathExtension.lowercased() == "cue" && Int(url.lastPathComponent) != nil
    }

    private static let cache = CueCache()

    public static func resolve(_ url: URL) -> (sheet: CueSheet, track: CueSheet.Track)? {
        guard isCue(url), let n = Int(url.lastPathComponent),
              let sheet = cache.sheet(url.deletingLastPathComponent()),
              let t = sheet.tracks.first(where: { $0.number == n }) else { return nil }
        return (sheet, t)
    }

    /// The file on disk that holds the audio: the image for cue tracks, the URL itself otherwise.
    public static func audioFile(_ url: URL) -> URL {
        resolve(url)?.track.file ?? url
    }

    public static func exists(_ url: URL) -> Bool {
        isCue(url) ? resolve(url) != nil : FileManager.default.fileExists(atPath: url.path)
    }

    public static func sheet(_ url: URL) -> CueSheet? { cache.sheet(url) }
}

/// How folders with cue sheets are presented: images that a sheet splits are replaced by its tracks.
/// One sheet in a folder is shown inline; several (multi-disc sets) become one container per sheet.
public enum CueFolders {
    public static func isSheet(_ url: URL) -> Bool { url.pathExtension.lowercased() == "cue" }

    /// Sheets among `items` that actually split something.
    public static func sheets(_ items: [URL]) -> [CueSheet] {
        items.filter(isSheet).compactMap(CueTrackRef.sheet)
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    public static func sheets(in dir: URL) -> [CueSheet] {
        sheets((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    }

    public static func trackURLs(_ sheet: CueSheet) -> [URL] {
        sheet.tracks.map { CueTrackRef.url(sheet.url, $0.number) }
    }

    /// Audio files of a walk with split images swapped for their cue tracks, in path order.
    public static func expand(audio: [URL], cues: [URL]) -> [URL] {
        let all = sheets(cues)
        let hidden = Set(all.flatMap { $0.splitFiles.map(\.path.pathKey) })
        let kept = audio.filter { !hidden.contains($0.path.pathKey) }
        return (kept + all.flatMap(trackURLs)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Where a cue track is listed: its folder when the sheet is shown inline, else the sheet itself.
    public static func listing(of track: URL) -> URL {
        let sheet = track.deletingLastPathComponent()
        let dir = sheet.deletingLastPathComponent()
        return sheets(in: dir).count == 1 ? dir : sheet
    }
}

/// Parsed sheets keyed by path, revalidated by modification date.
final class CueCache: @unchecked Sendable {
    private let lock = NSLock()
    private var sheets: [String: (Date, CueSheet?)] = [:]

    func sheet(_ url: URL) -> CueSheet? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        guard let mtime else { return nil }
        lock.lock()
        if let hit = sheets[url.path.pathKey], hit.0 == mtime { lock.unlock(); return hit.1 }
        lock.unlock()
        let s = CueSheet.load(url)
        lock.lock()
        sheets[url.path.pathKey] = (mtime, s)
        lock.unlock()
        return s
    }
}

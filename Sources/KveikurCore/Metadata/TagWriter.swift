import AVFoundation
import Foundation

public enum TagField: String, CaseIterable, Sendable {
    case title, artist, album, albumArtist, genre, composer, year, track, trackTotal, disc, discTotal
}

/// Changed fields only; an empty string removes the tag.
public struct TagEdit: Sendable, Equatable {
    public var values: [TagField: String] = [:]

    public init(_ values: [TagField: String] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    public subscript(_ f: TagField) -> String? {
        get { values[f] }
        set { values[f] = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Track and disc numbers are stored as one "n/total" value in ID3, so they travel together.
    func pair(_ number: TagField, _ total: TagField) -> String? {
        guard values[number] != nil || values[total] != nil else { return nil }
        let n = values[number] ?? ""
        let t = values[total] ?? ""
        if n.isEmpty { return "" }
        return t.isEmpty ? n : "\(n)/\(t)"
    }
}

public enum TagWriteError: LocalizedError {
    case unsupported(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Can't write tags: \(s)"
        case .corrupt(let s): return "Can't write tags: \(s)"
        }
    }
}

public enum TagWriter {
    public static func canWrite(_ url: URL) -> Bool {
        guard !CueTrackRef.isCue(url) else { return false }
        switch ContainerSniffer.sniff(url) {
        case .flac, .mp3, .mp4: return true
        default: return false
        }
    }

    public static func write(_ edit: TagEdit, to url: URL) async throws {
        guard !edit.isEmpty else { return }
        guard !CueTrackRef.isCue(url) else { throw TagWriteError.unsupported("cue sheet tracks are read-only") }
        switch ContainerSniffer.sniff(url) {
        case .flac: try FLACTagWriter.write(edit, to: url)
        case .mp3: try ID3Writer.write(edit, to: url)
        case .mp4: try await MP4TagWriter.write(edit, to: url)
        default: throw TagWriteError.unsupported("\(url.pathExtension.uppercased()) files are read-only")
        }
    }

    /// Writes `head` followed by the bytes of `url` from `from` to a temporary sibling, then swaps it in.
    static func rewrite(_ url: URL, head: Data, keepingFrom from: UInt64, upTo end: UInt64? = nil) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".kveikur-\(UUID().uuidString).\(url.pathExtension)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: head) else {
            throw TagWriteError.unsupported("folder is not writable")
        }
        do {
            let src = try FileHandle(forReadingFrom: url)
            defer { try? src.close() }
            let dst = try FileHandle(forWritingTo: tmp)
            defer { try? dst.close() }
            try dst.seekToEnd()
            try src.seek(toOffset: from)
            var remaining = end.map { $0 - from }
            while true {
                let n = remaining.map { Int(min($0, 1 << 20)) } ?? 1 << 20
                guard n > 0, let chunk = try src.read(upToCount: n), !chunk.isEmpty else { break }
                try dst.write(contentsOf: chunk)
                remaining = remaining.map { $0 - UInt64(chunk.count) }
            }
            try dst.synchronize()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func overwrite(_ url: URL, at offset: UInt64, with data: Data) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        try h.write(contentsOf: data)
        try h.synchronize()
    }
}

// MARK: FLAC

enum FLACTagWriter {
    struct Block {
        var type: UInt8
        var data: Data
    }

    struct Layout {
        var prefix: Data
        var blocks: [Block]
        /// Offset of the first metadata block (after "fLaC") and of the first audio frame.
        var metaStart: UInt64
        var audioStart: UInt64
    }

    static func layout(_ url: URL) throws -> Layout {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var prefix = Data()
        var offset: UInt64 = 0
        let head = try h.read(upToCount: 10) ?? Data()
        if head.count == 10, head.starts(with: Array("ID3".utf8)) {
            let b = [UInt8](head)
            let size = 10 + ((Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9]))
            try h.seek(toOffset: 0)
            prefix = try h.read(upToCount: size) ?? Data()
            offset = UInt64(size)
        }
        try h.seek(toOffset: offset)
        guard try h.read(upToCount: 4) == Data("fLaC".utf8) else { throw TagWriteError.corrupt("not a FLAC stream") }
        offset += 4
        let metaStart = offset
        var blocks: [Block] = []
        var last = false
        while !last {
            guard let hdr = try h.read(upToCount: 4), hdr.count == 4 else { throw TagWriteError.corrupt("truncated metadata") }
            let b = [UInt8](hdr)
            last = b[0] & 0x80 != 0
            let length = (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            guard let body = try h.read(upToCount: length), body.count == length else { throw TagWriteError.corrupt("truncated metadata") }
            blocks.append(Block(type: b[0] & 0x7F, data: body))
            offset += 4 + UInt64(length)
        }
        guard blocks.first?.type == 0 else { throw TagWriteError.corrupt("missing STREAMINFO") }
        return Layout(prefix: prefix, blocks: blocks, metaStart: metaStart, audioStart: offset)
    }

    static let keys: [TagField: [String]] = [
        .title: ["TITLE"], .artist: ["ARTIST"], .album: ["ALBUM"],
        .albumArtist: ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"], .genre: ["GENRE"], .composer: ["COMPOSER"],
        .year: ["DATE", "YEAR"], .track: ["TRACKNUMBER"], .trackTotal: ["TRACKTOTAL", "TOTALTRACKS"],
        .disc: ["DISCNUMBER"], .discTotal: ["DISCTOTAL", "TOTALDISCS"],
    ]

    /// Applies `edit` to a VORBIS_COMMENT body (or creates one), keeping every other field.
    static func comments(_ old: Data?, applying edit: TagEdit) -> Data {
        var vendor = Data("Kveikur".utf8)
        var fields: [Data] = []
        if let old {
            var r = ByteReader([UInt8](old))
            if let vl = r.u32le(), let v = r.bytes(Int(vl)), let count = r.u32le() {
                vendor = Data(v)
                for _ in 0..<count {
                    guard let l = r.u32le(), let f = r.bytes(Int(l)) else { break }
                    fields.append(Data(f))
                }
            }
        }
        let drop = Set(edit.values.keys.flatMap { keys[$0] ?? [] })
        fields.removeAll { f in
            guard let eq = f.firstIndex(of: UInt8(ascii: "=")) else { return false }
            return drop.contains(String(decoding: f[f.startIndex..<eq], as: UTF8.self).uppercased())
        }
        for field in TagField.allCases {
            guard let v = edit.values[field], !v.isEmpty, let key = keys[field]?.first else { continue }
            fields.append(Data("\(key)=\(v)".utf8))
        }
        var out = Data()
        out.appendLE(UInt32(vendor.count))
        out.append(vendor)
        out.appendLE(UInt32(fields.count))
        for f in fields {
            out.appendLE(UInt32(f.count))
            out.append(f)
        }
        return out
    }

    static func write(_ edit: TagEdit, to url: URL) throws {
        let l = try layout(url)
        let comment = comments(l.blocks.first { $0.type == 4 }?.data, applying: edit)
        var blocks = l.blocks.filter { $0.type != 4 && $0.type != 1 }
        let at = l.blocks.firstIndex { $0.type == 4 }.map { i in l.blocks[..<i].filter { $0.type != 1 }.count } ?? 1
        blocks.insert(Block(type: 4, data: comment), at: min(at, blocks.count))
        guard blocks.allSatisfy({ $0.data.count < 1 << 24 }) else { throw TagWriteError.unsupported("metadata block too large") }

        let oldSize = Int(l.audioStart - l.metaStart)
        let used = blocks.reduce(0) { $0 + 4 + $1.data.count }
        if used == oldSize {
            try TagWriter.overwrite(url, at: l.metaStart, with: encode(blocks))
        } else if used + 4 <= oldSize, oldSize - used - 4 < 1 << 24 {
            try TagWriter.overwrite(url, at: l.metaStart, with: encode(blocks + [Block(type: 1, data: Data(count: oldSize - used - 4))]))
        } else {
            var head = l.prefix
            head.append(Data("fLaC".utf8))
            head.append(encode(blocks + [Block(type: 1, data: Data(count: 8192))]))
            try TagWriter.rewrite(url, head: head, keepingFrom: l.audioStart)
        }
    }

    static func encode(_ blocks: [Block]) -> Data {
        var out = Data()
        for (i, b) in blocks.enumerated() {
            let n = b.data.count
            out.append(contentsOf: [(i == blocks.count - 1 ? 0x80 : 0) | b.type, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(b.data)
        }
        return out
    }
}

// MARK: ID3v2 (MP3)

enum ID3Writer {
    struct Frame: Equatable {
        var id: String
        var raw: Data
    }

    struct Tag {
        var major: UInt8
        var frames: [Frame]
        /// Header + body + footer: where the audio begins.
        var totalSize: Int
        var bodySize: Int
        var hasFooter: Bool
    }

    static func parse(_ data: Data) throws -> Tag? {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b.starts(with: Array("ID3".utf8)) else { return nil }
        let major = b[3]
        let flags = b[5]
        let size = synchsafe(b[6], b[7], b[8], b[9])
        guard major == 3 || major == 4 else { throw TagWriteError.unsupported("ID3v2.\(major) tags") }
        guard flags & 0x80 == 0 else { throw TagWriteError.unsupported("unsynchronised ID3 tags") }
        guard flags & 0x40 == 0 else { throw TagWriteError.unsupported("ID3 extended headers") }
        let footer = major == 4 && flags & 0x10 != 0
        let body = [UInt8](data.dropFirst(10).prefix(size))
        guard body.count == size else { throw TagWriteError.corrupt("truncated ID3 tag") }
        var frames: [Frame] = []
        var p = 0
        while p + 10 <= body.count, body[p] != 0 {
            let id = String(decoding: body[p..<p + 4], as: UTF8.self)
            let len = major == 4 ? synchsafe(body[p + 4], body[p + 5], body[p + 6], body[p + 7])
                                 : Int(body[p + 4]) << 24 | Int(body[p + 5]) << 16 | Int(body[p + 6]) << 8 | Int(body[p + 7])
            guard len >= 0, p + 10 + len <= body.count else { break }
            frames.append(Frame(id: id, raw: Data(body[p..<p + 10 + len])))
            p += 10 + len
        }
        return Tag(major: major, frames: frames, totalSize: 10 + size + (footer ? 10 : 0), bodySize: size, hasFooter: footer)
    }

    static func synchsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    static func synchsafeBytes(_ n: Int) -> [UInt8] {
        [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]
    }

    /// Frame IDs replaced by each field; the first one is written.
    static func ids(_ f: TagField, major: UInt8) -> [String] {
        switch f {
        case .title: return ["TIT2"]
        case .artist: return ["TPE1"]
        case .album: return ["TALB"]
        case .albumArtist: return ["TPE2"]
        case .genre: return ["TCON"]
        case .composer: return ["TCOM"]
        case .year: return major == 4 ? ["TDRC", "TYER"] : ["TYER", "TDRC"]
        case .track, .trackTotal: return ["TRCK"]
        case .disc, .discTotal: return ["TPOS"]
        }
    }

    static func textFrame(_ id: String, _ text: String, major: UInt8) -> Data {
        var body = Data()
        if major == 4 {
            body.append(3)
            body.append(Data(text.utf8))
        } else if text.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            body.append(0)
            body.append(Data(text.utf8))
        } else {
            body.append(1)
            body.append(contentsOf: [0xFF, 0xFE])
            for u in text.utf16 { body.append(contentsOf: [UInt8(u & 0xFF), UInt8(u >> 8)]) }
        }
        var out = Data(id.utf8)
        if major == 4 {
            out.append(contentsOf: synchsafeBytes(body.count))
        } else {
            out.appendBE(UInt32(body.count))
        }
        out.append(contentsOf: [0, 0])
        out.append(body)
        return out
    }

    static func apply(_ edit: TagEdit, to frames: [Frame], major: UInt8) -> [Frame] {
        var values: [(String, String)] = []
        for f in [TagField.title, .artist, .album, .albumArtist, .genre, .composer, .year] {
            if let v = edit.values[f] { values.append((ids(f, major: major)[0], v)) }
        }
        if let v = edit.pair(.track, .trackTotal) { values.append(("TRCK", v)) }
        if let v = edit.pair(.disc, .discTotal) { values.append(("TPOS", v)) }
        let drop = Set(edit.values.keys.flatMap { ids($0, major: major) })
        var out = frames.filter { !drop.contains($0.id) }
        for (id, v) in values where !v.isEmpty {
            out.append(Frame(id: id, raw: textFrame(id, v, major: major)))
        }
        return out
    }

    static func header(major: UInt8, size: Int) -> Data {
        var d = Data("ID3".utf8)
        d.append(contentsOf: [major, 0, 0])
        d.append(contentsOf: synchsafeBytes(size))
        return d
    }

    static func write(_ edit: TagEdit, to url: URL) throws {
        let h = try FileHandle(forReadingFrom: url)
        let head = try h.read(upToCount: 10) ?? Data()
        var tagData = head
        if head.count == 10, head.starts(with: Array("ID3".utf8)) {
            let b = [UInt8](head)
            tagData.append(try h.read(upToCount: synchsafe(b[6], b[7], b[8], b[9])) ?? Data())
        }
        try h.close()

        let existing = try parse(tagData)
        let major = existing?.major ?? 4
        let frames = apply(edit, to: existing?.frames ?? [], major: major)
        let body = frames.reduce(into: Data()) { $0.append($1.raw) }

        if let t = existing, !t.hasFooter, body.count <= t.bodySize {
            var tag = header(major: major, size: t.bodySize)
            tag.append(body)
            tag.append(Data(count: t.bodySize - body.count))
            try TagWriter.overwrite(url, at: 0, with: tag)
        } else {
            let size = body.count + 2048
            var tag = header(major: major, size: size)
            tag.append(body)
            tag.append(Data(count: 2048))
            try TagWriter.rewrite(url, head: tag, keepingFrom: UInt64(existing?.totalSize ?? 0))
        }
        try patchID3v1(edit, url: url)
    }

    /// Keeps a trailing ID3v1 tag from contradicting the new values; fields it can't encode are cleared.
    static func patchID3v1(_ edit: TagEdit, url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        guard end >= 128 else { return }
        try h.seek(toOffset: end - 128)
        guard var v1 = try h.read(upToCount: 128), v1.prefix(3) == Data("TAG".utf8) else { return }
        func put(_ f: TagField, _ offset: Int, _ len: Int) {
            guard let v = edit.values[f] else { return }
            let bytes = v.data(using: .isoLatin1) ?? Data()
            var field = Data(bytes.prefix(len))
            field.append(Data(count: len - field.count))
            v1.replaceSubrange(offset..<offset + len, with: field)
        }
        put(.title, 3, 30)
        put(.artist, 33, 30)
        put(.album, 63, 30)
        put(.year, 93, 4)
        if let t = edit.values[.track], v1[125] == 0 { v1[126] = UInt8(clamping: Int(t) ?? 0) }
        try h.seek(toOffset: end - 128)
        try h.write(contentsOf: v1)
    }
}

// MARK: MP4

enum MP4TagWriter {
    static func identifiers(_ f: TagField) -> [AVMetadataIdentifier] {
        switch f {
        case .title: return [.iTunesMetadataSongName, .commonIdentifierTitle]
        case .artist: return [.iTunesMetadataArtist, .commonIdentifierArtist]
        case .album: return [.iTunesMetadataAlbum, .commonIdentifierAlbumName]
        case .albumArtist: return [.iTunesMetadataAlbumArtist]
        case .genre: return [.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre]
        case .composer: return [.iTunesMetadataComposer]
        case .year: return [.iTunesMetadataReleaseDate, .commonIdentifierCreationDate]
        case .track, .trackTotal: return [.iTunesMetadataTrackNumber]
        case .disc, .discTotal: return [.iTunesMetadataDiscNumber]
        }
    }

    static func numberPair(_ s: String) -> Data {
        let (n, t) = TagBag.parsePair(s)
        let a = UInt16(clamping: n ?? 0), b = UInt16(clamping: t ?? 0)
        return Data([0, 0, UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF), 0, 0])
    }

    static func write(_ edit: TagEdit, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let existing = try await asset.load(.metadata)
        let drop = Set(edit.values.keys.flatMap(identifiers))
        var items: [AVMetadataItem] = existing.filter { $0.identifier.map { !drop.contains($0) } ?? true }

        func add(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: CFString? = nil) {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            if let dataType { m.dataType = dataType as String }
            items.append(m)
        }
        for f in [TagField.title, .artist, .album, .albumArtist, .genre, .composer, .year] {
            if let v = edit.values[f], !v.isEmpty { add(identifiers(f)[0], v as NSString) }
        }
        if let v = edit.pair(.track, .trackTotal), !v.isEmpty {
            add(.iTunesMetadataTrackNumber, numberPair(v) as NSData, dataType: kCMMetadataBaseDataType_RawData)
        }
        if let v = edit.pair(.disc, .discTotal), !v.isEmpty {
            add(.iTunesMetadataDiscNumber, numberPair(v) as NSData, dataType: kCMMetadataBaseDataType_RawData)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriteError.unsupported("this MP4 file can't be re-muxed")
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".kveikur-\(UUID().uuidString).m4a")
        session.metadata = items
        do {
            try await session.export(to: tmp, as: .m4a)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
    }

    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}

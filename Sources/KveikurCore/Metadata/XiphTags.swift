import Foundation

/// Reads Vorbis comments, pictures and STREAMINFO from FLAC and Ogg (Vorbis/Opus/FLAC) files.
enum XiphTags {
    struct StreamInfo {
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var totalSamples: Int64
    }

    struct Result {
        var tags = TagBag()
        var streamInfo: StreamInfo?
    }

    // MARK: FLAC

    static func readFLAC(_ url: URL, wantPicture: Bool) -> Result? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard var head = try? h.read(upToCount: 10) else { return nil }
        var offset: UInt64 = 0
        if head.starts(with: Array("ID3".utf8)), head.count == 10 {
            let b = [UInt8](head)
            offset = UInt64(10 + ((Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])))
            try? h.seek(toOffset: offset)
            head = (try? h.read(upToCount: 4)) ?? Data()
        }
        guard head.prefix(4) == Data("fLaC".utf8) else { return nil }
        offset += 4
        var result = Result()
        var last = false
        while !last {
            try? h.seek(toOffset: offset)
            guard let hdr = try? h.read(upToCount: 4), hdr.count == 4 else { break }
            let b = [UInt8](hdr)
            last = (b[0] & 0x80) != 0
            let type = b[0] & 0x7F
            let length = (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            offset += 4
            switch type {
            case 0:
                if let d = try? h.read(upToCount: length) { result.streamInfo = parseStreamInfo([UInt8](d)) }
            case 4:
                if let d = try? h.read(upToCount: length) { parseComments([UInt8](d), into: &result.tags) }
            case 6 where wantPicture && result.tags.picture == nil:
                if let d = try? h.read(upToCount: length) { result.tags.picture = parsePicture([UInt8](d)) }
            default:
                break
            }
            offset += UInt64(length)
        }
        return result
    }

    static func parseStreamInfo(_ b: [UInt8]) -> StreamInfo? {
        guard b.count >= 18 else { return nil }
        let rate = (Int(b[10]) << 12) | (Int(b[11]) << 4) | (Int(b[12]) >> 4)
        let channels = Int((b[12] >> 1) & 0x07) + 1
        let bps = Int(((b[12] & 0x01) << 4) | (b[13] >> 4)) + 1
        var total = Int64(b[13] & 0x0F)
        for i in 14..<18 { total = (total << 8) | Int64(b[i]) }
        return StreamInfo(sampleRate: rate, channels: channels, bitsPerSample: bps, totalSamples: total)
    }

    /// Vorbis comment block (little-endian lengths, no framing bit).
    static func parseComments(_ b: [UInt8], into tags: inout TagBag) {
        var r = ByteReader(b)
        guard let vendorLen = r.u32le(), r.skip(Int(vendorLen)), let count = r.u32le() else { return }
        for _ in 0..<min(count, 10_000) {
            guard let len = r.u32le(), let bytes = r.bytes(Int(len)) else { break }
            guard let s = String(bytes: bytes, encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            let key = TagBag.vorbisKey(String(s[..<eq]))
            let value = String(s[s.index(after: eq)...])
            if key == "lyrics" {
                if tags.lyrics == nil { tags.lyrics = value }
            } else if key == "metadata_block_picture" {
                if tags.picture == nil, let d = Data(base64Encoded: value, options: .ignoreUnknownCharacters) {
                    tags.picture = parsePicture([UInt8](d))
                }
            } else {
                tags.set(key, value)
            }
        }
    }

    /// FLAC PICTURE block -> image bytes.
    static func parsePicture(_ b: [UInt8]) -> Data? {
        var r = ByteReader(b)
        guard r.u32be() != nil, let mimeLen = r.u32be(), r.skip(Int(mimeLen)),
              let descLen = r.u32be(), r.skip(Int(descLen)), r.skip(16),
              let dataLen = r.u32be(), let data = r.bytes(Int(dataLen)) else { return nil }
        return Data(data)
    }

    // MARK: Ogg

    enum OggCodec { case vorbis, opus, flac }

    static func readOgg(_ url: URL, wantPicture: Bool) -> (Result, OggCodec)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        var serial: UInt32?
        var codec: OggCodec?
        var result = Result()
        let limit = wantPicture ? 32 << 20 : 4 << 20

        var read = 0
        pages: while read < limit {
            guard let hdr = try? h.read(upToCount: 27), hdr.count == 27, hdr.prefix(4) == Data("OggS".utf8) else { break }
            let hb = [UInt8](hdr)
            let pageSerial = UInt32(hb[14]) | UInt32(hb[15]) << 8 | UInt32(hb[16]) << 16 | UInt32(hb[17]) << 24
            let segCount = Int(hb[26])
            guard let segs = try? h.read(upToCount: segCount), segs.count == segCount else { break }
            let lacing = [UInt8](segs)
            let bodyLen = lacing.reduce(0) { $0 + Int($1) }
            guard let body = try? h.read(upToCount: bodyLen), body.count == bodyLen else { break }
            read += 27 + segCount + bodyLen
            if serial == nil { serial = pageSerial }
            guard pageSerial == serial else { continue }
            let bb = [UInt8](body)
            var pos = 0
            for l in lacing {
                partial.append(contentsOf: bb[pos..<pos + Int(l)])
                pos += Int(l)
                if l < 255 {
                    packets.append(partial)
                    partial = []
                    if handle(packets.count - 1, packets.last!, codec: &codec, result: &result) { break pages }
                }
            }
        }
        guard let c = codec else { return nil }
        if !wantPicture { result.tags.picture = nil }
        return (result, c)
    }

    /// Returns true once the comment header has been consumed.
    private static func handle(_ index: Int, _ p: [UInt8], codec: inout OggCodec?, result: inout Result) -> Bool {
        if index == 0 {
            if p.count >= 30, p[0] == 1, Array(p[1..<7]) == Array("vorbis".utf8) {
                codec = .vorbis
                let rate = Int(p[12]) | Int(p[13]) << 8 | Int(p[14]) << 16 | Int(p[15]) << 24
                result.streamInfo = StreamInfo(sampleRate: rate, channels: Int(p[11]), bitsPerSample: 0, totalSamples: 0)
            } else if p.count >= 19, Array(p[0..<8]) == Array("OpusHead".utf8) {
                codec = .opus
                result.streamInfo = StreamInfo(sampleRate: 48000, channels: Int(p[9]), bitsPerSample: 0, totalSamples: 0)
            } else if p.count >= 51, p[0] == 0x7F, Array(p[1..<5]) == Array("FLAC".utf8) {
                codec = .flac
                result.streamInfo = parseStreamInfo(Array(p[17...]))
            } else {
                return true
            }
            return false
        }
        switch codec {
        case .vorbis where p.count > 7 && p[0] == 3:
            parseComments(Array(p[7...]), into: &result.tags)
            return true
        case .opus where p.count > 8 && Array(p[0..<8]) == Array("OpusTags".utf8):
            parseComments(Array(p[8...]), into: &result.tags)
            return true
        case .flac where p.count > 4:
            if p[0] & 0x7F == 4 { parseComments(Array(p[4...]), into: &result.tags); return true }
            return false
        default:
            return index > 3
        }
    }
}

struct ByteReader {
    let b: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { self.b = b }

    mutating func u32le() -> UInt32? {
        guard pos + 4 <= b.count else { return nil }
        defer { pos += 4 }
        return UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24
    }

    mutating func u32be() -> UInt32? {
        guard pos + 4 <= b.count else { return nil }
        defer { pos += 4 }
        return UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3])
    }

    mutating func skip(_ n: Int) -> Bool {
        guard n >= 0, pos + n <= b.count else { return false }
        pos += n
        return true
    }

    mutating func bytes(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, pos + n <= b.count else { return nil }
        defer { pos += n }
        return b[pos..<pos + n]
    }
}

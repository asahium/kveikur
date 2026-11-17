import AudioToolbox
import AVFoundation
import Foundation

public enum MetadataReader {
    public static func read(_ url: URL) async -> TrackMetadata? {
        if CueTrackRef.isCue(url) { return await readCue(url) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        var m = TrackMetadata(
            path: url.path,
            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0
        )
        readTechnical(url, into: &m)
        let bag = await tags(url, wantPicture: false, metadata: &m)
        bag.apply(to: &m)
        if m.bitrate == 0, m.duration > 0 { m.bitrate = Int(Double(m.size) * 8 / m.duration / 1000) }
        return m
    }

    /// Image tags describe the whole disc, so cue tracks have no embedded lyrics.
    public static func embeddedLyrics(_ url: URL) async -> String? {
        guard !CueTrackRef.isCue(url) else { return nil }
        var scratch = TrackMetadata(path: url.path, mtime: 0, size: 0)
        return await tags(url, wantPicture: false, metadata: &scratch).lyrics
    }

    /// Every tag the file carries, with Vorbis-style lowercase keys ("label", "isrc", "replaygain_track_gain", ...).
    /// For cue tracks: the image's disc-level tags with the sheet's track fields on top; image track gain is dropped.
    public static func allTags(_ url: URL) async -> [String: String] {
        let file = CueTrackRef.audioFile(url)
        var scratch = TrackMetadata(path: file.path, mtime: 0, size: 0)
        var values = await tags(file, wantPicture: false, metadata: &scratch).values
        if let (sheet, t) = CueTrackRef.resolve(url) {
            values = values.filter { !$0.key.hasPrefix("replaygain_track") && $0.key != "title" && $0.key != "tracknumber" }
            values["title"] = t.title
            values["artist"] = t.performer ?? sheet.performer ?? values["artist"]
            values["tracknumber"] = "\(t.number)"
            values["isrc"] = t.isrc ?? values["isrc"]
            values["cuesheet"] = sheet.url.lastPathComponent
        }
        return values
    }

    public static func embeddedArtwork(_ url: URL) async -> Data? {
        let file = CueTrackRef.audioFile(url)
        var scratch = TrackMetadata(path: file.path, mtime: 0, size: 0)
        return await tags(file, wantPicture: true, metadata: &scratch).picture
    }

    /// Stamp of a cue track: newest of sheet and image, so editing either re-reads it.
    public static func cueStamp(_ url: URL) -> (mtime: Double, size: Int64)? {
        guard let (sheet, t) = CueTrackRef.resolve(url) else { return nil }
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: t.file.path),
              let c = try? fm.attributesOfItem(atPath: sheet.url.path) else { return nil }
        let m = max((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (c[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return (m, (a[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private static func readCue(_ url: URL) async -> TrackMetadata? {
        guard let (sheet, t) = CueTrackRef.resolve(url), let stamp = cueStamp(url) else { return nil }
        var m = TrackMetadata(path: url.path, mtime: stamp.mtime, size: stamp.size)
        readTechnical(t.file, into: &m)
        var image = TrackMetadata(path: t.file.path, mtime: 0, size: 0)
        let bag = await tags(t.file, wantPicture: false, metadata: &image)
        if let si = image.format { m.format = si }
        let total = image.duration > 0 ? image.duration : m.duration
        m.duration = max(0, (t.end ?? total) - t.start)
        bag.apply(to: &image)
        m.title = t.title ?? "Track \(t.number)"
        m.artist = t.performer ?? sheet.performer ?? image.artist
        m.album = sheet.title ?? image.album
        m.albumArtist = sheet.performer ?? image.albumArtist
        m.genre = sheet.genre ?? image.genre
        m.composer = t.songwriter ?? image.composer
        m.year = sheet.date ?? image.year
        m.trackNumber = t.number
        m.trackTotal = sheet.tracks.filter { $0.file == t.file }.count
        m.discNumber = sheet.disc ?? image.discNumber
        m.discTotal = sheet.discTotal ?? image.discTotal
        return m
    }

    // MARK: Technical info (Core Audio)

    static func readTechnical(_ url: URL, into m: inout TrackMetadata) {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let f = fileID else { return }
        defer { AudioFileClose(f) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &size, &asbd)

        var sourceBits: Int32 = 0
        size = UInt32(MemoryLayout<Int32>.size)
        AudioFileGetProperty(f, kAudioFilePropertySourceBitDepth, &size, &sourceBits)

        var duration: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &size, &duration)

        var bitrate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(f, kAudioFilePropertyBitRate, &size, &bitrate)

        let info = SourceFormat.codecInfo(formatID: asbd.mFormatID)
        var bits = Int(sourceBits)
        if bits <= 0, asbd.mFormatID == kAudioFormatLinearPCM { bits = Int(asbd.mBitsPerChannel) }
        if bits < 0 { bits = 0 }
        m.format = SourceFormat(codec: info.name, sampleRate: asbd.mSampleRate, bitDepth: info.lossless ? bits : 0,
                                channels: Int(asbd.mChannelsPerFrame), lossless: info.lossless)
        m.duration = duration
        m.bitrate = Int(bitrate / 1000)

        var dict: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(f, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
           let d = dict?.takeRetainedValue() as? [String: Any] {
            m.title = d[kAFInfoDictionary_Title] as? String
            m.artist = d[kAFInfoDictionary_Artist] as? String
            m.album = d[kAFInfoDictionary_Album] as? String
            m.genre = d[kAFInfoDictionary_Genre] as? String
            m.composer = d[kAFInfoDictionary_Composer] as? String
            m.year = (d[kAFInfoDictionary_Year] as? String).map { String($0.prefix(4)) }
            if let t = d[kAFInfoDictionary_TrackNumber] as? String {
                let (n, total) = TagBag.parsePair(t)
                m.trackNumber = n
                m.trackTotal = total
            }
        }
    }

    // MARK: Tags

    private static func tags(_ url: URL, wantPicture: Bool, metadata m: inout TrackMetadata) async -> TagBag {
        switch ContainerSniffer.sniff(url) {
        case .flac:
            guard let r = XiphTags.readFLAC(url, wantPicture: wantPicture) else { return TagBag() }
            if let si = r.streamInfo, si.sampleRate > 0 {
                m.format = SourceFormat(codec: "FLAC", sampleRate: Double(si.sampleRate), bitDepth: si.bitsPerSample,
                                        channels: si.channels, lossless: true)
                if si.totalSamples > 0 { m.duration = Double(si.totalSamples) / Double(si.sampleRate) }
            }
            return r.tags
        case .ogg:
            guard let (r, codec) = XiphTags.readOgg(url, wantPicture: wantPicture) else { return TagBag() }
            if var f = m.format {
                f.codec = codec == .flac ? "FLAC" : (codec == .opus ? "Opus" : "Vorbis")
                f.lossless = codec == .flac
                if codec == .flac, let si = r.streamInfo { f.bitDepth = si.bitsPerSample }
                m.format = f
            }
            return r.tags
        default:
            return await avTags(url, wantPicture: wantPicture)
        }
    }

    private static func avTags(_ url: URL, wantPicture: Bool) async -> TagBag {
        var bag = TagBag()
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return bag }
        for item in items {
            guard let id = item.identifier else { continue }
            if id == .commonIdentifierArtwork || id == .id3MetadataAttachedPicture || id == .iTunesMetadataCoverArt {
                if wantPicture, bag.picture == nil { bag.picture = try? await item.load(.dataValue) }
                continue
            }
            if id == .id3MetadataUserText {
                let desc = (try? await item.load(.extraAttributes))?[.info] as? String ?? ""
                let key = desc.uppercased() == "USLT" ? "lyrics" : TagBag.vorbisKey(desc)
                let value = try? await item.load(.stringValue)
                if key == "lyrics" {
                    if bag.lyrics == nil, let v = value, !v.isEmpty { bag.lyrics = v }
                } else {
                    bag.set(key, value)
                }
                continue
            }
            guard let key = Self.avKey(id) ?? Self.freeformKey(id) else { continue }
            if key == "tracknumber" || key == "discnumber", let data = try? await item.load(.dataValue), data.count >= 6,
               id == .iTunesMetadataTrackNumber || id == .iTunesMetadataDiscNumber {
                let b = [UInt8](data)
                let n = Int(b[2]) << 8 | Int(b[3])
                let total = Int(b[4]) << 8 | Int(b[5])
                bag.set(key, total > 0 ? "\(n)/\(total)" : "\(n)")
                continue
            }
            let value = try? await item.load(.stringValue)
            if key == "lyrics" {
                if bag.lyrics == nil, let v = value, !v.isEmpty { bag.lyrics = v }
            } else {
                bag.set(key, value)
            }
        }
        return bag
    }

    private static func avKey(_ id: AVMetadataIdentifier) -> String? {
        switch id {
        case .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName: return "title"
        case .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist: return "artist"
        case .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum: return "album"
        case .id3MetadataBand, .iTunesMetadataAlbumArtist: return "albumartist"
        case .id3MetadataComposer, .iTunesMetadataComposer: return "composer"
        case .id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre: return "genre"
        case .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate: return "date"
        case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber: return "tracknumber"
        case .id3MetadataPartOfASet, .iTunesMetadataDiscNumber: return "discnumber"
        case .id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics: return "lyrics"
        case .id3MetadataPublisher, .iTunesMetadataPublisher: return "label"
        case .id3MetadataInternationalStandardRecordingCode: return "isrc"
        case .id3MetadataBeatsPerMinute, .iTunesMetadataBeatsPerMin: return "bpm"
        case .id3MetadataInitialKey: return "initialkey"
        case .id3MetadataCopyright, .iTunesMetadataCopyright: return "copyright"
        case .id3MetadataComments, .iTunesMetadataUserComment: return "comment"
        case .iTunesMetadataGrouping, .id3MetadataContentGroupDescription: return "grouping"
        default: return nil
        }
    }

    /// iTunes freeform atoms such as "com.apple.iTunes:BARCODE".
    private static func freeformKey(_ id: AVMetadataIdentifier) -> String? {
        let raw = id.rawValue
        guard let r = raw.range(of: "com.apple.iTunes:", options: .backwards) else { return nil }
        let name = String(raw[r.upperBound...])
        return name.isEmpty ? nil : TagBag.vorbisKey(name)
    }
}

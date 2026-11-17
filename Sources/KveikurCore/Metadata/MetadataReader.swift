import AudioToolbox
import AVFoundation
import Foundation

public enum MetadataReader {
    public static func read(_ url: URL) async -> TrackMetadata? {
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

    public static func embeddedLyrics(_ url: URL) async -> String? {
        var scratch = TrackMetadata(path: url.path, mtime: 0, size: 0)
        return await tags(url, wantPicture: false, metadata: &scratch).lyrics
    }

    /// Every tag the file carries, with Vorbis-style lowercase keys ("label", "isrc", "replaygain_track_gain", ...).
    public static func allTags(_ url: URL) async -> [String: String] {
        var scratch = TrackMetadata(path: url.path, mtime: 0, size: 0)
        return await tags(url, wantPicture: false, metadata: &scratch).values
    }

    public static func embeddedArtwork(_ url: URL) async -> Data? {
        var scratch = TrackMetadata(path: url.path, mtime: 0, size: 0)
        return await tags(url, wantPicture: true, metadata: &scratch).picture
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

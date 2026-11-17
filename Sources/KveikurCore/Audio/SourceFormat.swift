import AudioToolbox
import Foundation

public enum AudioFiles {
    public static let extensions: Set<String> = [
        "flac", "m4a", "m4b", "m4r", "alac", "mp4", "mp3", "aac", "adts",
        "aif", "aiff", "aifc", "wav", "wave", "w64", "caf", "caff", "au", "snd",
        "ogg", "oga", "opus",
    ]
    public static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    public static func isAudio(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func isPlaylist(_ url: URL) -> Bool {
        playlistExtensions.contains(url.pathExtension.lowercased())
    }
}

public struct SourceFormat: Hashable, Codable, Sendable {
    public var codec: String
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int
    public var lossless: Bool

    public init(codec: String, sampleRate: Double, bitDepth: Int, channels: Int, lossless: Bool) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.lossless = lossless
    }

    /// "FLAC 24/96", "MP3 44.1", "AAC 48".
    public var shortLabel: String {
        let rate = SourceFormat.formatRate(sampleRate)
        if lossless && bitDepth > 0 { return "\(codec) \(bitDepth)/\(rate)" }
        return "\(codec) \(rate)"
    }

    public static func formatRate(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
    }

    static func codecInfo(formatID: AudioFormatID) -> (name: String, lossless: Bool) {
        switch formatID {
        case kAudioFormatFLAC: return ("FLAC", true)
        case kAudioFormatAppleLossless: return ("ALAC", true)
        case kAudioFormatLinearPCM: return ("PCM", true)
        case kAudioFormatMPEGLayer3: return ("MP3", false)
        case kAudioFormatMPEGLayer2: return ("MP2", false)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return ("AAC", false)
        case kAudioFormatOpus: return ("Opus", false)
        case 0x766F_7262: return ("Vorbis", false) // 'vorb'
        case kAudioFormatAC3: return ("AC3", false)
        case kAudioFormatEnhancedAC3: return ("EAC3", false)
        case kAudioFormatULaw, kAudioFormatALaw: return ("G.711", false)
        default:
            let chars = withUnsafeBytes(of: formatID.bigEndian) { Array($0) }
            let s = String(bytes: chars, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
            return (s.uppercased(), false)
        }
    }
}

public enum ContainerSniffer {
    public enum Kind: String, Sendable {
        case flac, ogg, mp4, mp3, riff, aiff, caf, w64, au, adts, unknown

        public var displayName: String {
            switch self {
            case .flac: return "FLAC"
            case .ogg: return "Ogg"
            case .mp4: return "MPEG-4"
            case .mp3: return "MPEG Audio"
            case .riff: return "WAVE"
            case .aiff: return "AIFF"
            case .caf: return "CAF"
            case .w64: return "Wave64"
            case .au: return "AU"
            case .adts: return "ADTS"
            case .unknown: return "Unknown"
            }
        }
    }

    /// Detects the container from file contents, not the extension.
    public static func sniff(_ url: URL) -> Kind {
        guard let h = try? FileHandle(forReadingFrom: CueTrackRef.audioFile(url)) else { return .unknown }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 16), d.count >= 4 else { return .unknown }
        let b = [UInt8](d)
        func ascii(_ r: Range<Int>) -> String { String(bytes: b[r], encoding: .ascii) ?? "" }
        if ascii(0..<4) == "fLaC" { return .flac }
        if ascii(0..<4) == "OggS" { return .ogg }
        if b.count >= 8 && ascii(4..<8) == "ftyp" { return .mp4 }
        if ascii(0..<4) == "RIFF" || ascii(0..<4) == "RF64" { return .riff }
        if ascii(0..<4) == "FORM" { return .aiff }
        if ascii(0..<4) == "caff" { return .caf }
        if ascii(0..<4) == "riff" { return .w64 }
        if ascii(0..<4) == ".snd" { return .au }
        if ascii(0..<3) == "ID3" {
            // ID3 may prefix FLAC or AAC too; skip the tag and look again.
            if b.count >= 10 {
                let size = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
                try? h.seek(toOffset: UInt64(10 + size))
                if let n = try? h.read(upToCount: 4), n.count == 4 {
                    let nb = [UInt8](n)
                    if String(bytes: nb, encoding: .ascii) == "fLaC" { return .flac }
                    if nb[0] == 0xFF && (nb[1] & 0xF6) == 0xF0 { return .adts }
                }
            }
            return .mp3
        }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 {
            return (b[1] & 0x06) == 0 ? .adts : .mp3
        }
        return .unknown
    }
}

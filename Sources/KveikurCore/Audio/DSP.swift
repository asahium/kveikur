import Foundation

// MARK: ReplayGain

public enum ReplayGainMode: String, CaseIterable, Codable, Sendable {
    case off, track, album

    public var title: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        }
    }
}

public struct ReplayGainSettings: Codable, Equatable, Sendable {
    public var mode: ReplayGainMode = .off
    /// Added on top of the tag or measured gain.
    public var preampDB: Float = 0
    /// Caps the gain so the track peak stays at or below full scale.
    public var preventClipping = true
    /// Measure EBU R128 loudness for files without ReplayGain tags.
    public var analyzeUntagged = true

    public init() {}
}

/// Gains in dB relative to the ReplayGain 2.0 reference (-18 LUFS); peaks are linear sample peaks.
public struct ReplayGainInfo: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case tags, analysis }

    public var trackGain: Float?
    public var trackPeak: Float?
    public var albumGain: Float?
    public var albumPeak: Float?
    public var source: Source

    public init(trackGain: Float?, trackPeak: Float? = nil, albumGain: Float? = nil, albumPeak: Float? = nil, source: Source) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
        self.source = source
    }

    /// Reads REPLAYGAIN_* and Opus R128_* tags (R128 is Q7.8 relative to -23 LUFS, so +5 dB to match ReplayGain).
    public static func parse(_ tags: [String: String]) -> ReplayGainInfo? {
        func db(_ key: String) -> Float? {
            guard let raw = tags[key] else { return nil }
            let cleaned = raw.lowercased().replacingOccurrences(of: "db", with: "").replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
            return Float(cleaned)
        }
        func r128(_ key: String) -> Float? {
            tags[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { Float($0) / 256 + 5 }
        }
        func peak(_ key: String) -> Float? {
            tags[key].flatMap { Float($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
        }
        let info = ReplayGainInfo(trackGain: db("replaygain_track_gain") ?? r128("r128_track_gain"),
                                  trackPeak: peak("replaygain_track_peak"),
                                  albumGain: db("replaygain_album_gain") ?? r128("r128_album_gain"),
                                  albumPeak: peak("replaygain_album_peak"),
                                  source: .tags)
        return info.trackGain == nil && info.albumGain == nil ? nil : info
    }

    /// Applied gain in dB for `settings`, or nil when this info has nothing for the mode.
    public func gainDB(_ settings: ReplayGainSettings) -> Float? {
        let gain: Float?
        let pk: Float?
        switch settings.mode {
        case .off: return nil
        case .track: gain = trackGain ?? albumGain; pk = trackGain != nil ? trackPeak : albumPeak
        case .album: gain = albumGain ?? trackGain; pk = albumGain != nil ? albumPeak : trackPeak
        }
        guard var g = gain else { return nil }
        g += settings.preampDB
        if settings.preventClipping, let p = pk, p > 0 {
            g = min(g, -20 * log10(p))
        }
        return g
    }
}

// MARK: Equalizer

public struct EQBand: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case peak, lowShelf, highShelf }

    public var kind: Kind
    public var frequency: Float
    public var gain: Float
    public var q: Float

    public init(_ kind: Kind = .peak, frequency: Float, gain: Float, q: Float = 1.41) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    /// Bandwidth in octaves for a peaking filter of this Q.
    public var bandwidthOctaves: Float {
        let q = max(self.q, 0.05)
        return 2 / log(2) * asinh(1 / (2 * q))
    }
}

public struct EQPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var preamp: Float
    public var bands: [EQBand]
    /// Ten ISO bands editable with sliders; imported parametric profiles are not.
    public var isGraphic: Bool

    public var id: String { name }

    public init(name: String, preamp: Float = 0, bands: [EQBand], isGraphic: Bool) {
        self.name = name
        self.preamp = preamp
        self.bands = bands
        self.isGraphic = isGraphic
    }

    public static let graphicFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let maxBands = 16

    public static func graphic(_ name: String, _ gains: [Float], preamp: Float = 0) -> EQPreset {
        EQPreset(name: name, preamp: preamp,
                 bands: zip(graphicFrequencies, gains + Array(repeating: 0, count: max(0, 10 - gains.count))).map {
                     EQBand(.peak, frequency: $0.0, gain: $0.1, q: 1.41)
                 },
                 isGraphic: true)
    }

    public static let flat = graphic("Flat", [])

    public static let builtIn: [EQPreset] = [
        flat,
        graphic("Bass Boost", [6, 5, 4, 2, 0.5, 0, 0, 0, 0, 0], preamp: -6),
        graphic("Treble Boost", [0, 0, 0, 0, 0, 0.5, 2, 3.5, 5, 6], preamp: -6),
        graphic("Loudness", [5, 4, 2, 0, -1, -1, 0, 2, 4, 5], preamp: -5),
        graphic("Vocal", [-2, -2, -1, 1, 3, 3.5, 3, 1.5, 0, -1], preamp: -3.5),
        graphic("Warm", [3, 3, 2, 1, 0, 0, -1, -2, -2.5, -3], preamp: -3),
        graphic("Bright", [-1, -1, 0, 0, 0, 1, 2, 3, 3.5, 3], preamp: -3.5),
    ]

    public var isFlat: Bool { preamp == 0 && bands.allSatisfy { $0.gain == 0 } }

    /// Magnitude response in dB including preamp (RBJ biquads, shelves with slope 1).
    public func responseDB(at frequency: Float, sampleRate: Float = 48000) -> Float {
        preamp + bands.reduce(0) { $0 + $1.responseDB(at: frequency, sampleRate: sampleRate) }
    }

    /// AutoEQ "ParametricEQ.txt": a Preamp line plus up to `maxBands` PK / LSC / HSC filters.
    public static func parseAutoEQ(_ text: String, name: String) -> EQPreset? {
        var preamp: Float = 0
        var bands: [EQBand] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first?.lowercased() else { continue }
            func value(after key: String) -> Float? {
                guard let i = words.firstIndex(where: { $0.lowercased() == key.lowercased() }), i + 1 < words.count else { return nil }
                return Float(words[i + 1])
            }
            if first.hasPrefix("preamp") {
                preamp = words.dropFirst().compactMap { Float($0) }.first ?? 0
                continue
            }
            guard first == "filter", words.contains(where: { $0.uppercased() == "ON" }) else { continue }
            let kind: EQBand.Kind
            if words.contains(where: { ["LSC", "LS", "LSQ"].contains($0.uppercased()) }) {
                kind = .lowShelf
            } else if words.contains(where: { ["HSC", "HS", "HSQ"].contains($0.uppercased()) }) {
                kind = .highShelf
            } else if words.contains(where: { ["PK", "PEQ"].contains($0.uppercased()) }) {
                kind = .peak
            } else {
                continue
            }
            guard let fc = value(after: "Fc"), let gain = value(after: "Gain") else { continue }
            bands.append(EQBand(kind, frequency: fc, gain: gain, q: value(after: "Q") ?? 0.71))
        }
        guard !bands.isEmpty else { return nil }
        return EQPreset(name: name, preamp: preamp, bands: Array(bands.prefix(maxBands)), isGraphic: false)
    }
}

extension EQBand {
    public func responseDB(at f: Float, sampleRate fs: Float) -> Float {
        guard gain != 0, frequency < fs / 2 else { return 0 }
        let a = pow(10, Double(gain) / 40)
        let w0 = 2 * Double.pi * Double(frequency) / Double(fs)
        let cw = cos(w0)
        let b: (Double, Double, Double)
        let d: (Double, Double, Double)
        switch kind {
        case .peak:
            let alpha = sin(w0) / (2 * Double(max(q, 0.05)))
            b = (1 + alpha * a, -2 * cw, 1 - alpha * a)
            d = (1 + alpha / a, -2 * cw, 1 - alpha / a)
        case .lowShelf, .highShelf:
            let alpha = sin(w0) / 2 * sqrt(2.0)
            let sa = 2 * sqrt(a) * alpha
            if kind == .lowShelf {
                b = (a * ((a + 1) - (a - 1) * cw + sa), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - sa))
                d = ((a + 1) + (a - 1) * cw + sa, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - sa)
            } else {
                b = (a * ((a + 1) + (a - 1) * cw + sa), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - sa))
                d = ((a + 1) - (a - 1) * cw + sa, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - sa)
            }
        }
        let w = 2 * Double.pi * Double(f) / Double(fs)
        func mag2(_ c: (Double, Double, Double)) -> Double {
            let re = c.0 + c.1 * cos(w) + c.2 * cos(2 * w)
            let im = -c.1 * sin(w) - c.2 * sin(2 * w)
            return re * re + im * im
        }
        return Float(10 * log10(mag2(b) / mag2(d)))
    }
}

public struct EQSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var preset: EQPreset = .flat

    public init() {}

    /// Whether the equalizer actually touches the samples.
    public var active: Bool { enabled && !preset.isFlat }
}

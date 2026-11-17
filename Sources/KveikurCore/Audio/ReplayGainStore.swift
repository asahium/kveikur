import AVFAudio
import Foundation

/// ReplayGain per file: tags when present, otherwise a cached EBU R128 measurement.
/// `linearGain` is called from the engine queue and only reads memory.
public final class ReplayGainStore: @unchecked Sendable {
    private struct Measured: Codable {
        var mtime: Double
        var gain: Float
        var peak: Float
    }

    private let lock = NSLock()
    private var settings = ReplayGainSettings()
    private var infos: [String: ReplayGainInfo] = [:]
    private var tagsRead: Set<String> = []
    private var measured: [String: Measured] = [:]
    private var measuring: Set<String> = []
    private let file: URL
    private let analysisQueue = DispatchQueue(label: "kveikur.replaygain", qos: .utility)

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kveikur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("replaygain.json")
        if let data = try? Data(contentsOf: file),
           let m = try? JSONDecoder().decode([String: Measured].self, from: data) {
            measured = m
        }
    }

    public func update(_ s: ReplayGainSettings) {
        lock.withLock { settings = s }
    }

    public func hasTagsLoaded(_ url: URL) -> Bool {
        lock.withLock { tagsRead.contains(url.path) }
    }

    public func info(for url: URL) -> ReplayGainInfo? {
        lock.withLock { infoLocked(url.path) }
    }

    private func infoLocked(_ path: String) -> ReplayGainInfo? {
        if let i = infos[path] { return i }
        guard let m = measured[path], m.mtime == Self.mtime(path) else { return nil }
        return ReplayGainInfo(trackGain: m.gain, trackPeak: m.peak, source: .analysis)
    }

    /// Gain in dB that playback applies right now; nil when off or unknown.
    public func gainDB(for url: URL) -> Float? {
        lock.withLock {
            guard settings.mode != .off else { return nil }
            return infoLocked(url.path)?.gainDB(settings)
        }
    }

    public func linearGain(for url: URL) -> Float {
        gainDB(for: url).map { pow(10, $0 / 20) } ?? 1
    }

    public var isMeasuring: Bool { lock.withLock { !measuring.isEmpty } }

    /// Reads tags once; with `analyze`, measures loudness in the background when tags have no gain.
    public func prepare(_ url: URL, analyze: Bool) async {
        let path = url.path
        if !hasTagsLoaded(url) {
            let tags = await MetadataReader.allTags(url)
            let parsed = ReplayGainInfo.parse(tags)
            lock.withLock {
                tagsRead.insert(path)
                if let p = parsed { infos[path] = p }
            }
        }
        guard analyze else { return }
        let start: Bool = lock.withLock {
            guard settings.mode != .off, settings.analyzeUntagged, infoLocked(path) == nil, !measuring.contains(path) else { return false }
            measuring.insert(path)
            return true
        }
        guard start else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            analysisQueue.async {
                let result = try? Self.measure(url)
                self.lock.withLock {
                    self.measuring.remove(path)
                    if let r = result { self.measured[path] = Measured(mtime: Self.mtime(path), gain: r.gain, peak: r.peak) }
                }
                if result != nil { self.save() }
                done.resume()
            }
        }
    }

    private func save() {
        let snapshot = lock.withLock { measured }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }

    private static func mtime(_ path: String) -> Double {
        let file = CueTrackRef.audioFile(URL(fileURLWithPath: path)).path
        return ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    /// Integrated loudness and sample peak; gain is relative to -18 LUFS.
    static func measure(_ url: URL) throws -> (gain: Float, peak: Float) {
        let decoder = try DecoderFactory.makeDecoder(for: url)
        let format = decoder.processingFormat
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw NSError(domain: "Kveikur", code: 1)
        }
        let meter = LoudnessMeter(sampleRate: format.sampleRate, channels: channels)
        var peak: Float = 0
        while try decoder.read(into: buffer) {
            guard let data = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<n {
                    let a = abs(p[i])
                    if a > peak { peak = a }
                }
            }
            meter.process(data, frames: n)
        }
        guard let lufs = meter.integrated() else { throw NSError(domain: "Kveikur", code: 2) }
        return (-18 - lufs, peak)
    }
}

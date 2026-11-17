import Accelerate
import AVFAudio
#if os(macOS)
import CoreAudio
#endif
import Foundation

public struct SignalPath: Equatable, Sendable {
    public var sourceRate: Double = 0
    public var sourceChannels: Int = 0
    public var deviceName: String = ""
    public var deviceRate: Double = 0
    public var exclusive = false
    public var softwareVolume: Float = 1
    /// ReplayGain applied to the current track, dB.
    public var gainDB: Float = 0
    public var equalizer = false

    public var resampling: Bool { sourceRate > 0 && deviceRate > 0 && sourceRate != deviceRate }
    public var processing: Bool { gainDB != 0 || equalizer }
    public var bitPerfect: Bool { sourceRate > 0 && !resampling && softwareVolume == 1 && !processing }

    public var label: String {
        guard sourceRate > 0 else { return deviceName }
        let src = SourceFormat.formatRate(sourceRate)
        let dst = SourceFormat.formatRate(deviceRate)
        var parts = ["\(src) → \(dst) kHz"]
        parts.append(bitPerfect ? "bit-perfect" : (resampling ? "resampling" : (processing ? "DSP" : "software volume")))
        if exclusive { parts.append("exclusive") }
        return parts.joined(separator: " · ")
    }
}

public protocol PlaybackEngineDelegate: AnyObject {
    func engine(_ engine: PlaybackEngine, didStart url: URL)
    func engineDidReachEnd(_ engine: PlaybackEngine)
    func engine(_ engine: PlaybackEngine, didFailToOpen url: URL, error: Error)
    func engine(_ engine: PlaybackEngine, signalPathChanged path: SignalPath)
}

/// Streams decoded chunks into an AVAudioPlayerNode. Tracks sharing a format are scheduled back to back,
/// which gives sample-accurate gapless transitions; a format change rebuilds the graph at the boundary.
/// All mutable state lives on `queue`; delegate callbacks arrive on the main queue.
public final class PlaybackEngine: @unchecked Sendable {
    public weak var delegate: PlaybackEngineDelegate?

    private final class Slot {
        let decoder: AudioDecoder
        let url: URL
        var startNodeFrame: Int64
        var baseFrame: Int64
        /// Linear gain fixed when the first buffer is scheduled, so it never changes mid-track.
        var gain: Float?
        init(decoder: AudioDecoder, url: URL, startNodeFrame: Int64, baseFrame: Int64) {
            self.decoder = decoder
            self.url = url
            self.startNodeFrame = startNodeFrame
            self.baseFrame = baseFrame
        }
    }

    private struct Snapshot {
        var startNodeFrame: Int64 = 0
        var baseFrame: Int64 = 0
        var rate: Double = 0
        var length: Int64 = 0
        var playing = false
        var pausedTime: TimeInterval = 0
        /// Seek target shown until the rebuilt graph reports real positions.
        var pendingSeek: TimeInterval?
        /// Last position handed out, used while the render clock is unavailable (engine restarting, player stopped).
        var lastTime: TimeInterval = 0
        /// Position reported at pause; the render clock can sit a few ms behind it, so resume never shows less.
        var floor: TimeInterval = 0
    }

    private static let buffersInFlight = 3
    private static let bufferSeconds = 0.5

    private let queue = DispatchQueue(label: "kveikur.engine", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: EQPreset.maxBands)
    private var eqSettings = EQSettings()
    private var gainProvider: (@Sendable (URL) -> Float)?

    private var connectedFormat: AVAudioFormat?
    private var current: Slot?
    private var feeding: Slot?
    private var pending: [Slot] = []
    private var formatBreakURL: URL?
    private var nextURL: URL?
    private var scheduledFrames: Int64 = 0
    private var inFlight = 0
    private var feedingDone = false
    private var orphanEnd: Slot?
    private var generation = 0
    private var wantsPlaying = false
    private var selectedDevice: OutputDeviceID = 0
    private var volume: Float = 1
    private var matchSampleRate = true
    private var exclusive = false
    private var hoggedDevice: OutputDeviceID = 0

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tapHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var tapInstalled = false

    public init() {
        engine.attach(player)
        engine.attach(eq)
        eq.bypass = true
        _ = engine.mainMixerNode
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
    }

    // MARK: Public API

    public func play(url: URL, at time: TimeInterval = 0) {
        queue.async { self.start(url: url, at: time, autoplay: true) }
    }

    /// Track to schedule right after the current one; nil clears it.
    public func setNext(_ url: URL?) {
        queue.async { self.updateNext(url) }
    }

    /// The position freezes immediately on the caller's thread, so the UI never reads a half-paused engine.
    /// Only the player node pauses: the engine keeps running, and resume continues from the same sample.
    public func pause() {
        let t = currentTime
        updateSnapshot { s in
            guard s.playing else { return }
            s.playing = false
            s.pausedTime = t
            s.floor = t
        }
        queue.async {
            guard self.wantsPlaying else { return }
            self.wantsPlaying = false
            self.player.pause()
        }
    }

    public func resume() {
        queue.async {
            guard self.current != nil, !self.wantsPlaying else { return }
            self.wantsPlaying = true
            if self.connectedFormat == nil || !self.engine.isRunning {
                self.rebuild(at: self.snapshot.pausedTime)
            } else {
                self.player.play()
                self.updateSnapshot { $0.playing = true }
            }
        }
    }

    public func seek(to time: TimeInterval) {
        updateSnapshot { s in
            s.pendingSeek = time
            s.pausedTime = time
            s.lastTime = time
        }
        queue.async {
            guard self.current != nil else { return }
            self.rebuild(at: time)
        }
    }

    public func stop() {
        queue.async {
            self.generation += 1
            self.player.stop()
            self.engine.stop()
            self.resetScheduling()
            self.current = nil
            self.feeding = nil
            self.nextURL = nil
            self.wantsPlaying = false
            self.releaseHog()
            self.updateSnapshot { $0 = Snapshot() }
        }
    }

    public func setVolume(_ v: Float) {
        queue.async {
            self.volume = v
            self.engine.mainMixerNode.outputVolume = v
            self.publishSignalPath()
        }
    }

    /// nil selects the system default output.
    public func setDevice(_ id: OutputDeviceID?) {
        queue.async {
            self.releaseHog()
            self.selectedDevice = id ?? 0
            let t = self.currentTime
            self.engine.stop()
            self.applyDevice()
            self.connectedFormat = nil
            if self.current != nil, self.wantsPlaying { self.rebuild(at: t) } else { self.publishSignalPath() }
        }
    }

    public func setMatchSampleRate(_ on: Bool) {
        queue.async {
            self.matchSampleRate = on
            self.connectedFormat = nil
            if self.current != nil, self.wantsPlaying { self.rebuild(at: self.currentTime) }
        }
    }

    public func setExclusive(_ on: Bool) {
        queue.async {
            self.exclusive = on
            if !on { self.releaseHog() }
            self.connectedFormat = nil
            if self.current != nil, self.wantsPlaying { self.rebuild(at: self.currentTime) } else { self.publishSignalPath() }
        }
    }

    /// Linear gain per file, asked once per track on the engine queue.
    public func setGainProvider(_ provider: (@Sendable (URL) -> Float)?) {
        queue.async { self.gainProvider = provider }
    }

    /// Re-asks the provider for the loaded tracks and re-schedules from the current position.
    public func refreshGains() {
        queue.async {
            guard let cur = self.current else { return }
            cur.gain = nil
            self.pending.forEach { $0.gain = nil }
            self.rebuild(at: self.currentTime)
            self.publishSignalPath()
        }
    }

    public func setEQ(_ settings: EQSettings) {
        queue.async {
            self.eqSettings = settings
            self.applyEQ()
            self.publishSignalPath()
        }
    }

    private func applyEQ() {
        let s = eqSettings
        let nyquist = Float((connectedFormat?.sampleRate ?? 44100) / 2)
        eq.globalGain = s.enabled ? s.preset.preamp : 0
        for (i, band) in eq.bands.enumerated() {
            guard s.enabled, i < s.preset.bands.count, s.preset.bands[i].frequency < nyquist * 0.95 else {
                band.bypass = true
                continue
            }
            let b = s.preset.bands[i]
            switch b.kind {
            case .peak: band.filterType = .parametric
            case .lowShelf: band.filterType = .lowShelf
            case .highShelf: band.filterType = .highShelf
            }
            band.frequency = b.frequency
            band.gain = b.gain
            band.bandwidth = b.bandwidthOctaves
            band.bypass = false
        }
        eq.bypass = !s.active
    }

    /// Receives decoded (pre-volume) buffers while set; nil removes the tap.
    public func setTap(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        queue.async {
            self.tapHandler = handler
            self.reinstallTap()
        }
    }

    private func reinstallTap() {
        if tapInstalled {
            player.removeTap(onBus: 0)
            tapInstalled = false
        }
        guard let handler = tapHandler, connectedFormat != nil else { return }
        player.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in handler(buffer) }
        tapInstalled = true
    }

    public var currentTime: TimeInterval {
        lock.lock()
        let s = snapshot
        lock.unlock()
        if let t = s.pendingSeek { return t }
        guard s.rate > 0 else { return 0 }
        guard s.playing else { return s.pausedTime }
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let pt = player.playerTime(forNodeTime: nodeTime), pt.isSampleTimeValid else { return s.lastTime }
        let frames = s.baseFrame + max(0, pt.sampleTime - s.startNodeFrame)
        let t = max(Double(min(frames, s.length)) / s.rate, s.floor)
        updateSnapshot { if $0.playing, $0.pendingSeek == nil { $0.lastTime = t } }
        return t
    }

    // MARK: Internals (queue only)

    #if os(macOS)
    private func effectiveDevice() -> OutputDeviceID {
        selectedDevice != 0 ? selectedDevice : AudioHardware.defaultOutputDevice()
    }

    private func applyDevice() {
        guard let au = engine.outputNode.audioUnit else { return }
        var id = effectiveDevice()
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func releaseHog() {
        if hoggedDevice != 0 {
            AudioHardware.setHog(hoggedDevice, enabled: false)
            hoggedDevice = 0
        }
    }
    #else
    private func applyDevice() {}
    private func releaseHog() {}
    #endif

    private func resetScheduling() {
        inFlight = 0
        scheduledFrames = 0
        pending = []
        formatBreakURL = nil
        feedingDone = false
        orphanEnd = nil
    }

    private func updateSnapshot(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&snapshot)
        lock.unlock()
    }

    private func snapshotFromCurrent() {
        guard let c = current else { return }
        let playing = wantsPlaying
        updateSnapshot {
            $0.startNodeFrame = c.startNodeFrame
            $0.baseFrame = c.baseFrame
            $0.rate = c.decoder.processingFormat.sampleRate
            $0.length = c.decoder.lengthFrames
            $0.playing = playing
            $0.pausedTime = Double(c.baseFrame) / c.decoder.processingFormat.sampleRate
            $0.lastTime = $0.pausedTime
            $0.floor = 0
            $0.pendingSeek = nil
        }
    }

    private static func compatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    /// Makes sure the graph runs `format`, matching the device rate when enabled.
    private func configure(for format: AVAudioFormat) throws {
        #if os(macOS)
        let device = effectiveDevice()
        let targetRate = matchSampleRate ? AudioHardware.bestRate(for: format.sampleRate, device: device) : nil
        let rateOK = targetRate == nil || AudioHardware.nominalSampleRate(device) == targetRate
        if let cf = connectedFormat, Self.compatible(cf, format), rateOK, engine.isRunning { return }

        engine.stop()
        if selectedDevice != 0 { applyDevice() }
        if let r = targetRate { AudioHardware.setNominalSampleRate(device, r) }
        if exclusive, AudioHardware.setHog(device, enabled: true) { hoggedDevice = device }
        #else
        let session = AVAudioSession.sharedInstance()
        let rateOK = !matchSampleRate || session.sampleRate == format.sampleRate
        if let cf = connectedFormat, Self.compatible(cf, format), rateOK, engine.isRunning { return }

        engine.stop()
        if matchSampleRate { try? session.setPreferredSampleRate(format.sampleRate) }
        try? session.setActive(true)
        #endif

        if tapInstalled {
            player.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        let hw = engine.outputNode.outputFormat(forBus: 0)
        if hw.sampleRate > 0, let mixFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mixFormat)
        }
        engine.mainMixerNode.outputVolume = volume
        connectedFormat = format
        applyEQ()
        reinstallTap()
        engine.prepare()
        try engine.start()
        publishSignalPath()
    }

    private func publishSignalPath() {
        var path = SignalPath()
        if let f = current?.decoder.processingFormat {
            path.sourceRate = f.sampleRate
            path.sourceChannels = Int(f.channelCount)
        }
        #if os(macOS)
        let device = effectiveDevice()
        path.deviceName = AudioHardware.name(of: device)
        path.deviceRate = AudioHardware.nominalSampleRate(device)
        path.exclusive = hoggedDevice != 0 && AudioHardware.hogOwner(device) == getpid()
        #else
        let session = AVAudioSession.sharedInstance()
        path.deviceName = session.currentRoute.outputs.first?.portName ?? "iPhone"
        path.deviceRate = session.sampleRate
        #endif
        path.softwareVolume = volume
        if let g = current?.gain, g != 1 { path.gainDB = 20 * log10(g) }
        path.equalizer = eqSettings.active
        DispatchQueue.main.async { self.delegate?.engine(self, signalPathChanged: path) }
    }

    private func start(url: URL, at time: TimeInterval, autoplay: Bool) {
        generation += 1
        player.stop()
        resetScheduling()
        let decoder: AudioDecoder
        do {
            decoder = try DecoderFactory.makeDecoder(for: url)
        } catch {
            current = nil
            feeding = nil
            DispatchQueue.main.async { self.delegate?.engine(self, didFailToOpen: url, error: error) }
            return
        }
        let frame = Int64(time * decoder.processingFormat.sampleRate)
        try? decoder.seek(to: frame)
        let slot = Slot(decoder: decoder, url: url, startNodeFrame: 0, baseFrame: frame)
        current = slot
        feeding = slot
        wantsPlaying = autoplay
        do {
            try configure(for: decoder.processingFormat)
        } catch {
            DispatchQueue.main.async { self.delegate?.engine(self, didFailToOpen: url, error: error) }
            return
        }
        snapshotFromCurrent()
        fill()
        if autoplay { player.play() }
        publishSignalPath()
        DispatchQueue.main.async { self.delegate?.engine(self, didStart: url) }
    }

    /// Re-schedules the current track from `time`, keeping the queued next track.
    private func rebuild(at time: TimeInterval) {
        guard let cur = current else { return }
        generation += 1
        player.stop()
        if let p = pending.first { nextURL = p.url } else if let u = formatBreakURL { nextURL = u }
        resetScheduling()
        let rate = cur.decoder.processingFormat.sampleRate
        let frame = max(0, min(Int64(time * rate), cur.decoder.lengthFrames))
        try? cur.decoder.seek(to: frame)
        cur.startNodeFrame = 0
        cur.baseFrame = frame
        feeding = cur
        do {
            try configure(for: cur.decoder.processingFormat)
        } catch {
            DispatchQueue.main.async { self.delegate?.engine(self, didFailToOpen: cur.url, error: error) }
            return
        }
        snapshotFromCurrent()
        fill()
        if wantsPlaying { player.play() }
    }

    private func updateNext(_ url: URL?) {
        if let p = pending.first {
            if p.url != url {
                nextURL = url
                pending = []
                rebuild(at: currentTime)
            }
            return
        }
        if formatBreakURL != nil {
            formatBreakURL = url
            return
        }
        nextURL = url
        if feedingDone, let f = feeding, url != nil {
            feedingDone = false
            advanceFeeding(after: f)
            fill()
        }
    }

    private func fill() {
        while inFlight < Self.buffersInFlight, !feedingDone, let slot = feeding {
            let format = slot.decoder.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(format.sampleRate * Self.bufferSeconds)) else { return }
            let ok = (try? slot.decoder.read(into: buffer)) ?? false
            let atEnd = !ok || slot.decoder.positionFrames >= slot.decoder.lengthFrames
            if ok {
                if slot.gain == nil {
                    slot.gain = gainProvider?(slot.url) ?? 1
                    if slot === current { publishSignalPath() }
                }
                if let g = slot.gain, g != 1 { Self.scale(buffer, by: g) }
                schedule(buffer, endsSlot: atEnd ? slot : nil)
            } else if inFlight == 0 {
                queue.async { [gen = generation] in
                    if gen == self.generation { self.slotFinished(slot) }
                }
            } else {
                orphanEnd = slot
            }
            if atEnd { advanceFeeding(after: slot) }
        }
    }

    private static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard let data = buffer.floatChannelData else { return }
        var g = gain
        let n = vDSP_Length(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(data[c], 1, &g, data[c], 1, n)
        }
    }

    private func advanceFeeding(after slot: Slot) {
        guard let url = nextURL else {
            feedingDone = true
            return
        }
        nextURL = nil
        guard let decoder = try? DecoderFactory.makeDecoder(for: url),
              Self.compatible(decoder.processingFormat, slot.decoder.processingFormat) else {
            // Different format, or unreadable: handled by a full restart at the boundary.
            formatBreakURL = url
            feedingDone = true
            return
        }
        let next = Slot(decoder: decoder, url: url, startNodeFrame: scheduledFrames, baseFrame: 0)
        pending.append(next)
        feeding = next
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, endsSlot: Slot?) {
        let gen = generation
        inFlight += 1
        scheduledFrames += Int64(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.bufferDone(generation: gen, endsSlot: endsSlot) }
        }
    }

    private func bufferDone(generation gen: Int, endsSlot: Slot?) {
        guard gen == generation else { return }
        inFlight -= 1
        if let s = endsSlot { slotFinished(s) }
        if inFlight == 0, let o = orphanEnd {
            orphanEnd = nil
            slotFinished(o)
        }
        if gen == generation { fill() }
    }

    private func slotFinished(_ slot: Slot) {
        guard slot === current else { return }
        if !pending.isEmpty {
            let next = pending.removeFirst()
            current = next
            snapshotFromCurrent()
            publishSignalPath()
            DispatchQueue.main.async { self.delegate?.engine(self, didStart: next.url) }
        } else if let url = formatBreakURL {
            formatBreakURL = nil
            start(url: url, at: 0, autoplay: true)
        } else {
            generation += 1
            player.stop()
            engine.stop()
            resetScheduling()
            current = nil
            feeding = nil
            wantsPlaying = false
            updateSnapshot { $0 = Snapshot() }
            DispatchQueue.main.async { self.delegate?.engineDidReachEnd(self) }
        }
    }

    private func handleConfigurationChange() {
        // Late notifications for changes we made ourselves arrive after the engine restarted.
        if engine.isRunning { publishSignalPath(); return }
        connectedFormat = nil
        guard current != nil else { publishSignalPath(); return }
        if wantsPlaying {
            rebuild(at: currentTime)
        } else {
            publishSignalPath()
        }
    }
}

import AVFAudio
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif
import Combine
import Foundation
import MediaPlayer

public enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
}

/// Position ticks live separately so only time-dependent views redraw at 10 Hz.
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public internal(set) var time: TimeInterval = 0
    @Published public internal(set) var duration: TimeInterval = 0
}

/// What is restored on the next launch: the queue, the loaded track and its position, always paused.
public struct PlayerSnapshot: Codable, Sendable {
    public var queue: [String]
    public var index: Int?
    public var time: TimeInterval
    public var shuffle: Bool
    public var repeatMode: String
}

@MainActor
public final class PlayerController: ObservableObject, PlaybackEngineDelegate {
    @Published public private(set) var queue: [URL] = []
    @Published public private(set) var index: Int?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var current: TrackMetadata?
    @Published public private(set) var signalPath = SignalPath()
    @Published public private(set) var devices: [OutputDevice] = []
    @Published public private(set) var activeDeviceUID: String?
    @Published public var volume: Float { didSet { engine.setVolume(volume); defaults.set(volume, forKey: "volume") } }
    @Published public var shuffle = false { didSet { rebuildOrder(); updateNext() } }
    @Published public var repeatMode: RepeatMode = .off { didSet { updateNext() } }
    @Published public var matchSampleRate: Bool {
        didSet { engine.setMatchSampleRate(matchSampleRate); defaults.set(matchSampleRate, forKey: "matchSampleRate") }
    }
    @Published public var exclusiveMode: Bool {
        didSet { engine.setExclusive(exclusiveMode); defaults.set(exclusiveMode, forKey: "exclusiveMode") }
    }
    @Published public var replayGain: ReplayGainSettings {
        didSet {
            guard replayGain != oldValue else { return }
            gains.update(replayGain)
            Self.store(replayGain, "replayGain")
            let u = currentURL
            Task {
                if let u { await gains.prepare(u, analyze: false) }
                engine.refreshGains()
                updateNext()
                if let u { await gains.prepare(u, analyze: true) }
            }
        }
    }
    @Published public var equalizer: EQSettings {
        didSet {
            guard equalizer != oldValue else { return }
            engine.setEQ(equalizer)
            Self.store(equalizer, "equalizer")
        }
    }
    /// User and AutoEQ presets, after the built-in ones.
    @Published public var customPresets: [EQPreset] {
        didSet { Self.store(customPresets, "eqPresets") }
    }
    @Published public private(set) var artwork: PlatformImage?
    @Published public private(set) var deviceDetails = DeviceDetails()

    public let clock = PlaybackClock()
    public var currentURL: URL? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }

    private let engine = PlaybackEngine()
    public let gains = ReplayGainStore()
    private var startToken = 0
    private let metadata: MetadataStore
    private let defaults = UserDefaults.standard
    private var order: [Int] = []
    private var orderPos = 0
    private var ticker: Timer?
    private var preferredDeviceUID: String?
    private var startedURL: URL?
    private var interrupted = false

    public init(metadata: MetadataStore) {
        self.metadata = metadata
        volume = defaults.object(forKey: "volume") as? Float ?? 1
        matchSampleRate = defaults.object(forKey: "matchSampleRate") as? Bool ?? true
        exclusiveMode = defaults.bool(forKey: "exclusiveMode")
        preferredDeviceUID = defaults.string(forKey: "outputDeviceUID")
        replayGain = Self.load("replayGain") ?? ReplayGainSettings()
        equalizer = Self.load("equalizer") ?? EQSettings()
        customPresets = Self.load("eqPresets") ?? []
        gains.update(replayGain)
        engine.setGainProvider { [gains] in gains.linearGain(for: $0) }
        engine.setEQ(equalizer)
        engine.delegate = self
        engine.setVolume(volume)
        engine.setMatchSampleRate(matchSampleRate)
        engine.setExclusive(exclusiveMode)
        #if os(macOS)
        refreshDevices()
        AudioHardware.observeDevices { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        #else
        setupAudioSession()
        #endif
        setupRemoteCommands()
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func saveCustomPreset(_ preset: EQPreset) {
        customPresets.removeAll { $0.name == preset.name }
        customPresets.append(preset)
    }

    public func deleteCustomPreset(named name: String) {
        customPresets.removeAll { $0.name == name }
    }

    // MARK: Queue

    public func play(_ urls: [URL], startAt start: Int = 0) {
        guard !urls.isEmpty else { return }
        queue = urls
        index = min(max(start, 0), urls.count - 1)
        rebuildOrder()
        startCurrent(at: 0)
    }

    public func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if queue.isEmpty { play(urls); return }
        let base = queue.count
        queue += urls
        order += (base..<queue.count)
        updateNext()
    }

    public func playNext(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let i = index else { play(urls); return }
        let insertAt = i + 1
        queue.insert(contentsOf: urls, at: insertAt)
        order = order.map { $0 >= insertAt ? $0 + urls.count : $0 }
        order.insert(contentsOf: insertAt..<insertAt + urls.count, at: orderPos + 1)
        updateNext()
    }

    public func jump(toQueueIndex i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        if let p = order.firstIndex(of: i) { orderPos = p }
        startCurrent(at: 0)
    }

    public func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        order = order.filter { $0 != i }.map { $0 > i ? $0 - 1 : $0 }
        if let idx = index, i < idx { index = idx - 1 }
        orderPos = index.flatMap { order.firstIndex(of: $0) } ?? 0
        updateNext()
    }

    public func moveQueueItems(from source: IndexSet, to destination: Int) {
        let playing = currentURL.map { u in (u, index!) }
        var items = queue.enumerated().map { ($0.offset, $0.element) }
        let moving = source.sorted().map { items[$0] }
        for i in source.sorted(by: >) { items.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(insertAt, items.count)))
        queue = items.map(\.1)
        let remap = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.0, $0.offset) })
        order = order.compactMap { remap[$0] }
        if let p = playing { index = remap[p.1] }
        if !shuffle { order = Array(queue.indices) }
        orderPos = index.flatMap { order.firstIndex(of: $0) } ?? 0
        updateNext()
    }

    /// Live analysis tap on decoded audio; nil removes it.
    public func setAnalysisTap(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        engine.setTap(handler)
    }

    public func clearQueue() {
        engine.stop()
        queue = []
        index = nil
        order = []
        current = nil
        artwork = nil
        isPlaying = false
        clock.time = 0
        clock.duration = 0
        updateNowPlaying()
    }

    private func rebuildOrder() {
        let n = queue.count
        guard n > 0 else { order = []; orderPos = 0; return }
        let cur = index ?? 0
        if shuffle {
            var rest = Array(0..<n).filter { $0 != cur }
            rest.shuffle()
            order = [cur] + rest
            orderPos = 0
        } else {
            order = Array(0..<n)
            orderPos = cur
        }
    }

    private func nextIndex() -> Int? {
        guard !order.isEmpty else { return nil }
        if repeatMode == .one { return index }
        if orderPos + 1 < order.count { return order[orderPos + 1] }
        return repeatMode == .all ? order[0] : nil
    }

    private func previousIndex() -> Int? {
        guard !order.isEmpty else { return nil }
        if orderPos > 0 { return order[orderPos - 1] }
        return repeatMode == .all ? order.last : nil
    }

    private func updateNext() {
        let next = nextIndex().map { queue[$0] }
        engine.setNext(next)
        if let u = next, replayGain.mode != .off { Task { await gains.prepare(u, analyze: true) } }
    }

    // MARK: State

    public func snapshot() -> PlayerSnapshot {
        PlayerSnapshot(queue: queue.map(\.path), index: index,
                       time: startedURL != nil ? engine.currentTime : clock.time,
                       shuffle: shuffle, repeatMode: repeatMode.rawValue)
    }

    /// Loads the queue and track without starting playback; play resumes from the saved position.
    public func restore(_ s: PlayerSnapshot) {
        let fm = FileManager.default
        let kept = s.queue.enumerated().filter { fm.fileExists(atPath: $0.element) }
        guard !kept.isEmpty else { return }
        queue = kept.map { URL(fileURLWithPath: $0.element) }
        index = s.index.flatMap { i in kept.firstIndex { $0.offset == i } } ?? 0
        repeatMode = RepeatMode(rawValue: s.repeatMode) ?? .off
        shuffle = s.shuffle
        rebuildOrder()
        isPlaying = false
        startedURL = nil
        clock.time = kept.contains { $0.offset == s.index } ? max(0, s.time) : 0
        if let u = currentURL { loadMetadata(u) }
    }

    // MARK: Transport

    public func playPause() {
        if isPlaying {
            engine.pause()
            isPlaying = false
            stopTicker()
        } else if currentURL != nil {
            if startedURL == nil { startCurrent(at: clock.time) } else { engine.resume() }
            isPlaying = true
            startTicker()
        }
        updateNowPlaying()
    }

    public func next() {
        guard let n = nextIndex() ?? (order.isEmpty ? nil : order[(orderPos + 1) % order.count]) else { return }
        move(to: n)
    }

    public func previous() {
        if clock.time > 3 { seek(to: 0); return }
        guard let p = previousIndex() else { seek(to: 0); return }
        move(to: p)
    }

    private func move(to i: Int) {
        index = i
        if let p = order.firstIndex(of: i) { orderPos = p }
        startCurrent(at: 0)
    }

    public func seek(to t: TimeInterval) {
        guard currentURL != nil else { return }
        let target = max(0, min(t, clock.duration > 0 ? clock.duration - 0.05 : t))
        guard startedURL != nil else {
            clock.time = target
            updateNowPlaying()
            return
        }
        engine.seek(to: target)
        clock.time = target
        updateNowPlaying()
    }

    /// Sample-accurate position for smooth animation; `clock.time` ticks at 10 Hz.
    public var position: TimeInterval { startedURL != nil ? engine.currentTime : clock.time }

    public func seek(by delta: TimeInterval) {
        seek(to: (startedURL != nil ? engine.currentTime : clock.time) + delta)
    }

    /// Tags are read before the engine starts so the first buffer already carries the track's gain.
    private func startCurrent(at time: TimeInterval) {
        guard let url = currentURL else { return }
        startToken += 1
        if replayGain.mode == .off || gains.hasTagsLoaded(url) {
            engine.play(url: url, at: time)
            Task { await gains.prepare(url, analyze: true) }
        } else {
            let token = startToken
            Task {
                await gains.prepare(url, analyze: false)
                guard token == startToken else { return }
                engine.play(url: url, at: time)
                await gains.prepare(url, analyze: true)
            }
        }
        isPlaying = true
        startTicker()
        loadMetadata(url)
    }

    private func loadMetadata(_ url: URL) {
        Task {
            let m = await metadata.metadata(for: url)
            guard url == currentURL else { return }
            current = m
            clock.duration = m?.duration ?? 0
            updateNowPlaying()
            let img = await ArtworkCache.shared.image(forTrack: url)
            guard url == currentURL else { return }
            #if os(macOS)
            artwork = img.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            #else
            artwork = img.map { UIImage(cgImage: $0) }
            #endif
            updateNowPlaying()
        }
    }

    // MARK: Devices

    public func selectDevice(uid: String?) {
        preferredDeviceUID = uid
        defaults.set(uid, forKey: "outputDeviceUID")
        refreshDevices(force: true)
    }

    #if os(macOS)
    private func refreshDevices(force: Bool = false) {
        devices = AudioHardware.outputDevices()
        let target = preferredDeviceUID.flatMap { uid in devices.contains { $0.uid == uid } ? uid : nil }
        guard force || target != activeDeviceUID else { return }
        activeDeviceUID = target
        engine.setDevice(target.flatMap { AudioHardware.device(uid: $0) })
        refreshDeviceDetails()
    }

    private func refreshDeviceDetails() {
        let id = activeDeviceUID.flatMap { AudioHardware.device(uid: $0) } ?? AudioHardware.defaultOutputDevice()
        let d = AudioHardware.details(id)
        if d != deviceDetails { deviceDetails = d }
    }
    #else
    private func refreshDevices(force: Bool = false) {}

    private func refreshDeviceDetails() {
        let s = AVAudioSession.sharedInstance()
        var d = DeviceDetails()
        let out = s.currentRoute.outputs.first
        d.name = out?.portName ?? "iPhone"
        d.transport = out.map { Self.portLabel($0.portType) } ?? ""
        d.channels = s.outputNumberOfChannels
        d.sampleRate = s.sampleRate
        if d != deviceDetails { deviceDetails = d }
    }

    private static func portLabel(_ p: AVAudioSession.Port) -> String {
        switch p {
        case .builtInSpeaker: return "Speaker"
        case .headphones: return "Wired"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        case .airPlay: return "AirPlay"
        case .usbAudio: return "USB"
        case .carAudio: return "CarPlay"
        default: return p.rawValue
        }
    }

    /// Playback category for background audio; pauses on interruptions and when headphones are unplugged.
    private func setupAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio)
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let resume = ((n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began, self.isPlaying {
                    self.playPause()
                    self.interrupted = true
                } else if type == .ended, self.interrupted {
                    self.interrupted = false
                    if resume, !self.isPlaying { self.playPause() }
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable, self.isPlaying { self.playPause() }
                self.refreshDeviceDetails()
            }
        }
        refreshDeviceDetails()
    }
    #endif

    // MARK: Engine delegate

    nonisolated public func engine(_ engine: PlaybackEngine, didStart url: URL) {
        MainActor.assumeIsolated {
            startedURL = url
            if currentURL != url {
                if let n = nextIndex(), queue[n] == url {
                    move(toAudible: n)
                } else if let i = queue.firstIndex(of: url) {
                    move(toAudible: i)
                }
            }
            updateNext()
            updateNowPlaying()
        }
    }

    private func move(toAudible i: Int) {
        index = i
        if let p = order.firstIndex(of: i) { orderPos = p }
        clock.time = 0
        loadMetadata(queue[i])
    }

    nonisolated public func engineDidReachEnd(_ engine: PlaybackEngine) {
        MainActor.assumeIsolated {
            isPlaying = false
            startedURL = nil
            stopTicker()
            clock.time = 0
            updateNowPlaying()
        }
    }

    nonisolated public func engine(_ engine: PlaybackEngine, didFailToOpen url: URL, error: Error) {
        MainActor.assumeIsolated {
            NSLog("Kveikur: cannot play \(url.path): \(error)")
            guard url == currentURL, let n = nextIndex(), n != index else {
                isPlaying = false
                stopTicker()
                return
            }
            move(to: n)
        }
    }

    nonisolated public func engine(_ engine: PlaybackEngine, signalPathChanged path: SignalPath) {
        MainActor.assumeIsolated {
            signalPath = path
            refreshDeviceDetails()
        }
    }

    // MARK: Clock

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.time = self.engine.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        clock.time = engine.currentTime
    }

    // MARK: Now Playing / media keys

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ action: @escaping @MainActor (PlayerController) -> Void) {
            cmd.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
        }
        on(c.playCommand) { if !$0.isPlaying { $0.playPause() } }
        on(c.pauseCommand) { if $0.isPlaying { $0.playPause() } }
        on(c.togglePlayPauseCommand) { $0.playPause() }
        on(c.nextTrackCommand) { $0.next() }
        on(c.previousTrackCommand) { $0.previous() }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let url = currentURL else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current?.displayTitle ?? url.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: startedURL != nil ? engine.currentTime : clock.time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let a = current?.artist { info[MPMediaItemPropertyArtist] = a }
        if let a = current?.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if let img = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

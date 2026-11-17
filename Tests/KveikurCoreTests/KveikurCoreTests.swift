import CryptoKit
import AVFAudio
@testable import KveikurCore
import XCTest

final class FuzzyTests: XCTestCase {
    func testSubsequenceAndRanking() {
        let m = FuzzyMatcher("dsotm")
        XCTAssertNotNil(m.score(FuzzyMatcher.prepare("Dark Side of the Moon")))
        XCTAssertNil(m.score(FuzzyMatcher.prepare("Wish You Were Here")))

        let idx = FuzzyIndex(items: ["Pink Floyd/Animals", "Pink Floyd/The Wall", "Tool/Lateralus"], key: { $0 })
        XCTAssertEqual(idx.search("wall").first?.item, "Pink Floyd/The Wall")
        XCTAssertEqual(idx.search("pf an").first?.item, "Pink Floyd/Animals")
        XCTAssertEqual(idx.search("tool").count, 1)
    }

    func testBoundaryBeatsScattered() {
        let m = FuzzyMatcher("lat")
        let boundary = m.score(FuzzyMatcher.prepare("tool/lateralus"))!
        let scattered = m.score(FuzzyMatcher.prepare("bloated"))!
        XCTAssertGreaterThan(boundary, scattered)
    }
}

final class LyricsTests: XCTestCase {
    func testParseSynced() {
        let lrc = """
        [ar:Someone]
        [offset:500]
        [00:01.00]First
        [00:03.50][00:10.00]Chorus
        [00:05.25]Second
        """
        let l = LRCParser.parse(lrc, source: "t")
        XCTAssertTrue(l.synced)
        XCTAssertEqual(l.offset, 0.5, accuracy: 0.001)
        XCTAssertEqual(l.lines.map(\.text), ["First", "Chorus", "Second", "Chorus"])
        XCTAssertEqual(l.lines[2].time!, 5.25, accuracy: 0.001)
        XCTAssertNil(l.activeIndex(at: 1.2))
        XCTAssertEqual(l.activeIndex(at: 1.6), 0)
        XCTAssertEqual(l.activeIndex(at: 6.0), 2)
        XCTAssertEqual(l.activeIndex(at: 100), 3)

        let round = LRCParser.parse(LRCParser.serialize(l), source: "t")
        XCTAssertEqual(round.lines, l.lines)
        XCTAssertEqual(round.offset, l.offset, accuracy: 0.001)
    }

    func testPlain() {
        let l = LRCParser.parse("\nLine one\nLine two\n\n", source: "t")
        XCTAssertFalse(l.synced)
        XCTAssertEqual(l.lines.map(\.text), ["Line one", "Line two"])
    }

    func testGeniusExtraction() {
        let html = """
        <div data-lyrics-container="true" class="x"><div data-exclude-from-selection="true">5 Contributors</div>\
        [Verse 1]<br/>Hello <a href="#"><span>world</span></a><br>It&#x27;s me &amp; you</div>\
        <div>footer</div><div data-lyrics-container="true">Last line</div>
        """
        XCTAssertEqual(GeniusProvider.extractLyrics(html), "[Verse 1]\nHello world\nIt's me & you\nLast line")
    }
}

final class PlaylistTests: XCTestCase {
    func testRoundTrip() {
        let base = URL(fileURLWithPath: "/Music/Playlists")
        let entries = [
            PlaylistEntry(url: URL(fileURLWithPath: "/Music/Playlists/sub/a.flac"), title: "A - One", duration: 61),
            PlaylistEntry(url: URL(fileURLWithPath: "/Other/b.mp3"), title: nil, duration: nil),
        ]
        let text = M3U8.serialize(entries, relativeTo: base)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n#EXTINF:61,A - One\nsub/a.flac\n"))
        let parsed = M3U8.parse(text, relativeTo: base)
        XCTAssertEqual(parsed.map(\.url.path), ["/Music/Playlists/sub/a.flac", "/Other/b.mp3"])
        XCTAssertEqual(parsed[0].title, "A - One")
        XCTAssertEqual(parsed[0].duration, 61)
    }

    func testStoreEditing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PlaylistStore(folder: dir)
        let pl = try store.create(named: "Mix", with: ["a", "b", "c"].map { PlaylistEntry(url: dir.appendingPathComponent("\($0).flac")) })
        try store.move(from: 0, to: 2, in: pl)
        XCTAssertEqual(store.entries(pl).map(\.url.lastPathComponent), ["b.flac", "c.flac", "a.flac"])
        try store.remove(at: IndexSet(integer: 1), from: pl)
        XCTAssertEqual(store.entries(pl).map(\.url.lastPathComponent), ["b.flac", "a.flac"])
        XCTAssertEqual(store.playlists().map(\.lastPathComponent), ["Mix.m3u8"])
    }
}

final class TagTests: XCTestCase {
    private func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }

    private func comments(_ pairs: [String]) -> [UInt8] {
        var b = le32(3) + Array("ven".utf8) + le32(pairs.count)
        for p in pairs { b += le32(p.utf8.count) + Array(p.utf8) }
        return b
    }

    func testVorbisComments() {
        var bag = TagBag()
        XiphTags.parseComments(comments(["TITLE=Song", "ALBUMARTIST=Band", "TRACKNUMBER=3/12", "DATE=1999-05-01", "LYRICS=la la"]), into: &bag)
        var m = TrackMetadata(path: "/x.flac", mtime: 0, size: 0)
        bag.apply(to: &m)
        XCTAssertEqual(m.title, "Song")
        XCTAssertEqual(m.albumArtist, "Band")
        XCTAssertEqual(m.trackNumber, 3)
        XCTAssertEqual(m.trackTotal, 12)
        XCTAssertEqual(m.year, "1999")
        XCTAssertEqual(bag.lyrics, "la la")
    }

    func testFlacFile() throws {
        // STREAMINFO for 96 kHz / 24 bit / 2 ch / 960000 samples.
        var si = [UInt8](repeating: 0, count: 34)
        let rate = 96000, ch = 2, bps = 24
        let total: Int64 = 960_000
        si[10] = UInt8(rate >> 12)
        si[11] = UInt8((rate >> 4) & 0xFF)
        si[12] = UInt8(((rate & 0x0F) << 4) | ((ch - 1) << 1) | ((bps - 1) >> 4))
        si[13] = UInt8((((bps - 1) & 0x0F) << 4) | Int((total >> 32) & 0x0F))
        for i in 0..<4 { si[14 + i] = UInt8((total >> (24 - 8 * Int64(i))) & 0xFF) }
        let vc = comments(["ARTIST=Artist", "TITLE=T"])
        func header(_ type: UInt8, last: Bool, _ len: Int) -> [UInt8] {
            [type | (last ? 0x80 : 0), UInt8(len >> 16), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        }
        let bytes = Array("fLaC".utf8) + header(0, last: false, 34) + si + header(4, last: true, vc.count) + vc
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).flac")
        try Data(bytes).write(to: url)
        XCTAssertEqual(ContainerSniffer.sniff(url), .flac)
        let r = try XCTUnwrap(XiphTags.readFLAC(url, wantPicture: false))
        XCTAssertEqual(r.streamInfo?.sampleRate, 96000)
        XCTAssertEqual(r.streamInfo?.bitsPerSample, 24)
        XCTAssertEqual(r.streamInfo?.channels, 2)
        XCTAssertEqual(r.streamInfo?.totalSamples, total)
        XCTAssertEqual(r.tags.values["artist"], "Artist")
    }
}

final class LibraryTests: XCTestCase {
    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite")
        let store = try LibraryStore(url: url)
        var t = TrackMetadata(path: "/Music/A/01.flac", mtime: 10, size: 100)
        t.title = "One"
        t.trackNumber = 1
        t.format = SourceFormat(codec: "FLAC", sampleRate: 44100, bitDepth: 16, channels: 2, lossless: true)
        var u = TrackMetadata(path: "/Music/B/02.mp3", mtime: 11, size: 200)
        u.artist = "X"
        store.upsert([t, u])
        XCTAssertEqual(store.tracks(inFolder: "/Music/A")["/Music/A/01.flac"], t)
        XCTAssertEqual(store.stamps(underRoot: "/Music").count, 2)
        XCTAssertEqual(store.stamps(underRoot: "/Mus").count, 0)
        store.delete(paths: ["/Music/B/02.mp3"])
        XCTAssertEqual(store.trackCount(), 1)
        store.replaceFolders(root: "/Music", folders: ["/Music", "/Music/A"])
        XCTAssertEqual(store.allFolders(), ["/Music", "/Music/A"])
    }

    func testDecomposedPathsMatchComposed() throws {
        let nfc = "/Music/toe/04. 街のどこかで.mp3"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite")
        _ = try LibraryStore(url: url)
        let raw = try SQLiteDB(path: url.path)
        try raw.prepare("INSERT INTO tracks(path, folder, mtime, size) VALUES(?, '/Music/toe', 1, 1)").bind([nfd]).run()

        let store = try LibraryStore(url: url)
        XCTAssertEqual(store.trackCount(), 0)

        var t = TrackMetadata(path: nfd, mtime: 1, size: 1)
        t.title = "街のどこかで"
        store.upsert([t])
        XCTAssertEqual(store.track(path: nfc)?.title, t.title)
        XCTAssertEqual(store.tracks(inFolder: "/Music/toe").count, 1)

        let meta = MetadataStore(library: store)
        let exp = expectation(description: "load")
        _ = meta.load(folder: "/Music/toe", files: [FileStamp(url: URL(fileURLWithPath: nfc), mtime: 1, size: 1)]) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(meta.cached(nfd)?.title, t.title)
        XCTAssertEqual(meta.cached(nfc)?.title, t.title)
    }
}

/// Reads and decodes every file under $KVEIKUR_SAMPLES; skipped when unset.
final class SampleLibraryTests: XCTestCase {
    func testReadAndDecodeSamples() async throws {
        guard let dir = ProcessInfo.processInfo.environment["KVEIKUR_SAMPLES"] else { throw XCTSkip("KVEIKUR_SAMPLES not set") }
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)!
        var count = 0
        while let u = walker.nextObject() as? URL {
            guard AudioFiles.isAudio(u) else { continue }
            count += 1
            let read = await MetadataReader.read(u)
            let m = try XCTUnwrap(read, u.lastPathComponent)
            print("SAMPLE \(u.lastPathComponent): \(m.displayTitle) | \(m.artist ?? "-") | \(m.album ?? "-") | #\(m.trackNumber ?? 0) | \(m.format?.shortLabel ?? "?") | \(Int(m.duration))s | \(m.bitrate)kbps")
            XCTAssertNotNil(m.title, u.lastPathComponent)
            XCTAssertGreaterThan(m.duration, 1, u.lastPathComponent)
            let d = try DecoderFactory.makeDecoder(for: u)
            let buf = AVAudioPCMBuffer(pcmFormat: d.processingFormat, frameCapacity: 4096)!
            XCTAssertTrue(try d.read(into: buf), u.lastPathComponent)
            try d.seek(to: d.lengthFrames / 2)
            XCTAssertTrue(try d.read(into: buf), "seek \(u.lastPathComponent)")
            let art = await MetadataReader.embeddedArtwork(u)
            let lyr = await MetadataReader.embeddedLyrics(u)
            print("SAMPLE   art=\(art?.count ?? 0) lyrics=\(lyr ?? "-")")
        }
        XCTAssertGreaterThan(count, 0)
    }
}

/// Plays generated WAV files through the real output device (silence, short).
final class EngineTests: XCTestCase {
    private final class Recorder: PlaybackEngineDelegate {
        var started: [(URL, Date)] = []
        var ended: XCTestExpectation?
        var startedSecond: XCTestExpectation?
        var startedThird: XCTestExpectation?
        func engine(_ engine: PlaybackEngine, didStart url: URL) {
            started.append((url, Date()))
            if started.count == 2 { startedSecond?.fulfill() }
            if started.count == 3 { startedThird?.fulfill() }
        }
        func engineDidReachEnd(_ engine: PlaybackEngine) { ended?.fulfill() }
        func engine(_ engine: PlaybackEngine, didFailToOpen url: URL, error: Error) { XCTFail("open failed \(error)") }
        func engine(_ engine: PlaybackEngine, signalPathChanged path: SignalPath) {}
    }

    private func wav(_ name: String, rate: Double, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        try file.write(from: buf)
        return url
    }

    func testPauseResumeAndSeekKeepPosition() throws {
        let url = try wav("long", rate: 44100, seconds: 6)
        let engine = PlaybackEngine()
        engine.setMatchSampleRate(false)
        var samples: [TimeInterval] = []
        func sample(for seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                samples.append(engine.currentTime)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        engine.play(url: url)
        sample(for: 1.0)
        engine.pause()
        let paused = engine.currentTime
        XCTAssertGreaterThan(paused, 0.5, "pause must not report the track start")
        samples = []
        sample(for: 0.6)
        XCTAssertTrue(samples.allSatisfy { abs($0 - paused) < 0.001 }, "position must stay frozen while paused: \(samples)")
        engine.resume()
        samples = []
        sample(for: 0.6)
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $1 >= $0 - 0.001 }, "position must not go back after resume: paused=\(paused) \(samples)")
        XCTAssertGreaterThanOrEqual(samples.first ?? 0, paused - 0.001)
        XCTAssertEqual(samples.last ?? 0, paused + 0.6, accuracy: 0.25)

        engine.seek(to: 4.0)
        XCTAssertEqual(engine.currentTime, 4.0, accuracy: 0.001, "seek target shows immediately")
        samples = []
        sample(for: 0.5)
        XCTAssertTrue(samples.allSatisfy { $0 >= 4.0 - 0.001 }, "no bounce back to the old position after seek: \(samples)")
        engine.stop()
    }

    func testGaplessThenFormatChange() throws {
        let a = try wav("a", rate: 44100, seconds: 0.8)
        let b = try wav("b", rate: 44100, seconds: 0.8)
        let c = try wav("c", rate: 48000, seconds: 0.5)
        let engine = PlaybackEngine()
        let rec = Recorder()
        rec.startedSecond = expectation(description: "second")
        rec.startedThird = expectation(description: "third")
        rec.ended = expectation(description: "end")
        engine.delegate = rec
        engine.setMatchSampleRate(false)
        engine.play(url: a)
        engine.setNext(b)

        wait(for: [rec.startedSecond!], timeout: 5)
        XCTAssertEqual(rec.started.map(\.0), [a, b])
        let gap = rec.started[1].1.timeIntervalSince(rec.started[0].1)
        XCTAssertEqual(gap, 0.8, accuracy: 0.25, "second track should start right when the first ends")
        engine.setNext(c)
        wait(for: [rec.startedThird!], timeout: 5)
        XCTAssertEqual(rec.started.last?.0, c)
        engine.setNext(nil)
        wait(for: [rec.ended!], timeout: 5)
    }
}

final class AnalysisTests: XCTestCase {
    /// 1 kHz sine at amplitude 0.5 in both channels: −6 dBFS peak, −9 dBFS RMS, ≈ −6 LUFS (BS.1770).
    func testSineMeasurements() throws {
        let rate = 48000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sine-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            ])
            let n = Int(rate * 6)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = buf.frameCapacity
            for i in 0..<n {
                let v = Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / rate))
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
        }
        try file.write(from: buf)
        }

        let a = try TrackAnalyzer.analyze(url)
        XCTAssertEqual(a.samplePeakDB, -6.02, accuracy: 0.1)
        XCTAssertEqual(a.rmsDB, -9.03, accuracy: 0.2)
        XCTAssertEqual(a.integratedLUFS ?? 0, -6.0, accuracy: 0.4)
        XCTAssertFalse(a.waveform.isEmpty)
        XCTAssertNotNil(a.spectrogram)
        let peakBin = a.spectrum.indices.max { a.spectrum[$0] < a.spectrum[$1] }!
        let hz = Double(peakBin) / Double(a.spectrum.count) * rate / 2
        XCTAssertEqual(hz, 1000, accuracy: rate / 2 / Double(a.spectrum.count) * 2)
    }
}

@MainActor
final class PlayerStateTests: XCTestCase {
    func testRestoreIsPausedAtSavedPosition() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kveikur-state-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore(url: dir.appendingPathComponent("lib.sqlite"))
        let player = PlayerController(metadata: MetadataStore(library: store))
        let a = dir.appendingPathComponent("a.wav").path
        FileManager.default.createFile(atPath: a, contents: Data())
        let gone = dir.appendingPathComponent("missing.wav").path
        player.restore(PlayerSnapshot(queue: [gone, a], index: 1, time: 42, shuffle: false, repeatMode: "all"))
        XCTAssertEqual(player.queue.map(\.path), [a])
        XCTAssertEqual(player.currentURL?.path, a)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.clock.time, 42)
        XCTAssertEqual(player.repeatMode, .all)
        player.seek(by: 5)
        XCTAssertEqual(player.clock.time, 47)
        XCTAssertEqual(player.snapshot().time, 47)
    }
}

final class LyricsQueryTests: XCTestCase {
    func testCleanedTitle() {
        func clean(_ t: String) -> String {
            LyricsQuery(url: URL(fileURLWithPath: "/x"), title: t, artist: "", album: nil, duration: 0).cleanedTitle
        }
        XCTAssertEqual(clean("03 Hate That You Know Me"), "Hate That You Know Me")
        XCTAssertEqual(clean("01. Intro"), "Intro")
        XCTAssertEqual(clean("Round (feat. Wet)"), "Round")
        XCTAssertEqual(clean("Let It Be - 2009 Remastered"), "Let It Be")
        XCTAssertEqual(clean("Song [Live at Wembley]"), "Song")
        XCTAssertEqual(clean("Smoke (Remix)"), "Smoke")
        XCTAssertEqual(clean("1979"), "1979")
    }

    func testLRCLibLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVEIKUR_NETWORK"] != nil)
        let q = LyricsQuery(url: URL(fileURLWithPath: "/x"), title: "Hate That You Know Me", artist: "Bleachers",
                            album: "Gone Now", duration: 185)
        let raw = try await LRCLibProvider().fetch(q)
        XCTAssertNotNil(raw)
        XCTAssertTrue(LRCParser.parse(raw ?? "", source: "t").synced)
    }
}

final class DSPTests: XCTestCase {
    private func sine(seconds: Double = 3, amplitude: Float = 0.5) throws -> URL {
        let rate = 48000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rg-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            ])
            let n = Int(rate * seconds)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = buf.frameCapacity
            for i in 0..<n {
                let v = amplitude * Float(sin(2 * Double.pi * 1000 * Double(i) / rate))
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            try file.write(from: buf)
        }
        return url
    }

    func testReplayGainTags() {
        let rg = ReplayGainInfo.parse(["replaygain_track_gain": "-7.25 dB", "replaygain_track_peak": "0.98",
                                       "replaygain_album_gain": "+1.5 dB"])
        XCTAssertEqual(rg?.trackGain, -7.25)
        XCTAssertEqual(rg?.albumGain, 1.5)
        XCTAssertEqual(ReplayGainInfo.parse(["r128_track_gain": "-512"])?.trackGain, 3)
        XCTAssertNil(ReplayGainInfo.parse(["title": "x"]))
    }

    func testGainModesAndClipping() {
        let info = ReplayGainInfo(trackGain: -6, trackPeak: 0.5, albumGain: 4, albumPeak: 0.8, source: .tags)
        var s = ReplayGainSettings()
        XCTAssertNil(info.gainDB(s))
        s.mode = .track
        XCTAssertEqual(info.gainDB(s), -6)
        s.mode = .album
        XCTAssertEqual(info.gainDB(s)!, -20 * log10(0.8), accuracy: 0.01, "album +4 dB capped by the 0.8 peak")
        s.preventClipping = false
        s.preampDB = 2
        XCTAssertEqual(info.gainDB(s), 6)
    }

    func testAutoEQImport() {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.70
        Filter 2: ON PK Fc 2240 Hz Gain -3.1 dB Q 1.92
        Filter 3: OFF PK Fc 5000 Hz Gain 2 dB Q 1
        Filter 4: ON HSC Fc 10000 Hz Gain -1.2 dB Q 0.70
        """
        let p = EQPreset.parseAutoEQ(text, name: "HD 650")!
        XCTAssertEqual(p.preamp, -6.4)
        XCTAssertEqual(p.bands.map(\.kind), [.lowShelf, .peak, .highShelf])
        XCTAssertEqual(p.bands[1].frequency, 2240)
        XCTAssertEqual(p.bands[1].q, 1.92)
        XCTAssertFalse(p.isGraphic)
        XCTAssertNil(EQPreset.parseAutoEQ("hello", name: "x"))
    }

    func testResponseCurve() {
        let p = EQPreset(name: "t", preamp: -2, bands: [EQBand(.peak, frequency: 1000, gain: 6, q: 1.41)], isGraphic: false)
        XCTAssertEqual(p.responseDB(at: 1000), 4, accuracy: 0.05)
        XCTAssertEqual(p.responseDB(at: 20), -2, accuracy: 0.1)
        let shelf = EQBand(.lowShelf, frequency: 100, gain: 6, q: 0.7)
        XCTAssertEqual(shelf.responseDB(at: 20, sampleRate: 48000), 6, accuracy: 0.5)
        XCTAssertEqual(shelf.responseDB(at: 10000, sampleRate: 48000), 0, accuracy: 0.1)
    }

    /// 0.5 amplitude sine ≈ −6 LUFS, so ReplayGain 2.0 (−18 LUFS) is ≈ −12 dB.
    func testMeasureUntagged() throws {
        let r = try ReplayGainStore.measure(try sine())
        XCTAssertEqual(r.gain, -12, accuracy: 0.5)
        XCTAssertEqual(r.peak, 0.5, accuracy: 0.01)
    }

    func testEngineAppliesGain() throws {
        let url = try sine(seconds: 2)
        let engine = PlaybackEngine()
        engine.setMatchSampleRate(false)
        engine.setGainProvider { _ in 0.5 }
        let lock = NSLock()
        nonisolated(unsafe) var peak: Float = 0
        engine.setTap { buf in
            guard let d = buf.floatChannelData else { return }
            var m: Float = 0
            for i in 0..<Int(buf.frameLength) { m = max(m, abs(d[0][i])) }
            lock.withLock { peak = max(peak, m) }
        }
        engine.play(url: url)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        engine.stop()
        XCTAssertEqual(lock.withLock { peak }, 0.25, accuracy: 0.01)
    }
}

final class ScrobbleTests: XCTestCase {
    func testThresholdAndCounter() {
        XCTAssertNil(ScrobbleRules.threshold(duration: 30))
        XCTAssertEqual(ScrobbleRules.threshold(duration: 200), 100)
        XCTAssertEqual(ScrobbleRules.threshold(duration: 900), 240)
        var c = ListenCounter(duration: 100)
        XCTAssertFalse(c.add(49))
        XCTAssertTrue(c.add(1))
        XCTAssertFalse(c.add(30), "reports only once")
        var short = ListenCounter(duration: 20)
        XCTAssertFalse(short.add(20))
    }

    func testLastFMSignatureAndEncoding() {
        let p = ["method": "auth.getToken", "api_key": "KEY", "format": "json"]
        let expected = Insecure.MD5.hash(data: Data("api_keyKEYmethodauth.getTokenSECRET".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(LastFMService.signature(p, secret: "SECRET"), expected)
        XCTAssertEqual(LastFMService.formEncode(["track": "Rock & Roll + Me", "a": "é"]), "a=%C3%A9&track=Rock%20%26%20Roll%20%2B%20Me")
    }

    private final class FakeService: ScrobbleService, @unchecked Sendable {
        let id = "fake"
        var fail: ScrobbleError?
        var received: [ScrobbleTrack] = []
        func nowPlaying(_ track: ScrobbleTrack) async throws {}
        func scrobble(_ tracks: [ScrobbleTrack]) async throws {
            if let f = fail { throw f }
            received += tracks
        }
    }

    func testQueueRetriesAndPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scrob-\(UUID())")
        let t = ScrobbleTrack(artist: "A", title: "T", duration: 200, timestamp: 1_700_000_000)
        let svc = FakeService()
        svc.fail = .service("offline")
        let q = ScrobbleQueue(directory: dir)
        await q.add(t, for: ["fake"])
        await q.flush([svc])
        let afterFailure = await q.count(for: "fake")
        XCTAssertEqual(afterFailure, 1, "transient failure keeps the scrobble")

        let reloaded = ScrobbleQueue(directory: dir)
        let persisted = await reloaded.count(for: "fake")
        XCTAssertEqual(persisted, 1)
        svc.fail = nil
        await reloaded.flush([svc])
        let afterSuccess = await reloaded.count(for: "fake")
        XCTAssertEqual(afterSuccess, 0)
        XCTAssertEqual(svc.received, [t])

        svc.fail = .http(401, "bad token")
        await reloaded.add(t, for: ["fake"])
        await reloaded.flush([svc])
        let afterAuthError = await reloaded.count(for: "fake")
        XCTAssertEqual(afterAuthError, 0, "auth errors drop instead of retrying forever")
    }
}

final class TagWriterTests: XCTestCase {
    private func encoded(_ ext: String, _ format: AudioFormatID) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID()).\(ext)")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try autoreleasepool {
            var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2]
            if format == kAudioFormatFLAC { settings[AVLinearPCMBitDepthKey] = 16 }
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 44100)!
            buf.frameLength = buf.frameCapacity
            for i in 0..<Int(buf.frameLength) {
                let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / 44100))
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            try file.write(from: buf)
        }
        return url
    }

    private func audioFrames(_ url: URL) throws -> AVAudioFramePosition {
        try AVAudioFile(forReading: url).length
    }

    func testFLACRoundTrip() async throws {
        let url = try encoded("flac", kAudioFormatFLAC)
        let frames = try audioFrames(url)
        var e = TagEdit()
        e[.title] = "Brennisteinn"
        e[.artist] = "Sigur Rós"
        e[.year] = "2013"
        e[.track] = "1"
        e[.trackTotal] = "9"
        try await TagWriter.write(e, to: url)
        var m = await MetadataReader.read(url)
        XCTAssertEqual(m?.title, "Brennisteinn")
        XCTAssertEqual(m?.artist, "Sigur Rós")
        XCTAssertEqual(m?.year, "2013")
        XCTAssertEqual(m?.trackNumber, 1)
        XCTAssertEqual(m?.trackTotal, 9)
        XCTAssertEqual(try audioFrames(url), frames)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        var e2 = TagEdit()
        e2[.title] = "Hrafntinna"
        e2[.artist] = ""
        try await TagWriter.write(e2, to: url)
        m = await MetadataReader.read(url)
        XCTAssertEqual(m?.title, "Hrafntinna")
        XCTAssertNil(m?.artist)
        XCTAssertEqual(m?.year, "2013")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, size, "fits in padding")
        XCTAssertEqual(try audioFrames(url), frames)
    }

    func testMP4RoundTrip() async throws {
        let url = try encoded("m4a", kAudioFormatMPEG4AAC)
        var e = TagEdit()
        e[.title] = "Ísjaki"
        e[.album] = "Kveikur"
        e[.track] = "3"
        e[.trackTotal] = "9"
        try await TagWriter.write(e, to: url)
        let m = await MetadataReader.read(url)
        XCTAssertEqual(m?.title, "Ísjaki")
        XCTAssertEqual(m?.album, "Kveikur")
        XCTAssertEqual(m?.trackNumber, 3)
        XCTAssertEqual(m?.trackTotal, 9)
        XCTAssertGreaterThan(m?.duration ?? 0, 0.9)
    }

    func testID3InPlaceAndGrow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("id3-\(UUID()).mp3")
        var file = ID3Writer.header(major: 3, size: 64)
        let old = ID3Writer.textFrame("TIT2", "Old", major: 3) + ID3Writer.textFrame("TXXX", "\0keep", major: 3)
        file.append(old)
        file.append(Data(count: 64 - old.count))
        let audio = Data((0..<4096).map { UInt8($0 & 0xFF) })
        file.append(audio)
        try file.write(to: url)

        var e = TagEdit()
        e[.title] = "街のどこかで"
        try ID3Writer.write(e, to: url)
        var data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, file.count, "rewritten in place")
        var tag = try XCTUnwrap(ID3Writer.parse(data))
        XCTAssertEqual(tag.frames.map(\.id), ["TXXX", "TIT2"])
        XCTAssertEqual(data.suffix(audio.count), audio)

        e = TagEdit()
        e[.album] = String(repeating: "Ágætis byrjun ", count: 10)
        e[.track] = "4"
        e[.trackTotal] = "10"
        try ID3Writer.write(e, to: url)
        data = try Data(contentsOf: url)
        tag = try XCTUnwrap(ID3Writer.parse(data))
        XCTAssertEqual(Set(tag.frames.map(\.id)), ["TXXX", "TIT2", "TALB", "TRCK"])
        XCTAssertEqual(data.count, tag.totalSize + audio.count)
        XCTAssertEqual(data.suffix(audio.count), audio)
        let trck = try XCTUnwrap(tag.frames.first { $0.id == "TRCK" })
        XCTAssertEqual(String(decoding: trck.raw.dropFirst(11), as: UTF8.self), "4/10")
    }

    func testRenameMovesSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ren-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let track = dir.appendingPathComponent("01 a.flac")
        try Data().write(to: track)
        try Data().write(to: dir.appendingPathComponent("01 a.lrc"))
        let moves = try FileOperations.rename(track, to: "01 b.flac")
        XCTAssertEqual(moves.map(\.1.lastPathComponent), ["01 b.flac", "01 b.lrc"])
        XCTAssertThrowsError(try FileOperations.rename(dir.appendingPathComponent("01 b.flac"), to: "x/y"))
        XCTAssertEqual(FileOperations.remap(URL(fileURLWithPath: dir.path + "/01 a.flac"), moves)?.lastPathComponent, "01 b.flac")
        XCTAssertEqual(FileOperations.remap(URL(fileURLWithPath: "/elsewhere/x.flac"), moves), nil)
    }
}

final class CueTests: XCTestCase {
    private func image(seconds: Double, in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * seconds))!
            buf.frameLength = buf.frameCapacity
            try file.write(from: buf)
        }
        return url
    }

    func testParseTokensTimesAndEncodings() throws {
        XCTAssertEqual(CueSheet.tokens(#"  TITLE "Ágætis byrjun" "#), ["TITLE", "Ágætis byrjun"])
        XCTAssertEqual(CueSheet.tokens(#"FILE "a b.wav" WAVE"#), ["FILE", "a b.wav", "WAVE"])
        XCTAssertEqual(CueSheet.time("01:02:37")!, 62.4933, accuracy: 0.001)
        let cyr = "PERFORMER \"Кино\"\r\nTITLE \"Группа крови\"\r\n"
        XCTAssertEqual(CueSheet.decode(cyr.data(using: .windowsCP1251)!), cyr)
        XCTAssertEqual(CueSheet.decode(Data([0xEF, 0xBB, 0xBF]) + Data("TITLE \"x\"".utf8)), "TITLE \"x\"")
    }

    func testSheetSplitsImageAndTracksPlayAsSegments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = try image(seconds: 6, in: dir, name: "Sigur Rós - Rarities.wav")
        let loose = try image(seconds: 1, in: dir, name: "bonus.wav")
        let cue = dir.appendingPathComponent("Sigur Rós - Rarities.cue")
        try """
        REM GENRE Rock\r
        REM DATE 2019\r
        PERFORMER "Sigur Ros"\r
        TITLE "Rarities"\r
        FILE "Sigur Ros - Rarities.flac" WAVE\r
          TRACK 01 AUDIO\r
            TITLE "One"\r
            INDEX 01 00:00:00\r
          TRACK 02 AUDIO\r
            TITLE "Two"\r
            PERFORMER "Guest"\r
            INDEX 00 00:01:50\r
            INDEX 01 00:02:00\r
        """.write(to: cue, atomically: true, encoding: .utf8)

        let sheet = try XCTUnwrap(CueTrackRef.sheet(cue))
        XCTAssertEqual(sheet.splitFiles.map(\.lastPathComponent), [img.lastPathComponent], "accent-stripped name resolves")
        XCTAssertEqual(sheet.tracks.map(\.start), [0, 2])

        let t2 = CueTrackRef.url(cue, 2)
        let read = await MetadataReader.read(t2)
        let m = try XCTUnwrap(read)
        XCTAssertEqual(m.title, "Two")
        XCTAssertEqual(m.artist, "Guest")
        XCTAssertEqual(m.album, "Rarities")
        XCTAssertEqual(m.year, "2019")
        XCTAssertEqual(m.trackNumber, 2)
        XCTAssertEqual(m.trackTotal, 2)
        XCTAssertEqual(m.duration, 4, accuracy: 0.01)
        let m1 = await MetadataReader.read(CueTrackRef.url(cue, 1))
        XCTAssertEqual(m1?.duration ?? 0, 2, accuracy: 0.01)

        let d = try DecoderFactory.makeDecoder(for: t2)
        XCTAssertEqual(d.lengthFrames, 4 * 44100)
        let buf = AVAudioPCMBuffer(pcmFormat: d.processingFormat, frameCapacity: 3 * 44100)!
        var total: Int64 = 0
        while try d.read(into: buf) { total += Int64(buf.frameLength) }
        XCTAssertEqual(total, 4 * 44100)
        try d.seek(to: 44100)
        XCTAssertEqual(d.positionFrames, 44100)

        let walk = CueFolders.expand(audio: [img, loose], cues: [cue])
        XCTAssertEqual(Set(walk.map(\.lastPathComponent)), ["01", "02", "bonus.wav"])
        XCTAssertTrue(CueTrackRef.exists(t2))
        XCTAssertFalse(CueTrackRef.exists(CueTrackRef.url(cue, 3)))
        XCTAssertEqual(CueTrackRef.audioFile(t2).path, img.path)
        XCTAssertEqual(CueFolders.listing(of: t2).path, dir.path)
        XCTAssertFalse(TagWriter.canWrite(t2))
    }

    func testPerFileSheetsAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try image(seconds: 1, in: dir, name: "01. Fuel.wav")
        _ = try image(seconds: 1, in: dir, name: "02. Memory.wav")
        let cue = dir.appendingPathComponent("Reload.cue")
        try """
        FILE "01. Fuel.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "02. Memory.wav" WAVE
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """.write(to: cue, atomically: true, encoding: .utf8)
        XCTAssertNil(CueSheet.load(cue))
    }
}

final class DuplicateTests: XCTestCase {
    private func track(_ path: String, _ title: String?, artist: String? = "Artist", album: String? = "Album",
                       duration: Double = 200, lossless: Bool, size: Int64 = 1_000) -> TrackMetadata {
        var t = TrackMetadata(path: path, mtime: 1, size: size)
        t.title = title
        t.artist = artist
        t.album = album
        t.duration = duration
        t.bitrate = lossless ? 900 : 320
        t.format = SourceFormat(codec: lossless ? "FLAC" : "MP3", sampleRate: 44_100, bitDepth: lossless ? 16 : 0, channels: 2, lossless: lossless)
        return t
    }

    func testAlbumCopiesGroupAndLosslessWins() {
        let titles = ["One", "Two", "Three", "Four"]
        var all: [TrackMetadata] = []
        for (i, t) in titles.enumerated() {
            all.append(track("/M/Album (MP3)/0\(i + 1) \(t).mp3", t, duration: 200 + Double(i * 30), lossless: false))
            all.append(track("/M/Album [FLAC]/0\(i + 1) \(t).flac", t, duration: 201 + Double(i * 30), lossless: true, size: 30_000))
        }
        // Same title, very different length: a different recording.
        all.append(track("/M/Live/One.flac", "One", album: "Live", duration: 420, lossless: true))
        let groups = DuplicateFinder.find(all)
        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(g.kind, .album)
        XCTAssertEqual(Set(g.versions.map(\.path)), ["/M/Album (MP3)", "/M/Album [FLAC]"])
        XCTAssertEqual(g.versions.first { $0.isBest }?.path, "/M/Album [FLAC]")
        XCTAssertEqual(g.reclaimable, 4_000)
    }

    func testUntaggedFilesMatchByName() {
        let all = [
            track("/M/a/01 - Песня.mp3", nil, artist: nil, album: nil, lossless: false),
            track("/M/b/Песня.flac", nil, artist: nil, album: nil, duration: 201, lossless: true),
            track("/M/c/Другая.flac", nil, artist: nil, album: nil, lossless: true),
        ]
        let groups = DuplicateFinder.find(all)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .track)
        XCTAssertEqual(groups[0].versions.count, 2)
    }
}

final class HistoryTests: XCTestCase {
    func testPlaysAggregateAndFeedSmartLists() throws {
        let store = try LibraryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"))
        var a = TrackMetadata(path: "/M/a.flac", mtime: 2, size: 1)
        a.artist = "Sigur Rós"; a.album = "()"; a.title = "Untitled"; a.duration = 300
        var b = TrackMetadata(path: "/M/b.flac", mtime: 1, size: 1)
        b.artist = "sigur rós"; b.title = "Other"; b.duration = 60
        let c = TrackMetadata(path: "/M/c.flac", mtime: 3, size: 1)
        store.upsert([a, b, c])
        let now = Date()
        store.recordPlay(a, at: now.addingTimeInterval(-86_400 * 40))
        store.recordPlay(a, at: now)
        store.recordPlay(b, at: now.addingTimeInterval(-60))

        let all = store.stats(since: nil)
        XCTAssertEqual(all.plays, 3)
        XCTAssertEqual(all.seconds, 660)
        XCTAssertEqual(all.artists, 1)
        XCTAssertEqual(all.topArtists.first?.plays, 3)
        XCTAssertEqual(all.topTracks.first?.key, a.path)

        let month = store.stats(since: Calendar.current.date(byAdding: .day, value: -30, to: now))
        XCTAssertEqual(month.plays, 2)
        XCTAssertEqual(month.days.count, 31)
        XCTAssertEqual(month.days.last?.seconds, 360)

        XCTAssertEqual(store.smartList(.mostPlayed), [a.path, b.path])
        XCTAssertEqual(store.smartList(.recentlyPlayed), [a.path, b.path])
        XCTAssertEqual(store.smartList(.neverPlayed), [c.path])
        XCTAssertEqual(store.smartList(.recentlyAdded).first, c.path)
        XCTAssertEqual(store.playCount(a.path).plays, 2)
    }
}

final class ReleaseCheckTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(ReleaseCheck.isNewer("0.10.0", than: "0.9.2"))
        XCTAssertTrue(ReleaseCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(ReleaseCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(ReleaseCheck.isNewer("0.1.0", than: "0.2.0-beta"))
    }

    func testParsesReleaseAndPicksDMG() throws {
        let json = """
            {"tag_name": "v0.2.0", "html_url": "https://github.com/asahium/kveikur/releases/tag/v0.2.0", "body": "Notes",
             "assets": [{"name": "Source.zip", "browser_download_url": "https://x/s.zip"},
                        {"name": "Kveikur-0.2.0.dmg", "browser_download_url": "https://x/k.dmg"}]}
            """
        let r = try XCTUnwrap(ReleaseCheck.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.dmg?.absoluteString, "https://x/k.dmg")
        XCTAssertEqual(r.notes, "Notes")
    }
}

final class HistoryImportTests: XCTestCase {
    func testParsesRecentTracksAndSkipsNowPlaying() {
        let json: [String: Any] = ["recenttracks": [
            "@attr": ["totalPages": "3"],
            "track": [
                ["name": "Live", "artist": ["#text": "A"], "@attr": ["nowplaying": "true"]],
                ["name": "Hoppípolla", "artist": ["#text": "Sigur Rós"], "album": ["#text": "Takk..."], "date": ["uts": "1700000000"]],
                ["name": "Untitled", "artist": ["#text": "B"], "album": ["#text": ""], "date": ["uts": "1700000300"]],
            ],
        ]]
        let r = LastFMService.parseRecent(json)
        XCTAssertEqual(r.pages, 3)
        XCTAssertEqual(r.plays.map(\.title), ["Hoppípolla", "Untitled"])
        XCTAssertEqual(r.plays[0].album, "Takk...")
        XCTAssertNil(r.plays[1].album)
    }

    func testImportMatchesLibraryAndSkipsKnownPlays() throws {
        let store = try LibraryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"))
        var t = TrackMetadata(path: "/M/hoppipolla.flac", mtime: 1, size: 1)
        t.artist = "Sigur Rós"; t.title = "Hoppípolla"; t.duration = 268
        store.upsert([t])
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordPlay(t, at: at)

        let plays = [
            ImportedPlay(artist: "Sigur Rós", title: "Hoppípolla", album: nil, at: at.addingTimeInterval(20)),
            ImportedPlay(artist: "sigur ros", title: "hoppipolla", album: nil, at: at.addingTimeInterval(3600)),
            ImportedPlay(artist: "Other", title: "Song", album: "X", at: at.addingTimeInterval(7200)),
        ]
        XCTAssertEqual(store.importPlays(plays), 2)
        XCTAssertEqual(store.importPlays(plays), 0)
        let s = store.stats(since: nil)
        XCTAssertEqual(s.plays, 3)
        XCTAssertEqual(s.seconds, 268 * 2)
        XCTAssertEqual(store.playCount(t.path).plays, 2)
        XCTAssertEqual(store.smartList(.mostPlayed), [t.path])
    }
}

final class DiscographyTests: XCTestCase {
    private func track(_ path: String, album: String?, artist: String) -> TrackMetadata {
        var t = TrackMetadata(path: path, mtime: 0, size: 1)
        t.album = album
        t.albumArtist = artist
        return t
    }

    func testLocalArtistsAndMatching() {
        let root = URL(fileURLWithPath: "/m")
        let tracks = [
            track("/m/Rise Against/2007 - The Sufferer And The Witness (Australian Tour Edition)/01.flac", album: nil, artist: "Rise Against"),
            track("/m/Lana Del Rey/Born to Die - The Paradise Edition/01.flac", album: "Born to Die – The Paradise Edition", artist: "Lana Del Rey"),
            track("/m/Metallica/1991 - Black Album/01.flac", album: "Black Album", artist: "Metallica"),
            track("/m/OST/Dune/01.flac", album: "Dune", artist: "Hans Zimmer"),
            track("/m/Ed Sheeran/Albums/2014 - x (UK Deluxe Edition)/01.flac", album: nil, artist: "Ed Sheeran"),
            track("/m/Ed Sheeran/Albums/2017 - Divide (Deluxe Edition)/01.flac", album: nil, artist: "Ed Sheeran"),
            track("/m/Ed Sheeran/Albums/2023 - - (Deluxe)/01.flac", album: nil, artist: "Ed Sheeran"),
            track("/m/Childish Gambino/Childish Gambino - Atavista (2024) [24-44,1]/01.flac", album: nil, artist: "Childish Gambino"),
            track("/m/loose.flac", album: nil, artist: "X"),
        ]
        let artists = Discography.localArtists(tracks, roots: [root])
        XCTAssertEqual(artists.map(\.name), ["Childish Gambino", "Ed Sheeran", "Lana Del Rey", "Metallica", "Rise Against"])
        func album(_ t: String) -> StudioAlbum { StudioAlbum(id: t, title: t, year: nil) }
        XCTAssertTrue(artists[4].owns(album("The Sufferer & the Witness")))
        XCTAssertTrue(artists[2].owns(album("Born to Die")))
        XCTAssertFalse(artists[2].owns(album("Ultraviolence")))
        XCTAssertFalse(artists[3].owns(album("Metallica")), "the artist folder itself is not an album")
        XCTAssertTrue(artists[0].owns(album("Atavista")))
        for t in ["×", "÷", "−"] { XCTAssertTrue(artists[1].owns(album(t)), t) }
        XCTAssertFalse(artists[1].owns(album("+")))
    }

    func testFolderTitle() {
        XCTAssertEqual(Discography.folderTitle("2013 - Kveikur"), "Kveikur")
        XCTAssertEqual(Discography.folderTitle("(2002) ()"), "()")
        XCTAssertEqual(Discography.folderTitle("1999"), "1999")
    }

    func testPickArtist() {
        typealias Hit = MusicBrainz.ArtistHit
        let hits = [Hit(id: "a", name: "Sigur Rós", score: 100, aliases: nil), Hit(id: "b", name: "Sigur", score: 90, aliases: nil)]
        XCTAssertEqual(MusicBrainz.pick(hits, for: "Sigur Ros").first?.id, "a")
        XCTAssertTrue(MusicBrainz.pick([Hit(id: "c", name: "Other", score: 70, aliases: nil)], for: "Nobody").isEmpty)
    }
}

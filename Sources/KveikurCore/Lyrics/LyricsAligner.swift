import AVFAudio
import Foundation

/// A word heard by speech recognition, seconds from the start of the track.
public struct RecognizedWord: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Puts word timings on known lyrics by matching them against what speech recognition heard.
/// Recognition of sung vocals is patchy, so it only provides anchors; words in between are spread by length.
public enum LyricsAligner {
    public struct Result: Sendable {
        public var lyrics: Lyrics
        /// Share of lyric words that matched a recognized word.
        public var coverage: Double
    }

    struct Token {
        var line: Int
        var text: String
        var key: String
    }

    /// Nil when too little matched to trust the result.
    public static func align(_ lyrics: Lyrics, to heard: [RecognizedWord], duration: TimeInterval) -> Result? {
        let lineSynced = lyrics.synced
        var tokens: [Token] = []
        for (i, l) in lyrics.lines.enumerated() where isSung(l.text) {
            let parts = l.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            for (j, p) in parts.enumerated() {
                tokens.append(Token(line: i, text: j + 1 < parts.count ? p + " " : p, key: lyricsKey(p)))
            }
        }
        let rec = heard.filter { !lyricsKey($0.text).isEmpty }
        let keyed = tokens.filter { !$0.key.isEmpty }.count
        guard keyed > 0, !rec.isEmpty else { return nil }

        // Line windows constrain matches when the lyrics are already line-synced.
        var window: [Int: ClosedRange<TimeInterval>] = [:]
        if lineSynced {
            let times = lyrics.lines.map { $0.time.map { $0 - lyrics.offset } }
            for i in lyrics.lines.indices {
                guard let t = times[i] else { continue }
                let next = times[(i + 1)...].compactMap { $0 }.first ?? max(duration, t + 10)
                window[i] = (t - 1.5)...(next + 1.5)
            }
        }

        let pairs = match(tokens, rec, window: window)
        guard pairs.count >= 6, Double(pairs.count) / Double(keyed) >= (lineSynced ? 0.25 : 0.35) else { return nil }

        var start = [TimeInterval?](repeating: nil, count: tokens.count)
        var end = [TimeInterval?](repeating: nil, count: tokens.count)
        for (t, r) in pairs {
            start[t] = rec[r].start
            end[t] = rec[r].end
        }
        if lineSynced {
            for (i, tok) in tokens.enumerated() where i == 0 || tokens[i - 1].line != tok.line {
                if start[i] == nil, let t = lyrics.lines[tok.line].time { start[i] = t - lyrics.offset }
            }
        }
        fillGaps(tokens, &start, &end, duration: duration)

        var out = lyrics
        var k = 0
        var lastEnd: TimeInterval = 0
        for i in out.lines.indices {
            var words: [LyricWord] = []
            while k < tokens.count, tokens[k].line == i {
                let s = start[k]!
                let e = min(end[k] ?? s + 0.3, k + 1 < tokens.count ? max(s, start[k + 1]!) : duration)
                words.append(LyricWord(time: s + lyrics.offset, end: max(s, e) + lyrics.offset, text: tokens[k].text))
                k += 1
            }
            if words.isEmpty {
                out.lines[i].words = nil
                if out.lines[i].time == nil { out.lines[i].time = lastEnd + lyrics.offset }
                continue
            }
            if lineSynced, let lt = lyrics.lines[i].time {
                let next = lyrics.lines[(i + 1)...].compactMap(\.time).first ?? duration + lyrics.offset
                for w in words.indices {
                    words[w].time = min(max(words[w].time, w > 0 ? words[w - 1].time : lt), max(lt, next - 0.05))
                    words[w].end = min(max(words[w].end ?? words[w].time, words[w].time), next)
                }
            }
            out.lines[i].words = words
            if !lineSynced { out.lines[i].time = words[0].time }
            out.lines[i].end = words.last?.end
            lastEnd = (words.last?.end ?? 0) - lyrics.offset
        }
        return Result(lyrics: out, coverage: Double(pairs.count) / Double(keyed))
    }

    static func isSung(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        // Genius section headers: "[Chorus]", "[Verse 2: Artist]".
        if t.hasPrefix("["), t.hasSuffix("]") { return false }
        return true
    }

    /// Needleman–Wunsch over words; returns (token, recognized) index pairs that are real matches.
    static func match(_ tokens: [Token], _ rec: [RecognizedWord], window: [Int: ClosedRange<TimeInterval>]) -> [(Int, Int)] {
        let n = tokens.count, m = rec.count
        let recKeys = rec.map { lyricsKey($0.text) }
        let gapLyric = -0.4, gapHeard = -0.3
        func sim(_ i: Int, _ j: Int) -> Double {
            let a = tokens[i].key
            guard !a.isEmpty else { return 0 }
            if let w = window[tokens[i].line], !w.contains(rec[j].start) { return 0 }
            return similarity(a, recKeys[j])
        }
        func score(_ s: Double) -> Double { s >= 0.6 ? 2 * s : -1 }

        var dp = [Double](repeating: 0, count: (n + 1) * (m + 1))
        var move = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in 1...n { dp[i * w] = Double(i) * gapLyric; move[i * w] = 1 }
        for j in 1...max(1, m) where m > 0 { dp[j] = Double(j) * gapHeard; move[j] = 2 }
        var sims = [Double](repeating: 0, count: (n + 1) * (m + 1))
        for i in 1...n {
            for j in 1...m {
                let s = sim(i - 1, j - 1)
                sims[i * w + j] = s
                let diag = dp[(i - 1) * w + j - 1] + score(s)
                let up = dp[(i - 1) * w + j] + gapLyric
                let left = dp[i * w + j - 1] + gapHeard
                if diag >= up, diag >= left { dp[i * w + j] = diag; move[i * w + j] = 0 }
                else if up >= left { dp[i * w + j] = up; move[i * w + j] = 1 }
                else { dp[i * w + j] = left; move[i * w + j] = 2 }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            switch move[i * w + j] {
            case 0:
                if sims[i * w + j] >= 0.6 { pairs.append((i - 1, j - 1)) }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        pairs.reverse()
        // Recognition timestamps occasionally run backwards; keep anchors monotonic.
        var kept: [(Int, Int)] = []
        for p in pairs where kept.last.map({ rec[$0.1].start <= rec[p.1].start }) ?? true { kept.append(p) }
        return kept
    }

    /// 1 for equal keys, falling with edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        var cur = prev
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Natural length of a word when sung, used to place unmatched words.
    private static func natural(_ t: Token) -> TimeInterval { 0.12 + 0.06 * Double(t.key.count) }

    /// Unmatched runs: words still on the previous anchor's line follow it, the rest lead into the next anchor.
    private static func fillGaps(_ tokens: [Token], _ start: inout [TimeInterval?], _ end: inout [TimeInterval?], duration: TimeInterval) {
        var i = 0
        while i < tokens.count {
            guard start[i] == nil else { i += 1; continue }
            var j = i
            while j < tokens.count, start[j] == nil { j += 1 }
            let prev = i > 0 ? i - 1 : nil
            let next = j < tokens.count ? j : nil
            let lo = prev.map { end[$0] ?? start[$0]! + natural(tokens[$0]) } ?? 0
            let hi = next.map { start[$0]! } ?? duration
            let run = Array(i..<j)
            let tail = run.filter { p in prev.map { tokens[$0].line == tokens[p].line } ?? false }
            let head = run.filter { p in !tail.contains(p) }
            let room = max(0, hi - lo)
            let need = run.reduce(0) { $0 + natural(tokens[$1]) }
            let scale = need > room && need > 0 ? room / need : 1
            var t = lo
            for p in tail {
                start[p] = t
                t += natural(tokens[p]) * scale
                end[p] = t
            }
            let headNeed = head.reduce(0) { $0 + natural(tokens[$1]) } * scale
            if next != nil || prev == nil { t = max(t, hi - headNeed) }
            for p in head {
                start[p] = t
                t += natural(tokens[p]) * scale
                end[p] = t
            }
            i = j
        }
    }
}

public enum AudioSamples {
    /// The whole track as 16 kHz mono, what Whisper expects. Works for cue tracks too.
    public static func mono16k(_ url: URL) throws -> [Float] {
        let decoder = try DecoderFactory.makeDecoder(for: url)
        let inFormat = decoder.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 32768),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32768)
        else { throw CocoaError(.fileReadCorruptFile) }
        converter.downmix = true
        var out: [Float] = []
        out.reserveCapacity(Int(Double(decoder.lengthFrames) * 16000 / inFormat.sampleRate) + 1024)
        var done = false
        while true {
            var readError: Error?
            let status = converter.convert(to: outBuf, error: nil) { _, state in
                if done { state.pointee = .endOfStream; return nil }
                do {
                    if try decoder.read(into: inBuf) {
                        state.pointee = .haveData
                        return inBuf
                    }
                } catch { readError = error }
                done = true
                state.pointee = .endOfStream
                return nil
            }
            if let readError { throw readError }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return out
    }
}

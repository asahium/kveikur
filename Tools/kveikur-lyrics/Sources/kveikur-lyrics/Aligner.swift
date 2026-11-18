import Foundation
import KveikurCore

/// Runs `aligner/align.py` (Demucs + MMS forced alignment) through uv and talks to it one JSON line per track.
/// The process stays up between tracks so the models load once.
final class Aligner {
    struct Failure: LocalizedError {
        let reason: String
        /// The worker ran out of memory and quit; a fresh one may well manage the same track.
        var retryable = false
        var errorDescription: String? { reason }
    }

    private struct Request: Encodable {
        struct Line: Encodable { let text: String; let time: Double? }
        let audio: String
        let start: Double
        let end: Double?
        let lines: [Line]
    }

    private struct Reply: Decodable {
        struct Word: Decodable { let text: String; let start: Double; let end: Double }
        let ok: Bool
        let reason: String?
        let restart: Bool?
        let lines: [[Word]?]?
    }

    static let suffix = " + auto-sync"
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("aligner")

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(background: Bool) throws {
        var args = ["uv", "run", "--quiet", "--project", Self.directory.path, "python", Self.directory.appendingPathComponent("align.py").path]
        // Utility clamp: yields to anything interactive but may still use the performance cores.
        if background { args = ["/usr/sbin/taskpolicy", "-c", "utility"] + args }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var running: Bool { process.isRunning }
    /// Tracks sent so far; the caller recycles the worker now and then to keep its memory bounded.
    private(set) var handled = 0

    deinit { process.terminate() }

    /// Same lyrics with words timed. Lines keep their own time when they had one.
    func align(_ lyrics: Lyrics, url: URL) throws -> Lyrics {
        var audio = url.path, start = 0.0, end: Double?
        if CueTrackRef.isCue(url), let (_, t) = CueTrackRef.resolve(url) {
            audio = t.file.path
            start = t.start
            end = t.end
        }
        // Lines show at `time + offset` of the audio.
        let req = Request(audio: audio, start: start, end: end,
                          lines: lyrics.lines.map { .init(text: $0.text, time: $0.time.map { $0 + lyrics.offset }) })
        var data = try JSONEncoder().encode(req)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
        let reply = try JSONDecoder().decode(Reply.self, from: readLine())
        handled += 1
        guard reply.ok, let timed = reply.lines, timed.count == lyrics.lines.count else {
            throw Failure(reason: reply.reason ?? "no answer from the aligner", retryable: reply.restart == true)
        }
        var out = lyrics
        var lastEnd = 0.0
        for i in out.lines.indices {
            guard let ws = timed[i], !ws.isEmpty else {
                if out.lines[i].time == nil { out.lines[i].time = lastEnd - lyrics.offset }
                continue
            }
            out.lines[i].words = ws.map { LyricWord(time: $0.start - lyrics.offset, end: $0.end - lyrics.offset, text: $0.text) }
            if out.lines[i].time == nil { out.lines[i].time = ws[0].start - lyrics.offset }
            out.lines[i].end = ws.last!.end - lyrics.offset
            lastEnd = ws.last!.end
        }
        out.source = lyrics.source + Self.suffix
        return out
    }

    private func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw Failure(reason: "the aligner exited (is uv installed?)") }
            buffer.append(chunk)
        }
    }
}

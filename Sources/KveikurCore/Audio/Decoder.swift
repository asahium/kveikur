import AVFAudio
import Foundation

/// Streaming decoder: reads PCM chunk by chunk, never the whole file.
public protocol AudioDecoder: AnyObject {
    var url: URL { get }
    /// Float32 deinterleaved at the file's native rate and channel count.
    var processingFormat: AVAudioFormat { get }
    var lengthFrames: Int64 { get }
    var positionFrames: Int64 { get }
    /// Fills `buffer`; returns false when nothing was read (end of stream).
    func read(into buffer: AVAudioPCMBuffer) throws -> Bool
    func seek(to frame: Int64) throws
}

/// Covers everything Core Audio can open: FLAC, ALAC, AAC, MP3, WAV/W64, AIFF, CAF, AU, Ogg Vorbis/Opus/FLAC.
final class CoreAudioDecoder: AudioDecoder {
    let url: URL
    private let file: AVAudioFile

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var processingFormat: AVAudioFormat { file.processingFormat }
    var lengthFrames: Int64 { file.length }
    var positionFrames: Int64 { file.framePosition }

    func read(into buffer: AVAudioPCMBuffer) throws -> Bool {
        buffer.frameLength = 0
        guard file.framePosition < file.length else { return false }
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        return buffer.frameLength > 0
    }

    func seek(to frame: Int64) throws {
        file.framePosition = max(0, min(frame, file.length))
    }
}

/// One cue track: frames [start, end) of an image file, exposed as a stream starting at 0.
final class SegmentDecoder: AudioDecoder {
    let url: URL
    private let file: AVAudioFile
    private let start: Int64
    private let end: Int64

    init(url: URL, image: URL, start: TimeInterval, end: TimeInterval?) throws {
        self.url = url
        file = try AVAudioFile(forReading: image, commonFormat: .pcmFormatFloat32, interleaved: false)
        let f = file
        let rate = f.processingFormat.sampleRate
        let first = min(f.length, Int64((start * rate).rounded()))
        self.start = first
        self.end = end.map { min(f.length, Int64(($0 * rate).rounded())) } ?? f.length
        f.framePosition = first
    }

    var processingFormat: AVAudioFormat { file.processingFormat }
    var lengthFrames: Int64 { max(0, end - start) }
    var positionFrames: Int64 { file.framePosition - start }

    func read(into buffer: AVAudioPCMBuffer) throws -> Bool {
        buffer.frameLength = 0
        let remaining = end - file.framePosition
        guard remaining > 0 else { return false }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
        return buffer.frameLength > 0
    }

    func seek(to frame: Int64) throws {
        file.framePosition = start + max(0, min(frame, lengthFrames))
    }
}

public enum DecoderFactory {
    public static func makeDecoder(for url: URL) throws -> AudioDecoder {
        if CueTrackRef.isCue(url) {
            guard let (_, t) = CueTrackRef.resolve(url) else { throw CocoaError(.fileNoSuchFile) }
            return try SegmentDecoder(url: url, image: t.file, start: t.start, end: t.end)
        }
        return try CoreAudioDecoder(url: url)
    }
}

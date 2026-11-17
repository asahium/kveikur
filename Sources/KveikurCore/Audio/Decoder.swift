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

public enum DecoderFactory {
    public static func makeDecoder(for url: URL) throws -> AudioDecoder {
        try CoreAudioDecoder(url: url)
    }
}

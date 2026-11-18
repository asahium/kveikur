import CoreML
import Foundation
import KveikurCore
import NaturalLanguage
import WhisperKit

/// On-device Whisper (Core ML, Neural Engine) used to put word timings on lyrics.
/// One track at a time with a single decoder worker; the model is unloaded after a minute of idling.
actor SpeechAligner {
    static let shared = SpeechAligner()

    enum Model: String, CaseIterable, Sendable {
        case small, turbo

        var variant: String {
            switch self {
            case .small: return "openai_whisper-small_216MB"
            case .turbo: return "openai_whisper-large-v3-v20240930_turbo_632MB"
            }
        }

        var label: String {
            switch self {
            case .small: return "Small · 216 MB, faster"
            case .turbo: return "Large v3 Turbo · 632 MB, more accurate"
            }
        }
    }

    enum Failure: LocalizedError {
        case noMatch
        var errorDescription: String? { "The recording and the lyrics didn't match well enough." }
    }

    static let modelsBase: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kveikur/whisper", isDirectory: true)

    nonisolated(unsafe) static var verbose = false

    private var kit: WhisperKit?
    private var loaded: Model?
    private var idle: Task<Void, Never>?

    nonisolated static func folder(_ m: Model) -> URL {
        modelsBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(m.variant)", isDirectory: true)
    }

    nonisolated static func isDownloaded(_ m: Model) -> Bool {
        FileManager.default.fileExists(atPath: folder(m).appendingPathComponent("TextDecoder.mlmodelc").path)
    }

    nonisolated static func deleteModels() {
        try? FileManager.default.removeItem(at: modelsBase)
    }

    private func whisper(_ m: Model, download: @escaping @Sendable (Double) -> Void) async throws -> WhisperKit {
        idle?.cancel()
        if let kit, loaded == m { return kit }
        if let kit { await kit.unloadModels() }
        kit = nil
        if !Self.isDownloaded(m) {
            _ = try await WhisperKit.download(variant: m.variant, downloadBase: Self.modelsBase) { download($0.fractionCompleted) }
        }
        let config = WhisperKitConfig(
            model: m.variant,
            downloadBase: Self.modelsBase,
            modelFolder: Self.folder(m).path,
            computeOptions: ModelComputeOptions(melCompute: .cpuAndNeuralEngine, audioEncoderCompute: .cpuAndNeuralEngine,
                                                textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        let k = try await WhisperKit(config)
        kit = k
        loaded = m
        return k
    }

    private func scheduleUnload() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            await self.unload()
        }
    }

    func unload() async {
        if let kit { await kit.unloadModels() }
        kit = nil
        loaded = nil
    }

    /// Word timings for `lyrics` from the audio at `url`. Throws `Failure.noMatch` when the recording doesn't fit.
    func align(_ lyrics: Lyrics, url: URL, model: Model, download: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Lyrics {
        let k = try await whisper(model, download: download)
        defer { scheduleUnload() }
        let samples = try await Task.detached(priority: .utility) { try AudioSamples.mono16k(url) }.value
        try Task.checkCancellation()
        let heard = try await recognize(k, samples, language: Self.language(of: lyrics), prompt: Self.prompt(lyrics))
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16000
        if Self.verbose {
            print("language \(Self.language(of: lyrics) ?? "auto"), heard \(heard.count) words:")
            print(heard.map { String(format: "%.1f %@", $0.start, $0.text) }.joined(separator: " | "))
        }
        guard let result = LyricsAligner.align(lyrics, to: heard, duration: duration) else { throw Failure.noMatch }
        var out = result.lyrics
        out.source = lyrics.source + " + Whisper"
        return out
    }

    /// The opening lines, so Whisper expects singing in this wording instead of calling it "[Music]".
    nonisolated static func prompt(_ lyrics: Lyrics) -> String {
        let words = lyrics.lines.map(\.text).filter { !$0.hasPrefix("[") }.joined(separator: " ").split(separator: " ")
        return words.prefix(60).joined(separator: " ")
    }

    func recognize(_ k: WhisperKit, _ samples: [Float], language: String?, prompt: String) async throws -> [RecognizedWord] {
        let promptTokens = k.tokenizer?.encode(text: " " + prompt).filter { $0 < (k.tokenizer?.specialTokens.specialTokenBegin ?? 0) }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 2,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            wordTimestamps: true,
            promptTokens: promptTokens,
            // Music between verses is "no speech"; keep decoding rather than skipping windows.
            noSpeechThreshold: nil,
            concurrentWorkerCount: 1
        )
        let results = try await k.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
            RecognizedWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: Double($0.start), end: Double($0.end))
        }
    }

    /// Whisper's language code for the lyrics text, so it doesn't have to guess from a sung intro.
    nonisolated static func language(of lyrics: Lyrics) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(lyrics.lines.map(\.text).joined(separator: "\n"))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        let code = lang.rawValue.components(separatedBy: "-")[0]
        switch code {
        case "nb", "nn": return "no"
        case "zh": return "zh"
        default: return code
        }
    }
}

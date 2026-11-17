import AVFAudio
import CoreGraphics
import Foundation

public struct TrackAnalysis: Sendable {
    /// Per-bucket min/max of the mono mix, -1...1.
    public var waveform: [SIMD2<Float>]
    public var samplePeakDB: Float
    public var rmsDB: Float
    public var crestDB: Float { samplePeakDB - rmsDB }
    public var integratedLUFS: Float?
    /// ReplayGain 2.0 reference (-18 LUFS).
    public var replayGainDB: Float? { integratedLUFS.map { -18 - $0 } }
    /// Long-term spectrum in dB, linear frequency from 0 to Nyquist.
    public var spectrum: [Float]
    public var bandwidthHz: Double
    public var sampleRate: Double
    public var spectrogram: CGImage?
}

/// Streams the whole file once, chunk by chunk, so memory stays flat regardless of length.
public enum TrackAnalyzer {
    static let waveformBuckets = 900
    static let spectrogramColumns = 480
    static let fftSize = 2048
    static let spectrumBins = 256

    public static func analyze(_ url: URL) throws -> TrackAnalysis {
        let decoder = try DecoderFactory.makeDecoder(for: url)
        let format = decoder.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        let length = max(decoder.lengthFrames, 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw NSError(domain: "Kveikur", code: 1)
        }

        var wave = [SIMD2<Float>](repeating: SIMD2(1, -1), count: waveformBuckets)
        var peak: Float = 0
        var sumSquares = 0.0
        var totalSamples = 0
        let loudness = LoudnessMeter(sampleRate: rate, channels: channels)

        let fft = PowerSpectrum(size: fftSize)
        var power: [Float] = []
        var spectrumAcc = [Double](repeating: 0, count: fftSize / 2)
        var windows = 0
        var columns: [[Float]] = []
        columns.reserveCapacity(spectrogramColumns)
        let step = max(Int64(fftSize), length / Int64(spectrogramColumns))
        var nextWindow: Int64 = 0
        var carry: [Float] = []
        var position: Int64 = 0

        while try decoder.read(into: buffer) {
            let n = Int(buffer.frameLength)
            guard let data = buffer.floatChannelData else { break }
            var mono = [Float](repeating: 0, count: n)
            let scale = 1 / Float(channels)
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<n {
                    let s = p[i]
                    mono[i] += s * scale
                    let a = abs(s)
                    if a > peak { peak = a }
                    sumSquares += Double(s * s)
                }
            }
            totalSamples += n * channels
            loudness.process(data, frames: n)

            for i in 0..<n {
                let b = Int((position + Int64(i)) * Int64(waveformBuckets) / length)
                let idx = min(b, waveformBuckets - 1)
                let s = mono[i]
                if s < wave[idx].x { wave[idx].x = s }
                if s > wave[idx].y { wave[idx].y = s }
            }

            let combined = carry + mono
            let combinedStart = position - Int64(carry.count)
            while nextWindow + Int64(fftSize) <= combinedStart + Int64(combined.count) {
                let offset = Int(nextWindow - combinedStart)
                if offset >= 0 {
                    combined.withUnsafeBufferPointer { fft.power($0.baseAddress! + offset, into: &power) }
                    for k in 0..<power.count { spectrumAcc[k] += Double(power[k]) }
                    windows += 1
                    if columns.count < spectrogramColumns { columns.append(downsample(power, to: spectrumBins)) }
                }
                nextWindow += step
            }
            carry = Array(combined.suffix(fftSize))
            position += Int64(n)
        }

        for i in wave.indices where wave[i].x > wave[i].y { wave[i] = SIMD2(0, 0) }
        let rms = totalSamples > 0 ? sqrt(sumSquares / Double(totalSamples)) : 0
        let avg = spectrumAcc.map { PowerSpectrum.db(Float($0 / Double(max(windows, 1)))) }
        return TrackAnalysis(
            waveform: wave,
            samplePeakDB: 20 * log10(max(peak, 1e-6)),
            rmsDB: Float(20 * log10(max(rms, 1e-9))),
            integratedLUFS: loudness.integrated(),
            spectrum: downsample(avg.map { pow(10, $0 / 10) }, to: spectrumBins).map { PowerSpectrum.db($0) },
            bandwidthHz: bandwidth(avg, sampleRate: rate),
            sampleRate: rate,
            spectrogram: spectrogramImage(columns)
        )
    }

    /// Averages power into `count` linear bins.
    static func downsample(_ power: [Float], to count: Int) -> [Float] {
        let per = max(1, power.count / count)
        return (0..<count).map { i in
            var s: Float = 0
            for k in i * per..<min(power.count, (i + 1) * per) { s += power[k] }
            return s / Float(per)
        }
    }

    /// Highest frequency whose long-term level stays within 60 dB of the spectrum's peak.
    static func bandwidth(_ db: [Float], sampleRate: Double) -> Double {
        guard let top = db.dropFirst(2).max() else { return 0 }
        let threshold = max(top - 60, -110)
        let binHz = sampleRate / Double(fftSize)
        var i = db.count - 1
        // Require a few consecutive bins above threshold so isolated spurs don't count.
        while i > 3 {
            if db[i] > threshold, db[i - 1] > threshold, db[i - 2] > threshold { return Double(i) * binHz }
            i -= 1
        }
        return 0
    }

    static func spectrogramImage(_ columns: [[Float]]) -> CGImage? {
        guard let h = columns.first?.count, !columns.isEmpty else { return nil }
        let w = columns.count
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for (x, col) in columns.enumerated() {
            for (bin, p) in col.enumerated() {
                let db = PowerSpectrum.db(p)
                let t = max(0, min(1, (db + 120) / 120))
                let c = Colormap.magma(t)
                let y = h - 1 - bin
                let o = (y * w + x) * 4
                pixels[o] = c.0
                pixels[o + 1] = c.1
                pixels[o + 2] = c.2
                pixels[o + 3] = 255
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum Colormap {
    private static let stops: [(Float, (Float, Float, Float))] = [
        (0.0, (0, 0, 4)), (0.25, (59, 15, 112)), (0.5, (140, 41, 129)),
        (0.75, (222, 73, 104)), (0.9, (254, 159, 109)), (1.0, (252, 253, 191)),
    ]

    static func magma(_ t: Float) -> (UInt8, UInt8, UInt8) {
        var i = 0
        while i < stops.count - 2, t > stops[i + 1].0 { i += 1 }
        let (t0, a) = stops[i]
        let (t1, b) = stops[i + 1]
        let f = max(0, min(1, (t - t0) / (t1 - t0)))
        return (UInt8(a.0 + (b.0 - a.0) * f), UInt8(a.1 + (b.1 - a.1) * f), UInt8(a.2 + (b.2 - a.2) * f))
    }
}

/// ITU-R BS.1770-4 / EBU R128 integrated loudness: K-weighting, 400 ms blocks with 75 % overlap,
/// absolute gate at -70 LUFS and relative gate 10 LU below the ungated mean.
final class LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private let channels: Int
    private let subBlockFrames: Int
    private var subBlockFill = 0
    private var subBlockSum: [Double]
    private var subBlocks: [Double] = []

    init(sampleRate rate: Double, channels: Int) {
        self.channels = min(channels, 2)
        subBlockFrames = Int(rate * 0.1)
        subBlockSum = [Double](repeating: 0, count: max(1, min(channels, 2)))

        // Coefficients re-derived for any rate (same constants as libebur128).
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let g = 3.999843853973347
        var k = tan(.pi * f0 / rate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let s = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / rate)
        a0 = 1 + k / q + k * k
        let h = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        shelf = Array(repeating: s, count: max(1, self.channels))
        highpass = Array(repeating: h, count: max(1, self.channels))
    }

    func process(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        for i in 0..<frames {
            for c in 0..<channels {
                let y = highpass[c].run(shelf[c].run(Double(data[c][i])))
                subBlockSum[c] += y * y
            }
            subBlockFill += 1
            if subBlockFill == subBlockFrames {
                var sum = 0.0
                for c in 0..<channels { sum += subBlockSum[c] / Double(subBlockFrames); subBlockSum[c] = 0 }
                subBlocks.append(sum)
                subBlockFill = 0
            }
        }
    }

    func integrated() -> Float? {
        guard subBlocks.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count)
        for i in 3..<subBlocks.count {
            blocks.append((subBlocks[i] + subBlocks[i - 1] + subBlocks[i - 2] + subBlocks[i - 3]) / 4)
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-15)) }
        let absGated = blocks.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relThreshold = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relThreshold }
        guard !gated.isEmpty else { return nil }
        return Float(lufs(gated.reduce(0, +) / Double(gated.count)))
    }
}

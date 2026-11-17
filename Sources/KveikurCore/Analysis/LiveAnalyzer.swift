import AVFAudio
import Foundation

public struct LiveFrame: Sendable {
    /// Log-spaced bands from 20 Hz to 20 kHz, in dBFS.
    public var bands: [Float] = []
    public var peakDB: [Float] = [-120, -120]
    public var rmsDB: [Float] = [-120, -120]
    /// -1 (out of phase) ... +1 (mono).
    public var correlation: Float = 0
    /// Goniometer points: x = side, y = mid, both roughly -1...1.
    public var points: [SIMD2<Float>] = []

    public init() {}
}

/// Turns tapped buffers into meter, spectrum and goniometer frames. Runs on the tap thread.
public final class LiveAnalyzer: @unchecked Sendable {
    public static let bandCount = 36
    private let fft = PowerSpectrum(size: 2048)
    private var mono = [Float](repeating: 0, count: 2048)
    private var power: [Float] = []
    private var lastEmit = Date.distantPast
    private let onFrame: @Sendable (LiveFrame) -> Void

    public init(onFrame: @escaping @Sendable (LiveFrame) -> Void) {
        self.onFrame = onFrame
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 1.0 / 30, let data = buffer.floatChannelData else { return }
        lastEmit = now
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let l = data[0]
        let r = channels > 1 ? data[1] : data[0]

        var frame = LiveFrame()
        var sumL: Float = 0, sumR: Float = 0, sumLR: Float = 0
        var pkL: Float = 0, pkR: Float = 0
        for i in 0..<n {
            let a = l[i], b = r[i]
            sumL += a * a
            sumR += b * b
            sumLR += a * b
            pkL = max(pkL, abs(a))
            pkR = max(pkR, abs(b))
        }
        frame.peakDB = [Self.db(pkL), Self.db(pkR)]
        frame.rmsDB = [Self.db(sqrt(sumL / Float(n))), Self.db(sqrt(sumR / Float(n)))]
        let denom = sqrt(sumL * sumR)
        frame.correlation = denom > 1e-9 ? sumLR / denom : 0

        let step = max(1, n / 384)
        frame.points.reserveCapacity(n / step)
        var i = 0
        while i < n {
            frame.points.append(SIMD2((r[i] - l[i]) * 0.7071, (l[i] + r[i]) * 0.7071))
            i += step
        }

        let size = fft.size
        let take = min(n, size)
        for j in 0..<size { mono[j] = j < take ? (l[n - take + j] + r[n - take + j]) * 0.5 : 0 }
        mono.withUnsafeBufferPointer { fft.power($0.baseAddress!, into: &power) }
        frame.bands = Self.bands(power, sampleRate: buffer.format.sampleRate, fftSize: size)
        onFrame(frame)
    }

    static func db(_ amp: Float) -> Float { 20 * log10(max(amp, 1e-6)) }

    static func bands(_ power: [Float], sampleRate: Double, fftSize: Int) -> [Float] {
        let lo = log10(20.0), hi = log10(min(20000.0, sampleRate / 2))
        let binHz = sampleRate / Double(fftSize)
        var out = [Float](repeating: -120, count: bandCount)
        for b in 0..<bandCount {
            let f0 = pow(10, lo + (hi - lo) * Double(b) / Double(bandCount))
            let f1 = pow(10, lo + (hi - lo) * Double(b + 1) / Double(bandCount))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(power.count - 1, max(i0, Int(f1 / binHz)))
            var m: Float = 0
            for k in i0...i1 { m = max(m, power[k]) }
            out[b] = PowerSpectrum.db(m)
        }
        return out
    }
}

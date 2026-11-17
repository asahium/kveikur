import Accelerate
import Foundation

/// Real FFT with a Hann window; returns power per bin (n/2 bins).
final class PowerSpectrum {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var windowed: [Float]
    private let norm: Float

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        windowed = [Float](repeating: 0, count: size)
        // zrip returns 2x the DFT and Hann's coherent gain is 0.5, so |Z| = A·N/2 for a sine of amplitude A.
        norm = 2 / Float(size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold at least `size` values.
    func power(_ samples: UnsafePointer<Float>, into out: inout [Float]) {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                if out.count != size / 2 { out = [Float](repeating: 0, count: size / 2) }
                vDSP_zvmags(&split, 1, &out, 1, vDSP_Length(size / 2))
            }
        }
        var scale = norm * norm
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(size / 2))
    }

    static func db(_ power: Float) -> Float {
        10 * log10(max(power, 1e-14))
    }
}

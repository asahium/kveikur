import KveikurCore
import SwiftUI

struct AnalysisTab: View {
    @ObservedObject var model: AnalysisModel
    @ObservedObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PanelSection(title: "Live", help: "Spectrum, peak meters and stereo image of what is playing right now, before volume.") {
                    SpectrumBars(bands: model.bands).frame(height: 96)
                    MeterRow(label: "L", db: model.peakDB[0], hold: model.holdDB[0])
                    MeterRow(label: "R", db: model.peakDB[1], hold: model.holdDB[1])
                    HStack(alignment: .center, spacing: 14) {
                        Goniometer(points: model.points).frame(width: 110, height: 110)
                        CorrelationView(value: model.correlation)
                    }
                    .padding(.top, 4)
                }
                if player.currentURL == nil {
                    Placeholder(text: "Play a track to analyze it").frame(height: 160)
                } else if let a = model.track, model.trackURL == player.currentURL {
                    trackSections(a)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing whole track…").foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(30)
                }
            }
        }
        .onAppear { model.setActive(true) }
        .onDisappear { model.setActive(false) }
    }

    @ViewBuilder
    private func trackSections(_ a: TrackAnalysis) -> some View {
        PanelSection(title: "Waveform", help: "Min/max of the mono mix across the whole track. Click to seek.") {
            WaveformView(wave: a.waveform, progress: clock.duration > 0 ? clock.time / clock.duration : 0) { f in
                player.seek(to: f * clock.duration)
            }
            .frame(height: 70)
            KVRows(rows: [
                ("Sample Peak", String(format: "%.1f dBFS", a.samplePeakDB) + (a.samplePeakDB > -0.3 ? "  near full scale" : "")),
                ("RMS (avg)", String(format: "%.1f dBFS", a.rmsDB)),
                ("Crest Factor", String(format: "%.1f dB", a.crestDB)),
            ])
            Note(text: "Crest factor is peak minus RMS, not EBU loudness range or a mastering-quality rating.")
        }
        PanelSection(title: "Loudness", help: "ITU-R BS.1770 / EBU R128 integrated loudness with gating.") {
            KVRows(rows: [
                ("Integrated", a.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "–"),
                ("ReplayGain", a.replayGainDB.map { String(format: "%+.1f dB", $0) } ?? "–"),
            ])
            Note(text: "Loudness describes programme level, not mastering quality. ReplayGain is a reference calculation (−18 LUFS) and is not applied to playback.")
        }
        PanelSection(title: "Frequency", help: "Long-term average spectrum from sampled windows across the track.") {
            SpectrumArea(db: a.spectrum).frame(height: 60)
                .overlay(alignment: .bottomLeading) { axis("0 Hz") }
                .overlay(alignment: .bottomTrailing) { axis("Nyquist \(SourceFormat.formatRate(a.sampleRate / 2)) kHz") }
            KVRows(rows: [("Bandwidth", String(format: "%.1f kHz", a.bandwidthHz / 1000))])
            Note(text: "This overview samples spectral windows. A rolloff or lack of ultrasonic energy does not prove a lossy source or upsampling.")
        }
        PanelSection(title: "Spectrogram", help: "Time left to right, frequency bottom to top (linear, up to Nyquist).") {
            if let img = a.spectrogram {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .topLeading) { axis("\(SourceFormat.formatRate(a.sampleRate / 2)) kHz") }
                    .overlay(alignment: .bottomLeading) { axis("0") }
                    .overlay(alignment: .topLeading) {
                        GeometryReader { g in
                            Rectangle().fill(.white.opacity(0.8)).frame(width: 1)
                                .offset(x: g.size.width * (clock.duration > 0 ? clock.time / clock.duration : 0))
                        }
                    }
            }
        }
    }

    private func axis(_ s: String) -> some View {
        Text(s).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).padding(3)
    }
}

private struct SpectrumBars: View {
    let bands: [Float]

    var body: some View {
        Canvas { ctx, size in
            let n = bands.count
            guard n > 0 else { return }
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for (i, db) in bands.enumerated() {
                let level = CGFloat(max(0, min(1, (db + 90) / 90)))
                let h = max(2, level * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h)
                let hue = 0.42 - 0.38 * Double(i) / Double(n)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Color(hue: hue, saturation: 0.75, brightness: 0.85)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.25)))
        .overlay(alignment: .bottomLeading) { Text("20 Hz").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).padding(3) }
        .overlay(alignment: .bottomTrailing) { Text("20 kHz").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).padding(3) }
    }
}

private struct MeterRow: View {
    let label: String
    let db: Float
    let hold: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 12)
            GeometryReader { g in
                let f = { (d: Float) in CGFloat(max(0, min(1, (d + 60) / 60))) }
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * f(db)) }
                    Rectangle().fill(hold > -0.5 ? Color.red : Color.primary.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: max(0, g.size.width * f(hold) - 2))
                }
            }
            .frame(height: 7)
            Text(hold <= -89 ? "-∞" : String(format: "%.1f dB", hold))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(hold > -0.5 ? Color.red : Color.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

private struct Goniometer: View {
    let points: [SIMD2<Float>]

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 2
            var diamond = Path()
            diamond.move(to: CGPoint(x: c.x, y: c.y - r))
            diamond.addLine(to: CGPoint(x: c.x + r, y: c.y))
            diamond.addLine(to: CGPoint(x: c.x, y: c.y + r))
            diamond.addLine(to: CGPoint(x: c.x - r, y: c.y))
            diamond.closeSubpath()
            ctx.stroke(diamond, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            for p in points {
                let x = c.x + CGFloat(max(-1, min(1, p.x))) * r
                let y = c.y - CGFloat(max(-1, min(1, p.y))) * r
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.blue.opacity(0.8)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.25)))
    }
}

private struct CorrelationView: View {
    let value: Float

    private var label: String {
        switch value {
        case 0.95...: return "mono"
        case 0.3..<0.95: return "stereo"
        case 0..<0.3: return "wide"
        default: return "out of phase"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Correlation").font(.system(size: 12))
            GeometryReader { g in
                let mid = g.size.width / 2
                let x = mid + CGFloat(max(-1, min(1, value))) * mid
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Rectangle().fill(value >= 0 ? Color.green : Color.red)
                        .frame(width: abs(x - mid))
                        .offset(x: min(x, mid))
                    Rectangle().fill(.secondary).frame(width: 1).offset(x: mid)
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
            Text(String(format: "%.2f · %@", value, label)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

private struct WaveformView: View {
    let wave: [SIMD2<Float>]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let n = wave.count
                guard n > 0 else { return }
                let mid = size.height / 2
                let w = size.width / CGFloat(n)
                let playedX = size.width * CGFloat(progress)
                for (i, v) in wave.enumerated() {
                    let x = CGFloat(i) * w
                    let top = mid - CGFloat(v.y) * mid
                    let bottom = mid - CGFloat(v.x) * mid
                    let rect = CGRect(x: x, y: top, width: max(w, 0.6), height: max(0.6, bottom - top))
                    ctx.fill(Path(rect), with: .color(x <= playedX ? Theme.accent : Color.secondary.opacity(0.6)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                onSeek(max(0, min(1, v.location.x / g.size.width)))
            })
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.2)))
    }
}

private struct SpectrumArea: View {
    let db: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard db.count > 1 else { return }
            let top = db.max() ?? 0
            let floor = top - 90
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in db.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(db.count - 1)
                let y = size.height * (1 - CGFloat(max(0, min(1, (v - floor) / 90))))
                p.addLine(to: CGPoint(x: x, y: y))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.25)]),
                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.2)))
    }
}

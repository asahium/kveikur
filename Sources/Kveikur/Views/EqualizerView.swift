import AppKit
import KveikurCore
import SwiftUI
import UniformTypeIdentifiers

struct EqualizerView: View {
    @ObservedObject var player: PlayerController
    @State private var savingName: String?
    @State private var importError: String?

    private var preset: EQPreset { player.equalizer.preset }
    private var isCustom: Bool { player.customPresets.contains { $0.name == preset.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Toggle("Equalizer", isOn: $player.equalizer.enabled)
                    .toggleStyle(.switch)
                Spacer()
                presetMenu
                Button("Save As…") { savingName = preset.name == "Custom" ? "" : preset.name }
                Button("Import AutoEQ…") { importAutoEQ() }
                if isCustom {
                    Button(role: .destructive) { deleteCurrent() } label: { Image(systemName: "trash") }
                        .help("Delete this preset")
                }
            }

            ResponseCurve(preset: preset, enabled: player.equalizer.enabled)
                .frame(height: 130)

            if preset.isGraphic {
                graphicBands
            } else {
                parametricBands
            }

            Note(text: preset.isGraphic
                 ? "Double-click a slider to reset it. Keep the preamp at or below the highest boost to avoid clipping."
                 : "Parametric profile from AutoEQ (\(preset.bands.count) filters). Only the preamp is editable here.")
        }
        .padding(20)
        .frame(width: 640)
        .background(Color(nsColor: Theme.inspectorBackground))
        .environment(\.colorScheme, .dark)
        .opacity(player.equalizer.enabled ? 1 : 0.75)
        .alert("Save preset", isPresented: Binding(get: { savingName != nil }, set: { if !$0 { savingName = nil } })) {
            TextField("Name", text: Binding(get: { savingName ?? "" }, set: { savingName = $0 }))
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) { savingName = nil }
        }
        .alert("Cannot import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var presetMenu: some View {
        Menu(preset.name) {
            ForEach(EQPreset.builtIn) { p in Button(p.name) { select(p) } }
            if !player.customPresets.isEmpty {
                Divider()
                ForEach(player.customPresets) { p in Button(p.name) { select(p) } }
            }
        }
        .frame(width: 170)
    }

    private var graphicBands: some View {
        HStack(alignment: .bottom, spacing: 0) {
            band(label: "Pre", value: Binding(get: { preset.preamp }, set: { edit { $0.preamp = $1 } ($0) }))
            Divider().frame(height: 150).padding(.horizontal, 8)
            ForEach(preset.bands.indices, id: \.self) { i in
                band(label: Self.label(preset.bands[i].frequency),
                     value: Binding(get: { preset.bands[i].gain }, set: { v in edit { p, _ in p.bands[i].gain = v } (v) }))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var parametricBands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preamp").foregroundStyle(.secondary)
                Slider(value: Binding(get: { preset.preamp }, set: { v in edit { p, _ in p.preamp = v } (v) }), in: -24...12, step: 0.1)
                Text(String(format: "%+.1f dB", preset.preamp)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("#"); Text("Type"); Text("Frequency"); Text("Gain"); Text("Q")
                    }
                    .foregroundStyle(.secondary)
                    ForEach(preset.bands.indices, id: \.self) { i in
                        let b = preset.bands[i]
                        GridRow {
                            Text("\(i + 1)")
                            Text(b.kind == .peak ? "Peak" : (b.kind == .lowShelf ? "Low shelf" : "High shelf"))
                            Text(Self.label(b.frequency) + " Hz")
                            Text(String(format: "%+.1f dB", b.gain))
                            Text(String(format: "%.2f", b.q))
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
            }
            .frame(height: 150)
        }
    }

    private func band(label: String, value: Binding<Float>) -> some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            VerticalSlider(value: value, range: -12...12)
                .frame(width: 22, height: 150)
            Text(label)
                .font(.system(size: 10, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    /// Edits the current preset; touching a built-in one turns it into "Custom".
    private func edit(_ change: @escaping (inout EQPreset, Float) -> Void) -> (Float) -> Void {
        { v in
            var p = player.equalizer.preset
            change(&p, v)
            if EQPreset.builtIn.contains(where: { $0.name == p.name }) { p.name = "Custom" }
            player.equalizer.preset = p
            if !player.equalizer.enabled { player.equalizer.enabled = true }
        }
    }

    private func select(_ p: EQPreset) {
        player.equalizer.preset = p
        if p != .flat { player.equalizer.enabled = true }
    }

    private func saveCurrent() {
        let name = (savingName ?? "").trimmingCharacters(in: .whitespaces)
        savingName = nil
        guard !name.isEmpty, !EQPreset.builtIn.contains(where: { $0.name == name }) else { return }
        var p = preset
        p.name = name
        player.saveCustomPreset(p)
        player.equalizer.preset = p
    }

    private func deleteCurrent() {
        player.deleteCustomPreset(named: preset.name)
        var p = preset
        p.name = "Custom"
        player.equalizer.preset = p
    }

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ ParametricEQ.txt"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "The file could not be read."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ParametricEQ", with: "")
        guard let p = EQPreset.parseAutoEQ(text, name: name) else {
            importError = "No filters found. Use the ParametricEQ.txt file from AutoEQ."
            return
        }
        player.saveCustomPreset(p)
        select(p)
    }

    static func label(_ f: Float) -> String {
        f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
    }
}

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let y = CGFloat((range.upperBound - value) / span) * h
            let zero = CGFloat(range.upperBound / span) * h
            ZStack(alignment: .top) {
                Capsule().fill(Color(nsColor: Theme.nord2)).frame(width: 4)
                Rectangle().fill(Theme.accent)
                    .frame(width: 4, height: abs(y - zero))
                    .offset(y: min(y, zero))
                Rectangle().fill(Color(nsColor: Theme.nord3)).frame(width: 12, height: 1).offset(y: zero)
                Circle().fill(Color(nsColor: Theme.nord6))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .offset(y: y - 7)
            }
            .frame(width: geo.size.width)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = Float(min(max(g.location.y / h, 0), 1))
                value = ((range.upperBound - t * span) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

struct ResponseCurve: View {
    let preset: EQPreset
    let enabled: Bool
    private static let range: Float = 15

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func x(_ f: Float) -> CGFloat { CGFloat(log10(f / 20) / log10(20000 / 20)) * w }
            func y(_ db: Float) -> CGFloat { CGFloat((Self.range - min(max(db, -Self.range), Self.range)) / (2 * Self.range)) * h }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(nsColor: Theme.nord0)))
            var grid = Path()
            for f: Float in [50, 100, 200, 500, 1000, 2000, 5000, 10000] {
                grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: h))
            }
            for db: Float in [-10, -5, 5, 10] {
                grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: w, y: y(db)))
            }
            ctx.stroke(grid, with: .color(Color(nsColor: Theme.nord1)), lineWidth: 1)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: w, y: y(0)))
            ctx.stroke(zero, with: .color(Color(nsColor: Theme.nord3)), lineWidth: 1)

            var curve = Path()
            let steps = Int(w / 2)
            for i in 0...steps {
                let f = 20 * pow(1000, Float(i) / Float(steps))
                let p = CGPoint(x: x(f), y: y(preset.responseDB(at: f)))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(enabled ? Theme.accent : Color(nsColor: Theme.nord3)), lineWidth: 2)

            for (f, label) in [(100 as Float, "100"), (1000, "1k"), (10000, "10k")] {
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(Color(nsColor: Theme.secondaryText)),
                         at: CGPoint(x: x(f) + 3, y: h - 8), anchor: .leading)
            }
            for db: Float in [-10, 10] {
                ctx.draw(Text("\(Int(db)) dB").font(.system(size: 9)).foregroundStyle(Color(nsColor: Theme.secondaryText)),
                         at: CGPoint(x: 4, y: y(db) - 7), anchor: .leading)
            }
        }
    }
}

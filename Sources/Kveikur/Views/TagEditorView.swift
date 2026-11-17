import KveikurCore
import SwiftUI

/// Edits tags of one or more tracks. Fields that differ between files start empty with a "Mixed" placeholder
/// and are written only when touched.
struct TagEditorView: View {
    let files: [TrackMetadata]
    let readOnly: [String]
    let onSave: ([TagField: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [TagField: String] = [:]
    private let initial: [TagField: String?]

    init(files: [TrackMetadata], readOnly: [String], onSave: @escaping ([TagField: String]) -> Void, onCancel: @escaping () -> Void) {
        self.files = files
        self.readOnly = readOnly
        self.onSave = onSave
        self.onCancel = onCancel
        var common: [TagField: String?] = [:]
        for f in TagField.allCases {
            let all = Set(files.map { Self.value(f, $0) })
            common[f] = all.count == 1 ? all.first! : nil
        }
        initial = common
        _values = State(initialValue: common.mapValues { $0 ?? "" })
    }

    static func value(_ f: TagField, _ m: TrackMetadata) -> String {
        switch f {
        case .title: return m.title ?? ""
        case .artist: return m.artist ?? ""
        case .album: return m.album ?? ""
        case .albumArtist: return m.albumArtist ?? ""
        case .genre: return m.genre ?? ""
        case .composer: return m.composer ?? ""
        case .year: return m.year ?? ""
        case .track: return m.trackNumber.map(String.init) ?? ""
        case .trackTotal: return m.trackTotal.map(String.init) ?? ""
        case .disc: return m.discNumber.map(String.init) ?? ""
        case .discTotal: return m.discTotal.map(String.init) ?? ""
        }
    }

    private var changes: [TagField: String] {
        var out: [TagField: String] = [:]
        for f in TagField.allCases {
            let v = (values[f] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = initial[f] {
                if v != start { out[f] = v }
            } else if !v.isEmpty {
                out[f] = v
            }
        }
        return out
    }

    private var numbersValid: Bool {
        [TagField.track, .trackTotal, .disc, .discTotal].allSatisfy { f in
            let v = values[f] ?? ""
            return v.isEmpty || UInt16(v) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(files.count == 1 ? files[0].fileName : "\(files.count) tracks")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Title", .title)
                row("Artist", .artist)
                row("Album", .album)
                row("Album Artist", .albumArtist)
                row("Genre", .genre)
                row("Composer", .composer)
                GridRow {
                    label("Year")
                    HStack(spacing: 10) {
                        field(.year).frame(width: 70)
                        Text("Track").foregroundStyle(.secondary)
                        field(.track).frame(width: 46)
                        Text("of").foregroundStyle(.secondary)
                        field(.trackTotal).frame(width: 46)
                        Text("Disc").foregroundStyle(.secondary)
                        field(.disc).frame(width: 40)
                        Text("of").foregroundStyle(.secondary)
                        field(.discTotal).frame(width: 40)
                    }
                }
            }
            if !readOnly.isEmpty {
                Text("Read-only, skipped: " + readOnly.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: Theme.nord13))
                    .lineLimit(2)
            }
            HStack {
                Text(files.count > 1 ? "Empty fields marked “Mixed” keep each file's value." : "Clear a field to remove the tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(changes) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty || !numbersValid || files.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(nsColor: Theme.inspectorBackground))
        .environment(\.colorScheme, .dark)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ title: String, _ f: TagField) -> some View {
        GridRow {
            label(title)
            field(f)
        }
    }

    private func field(_ f: TagField) -> some View {
        TextField(initial[f] == nil ? "Mixed" : "", text: Binding(get: { values[f] ?? "" }, set: { values[f] = $0 }))
            .textFieldStyle(.roundedBorder)
    }
}

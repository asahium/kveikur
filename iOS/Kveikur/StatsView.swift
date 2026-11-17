import Charts
import KveikurCore
import SwiftUI

struct StatsView: View {
    enum Range: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "Year", all = "All"
        var id: String { rawValue }

        var since: Date? {
            let today = Calendar.current.startOfDay(for: Date())
            switch self {
            case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today)
            case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today)
            case .year: return Calendar.current.date(byAdding: .day, value: -364, to: today)
            case .all: return nil
            }
        }
    }

    @EnvironmentObject var model: MobileModel
    @ObservedObject var scrobbler: ScrobbleController
    @Environment(\.dismiss) private var dismiss
    @State private var range: Range = .month
    @State private var stats = ListeningStats()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if stats.plays == 0 {
                    Text(scrobbler.importing ? "Importing Last.fm history…" : "No plays yet. A track counts after half of it or four minutes.")
                        .foregroundStyle(Nord.secondary)
                        .listRowBackground(Nord.raised)
                } else {
                    Section {
                        HStack {
                            figure("\(stats.plays)", "plays")
                            figure(hours(stats.seconds), "listened")
                            figure("\(stats.artists)", "artists")
                        }
                        Chart(stats.days, id: \.day) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.seconds / 60))
                                .foregroundStyle(Nord.accent)
                        }
                        .frame(height: 110)
                    }
                    .listRowBackground(Nord.raised)
                    top("Artists", stats.topArtists)
                    top("Albums", stats.topAlbums)
                    top("Tracks", stats.topTracks)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nord.background)
            .navigationTitle("Listening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { scrobbler.importHistory(); await load() }
            .task(id: range) { await load() }
            .onChange(of: scrobbler.importing) { _, busy in if !busy { Task { await load() } } }
        }
    }

    private func load() async {
        let library = model.library
        let since = range.since
        stats = await Task.detached { library.stats(since: since) }.value
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Nord.n6)
            Text(label).font(.caption).foregroundStyle(Nord.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func top(_ title: String, _ items: [ListeningStats.Item]) -> some View {
        Section(title) {
            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { i, item in
                HStack {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Nord.secondary).frame(width: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? "—" : item.title).foregroundStyle(Nord.n6).lineLimit(1)
                        if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(Nord.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text("\(item.plays)").font(.footnote.monospacedDigit()).foregroundStyle(Nord.secondary)
                }
            }
        }
        .listRowBackground(Nord.raised)
    }

    private func hours(_ s: Double) -> String {
        s >= 3600 ? String(format: "%.1f h", s / 3600) : "\(Int(s / 60)) min"
    }
}

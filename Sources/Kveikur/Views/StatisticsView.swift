import Charts
import KveikurCore
import SwiftUI

@MainActor
final class StatisticsModel: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "Year", all = "All Time"
        var id: String { rawValue }

        var since: Date? {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            switch self {
            case .week: return cal.date(byAdding: .day, value: -6, to: today)
            case .month: return cal.date(byAdding: .day, value: -29, to: today)
            case .year: return cal.date(byAdding: .day, value: -364, to: today)
            case .all: return nil
            }
        }
    }

    @Published var range: Range = .month { didSet { load() } }
    @Published private(set) var stats = ListeningStats()

    let app: AppModel
    var onShow: ((URL) -> Void)?

    init(app: AppModel) {
        self.app = app
    }

    func load() {
        let library = app.library
        let since = range.since
        Task {
            stats = await Task.detached { library.stats(since: since) }.value
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var model: StatisticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $model.range) {
                    ForEach(StatisticsModel.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
            }
            if model.stats.plays == 0 {
                Text("No plays recorded yet. A track counts once you've heard half of it or four minutes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                totals
                chart
                HStack(alignment: .top, spacing: 16) {
                    top("Artists", model.stats.topArtists, reveal: false)
                    top("Albums", model.stats.topAlbums, reveal: false)
                    top("Tracks", model.stats.topTracks, reveal: true)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: Theme.inspectorBackground))
        .environment(\.colorScheme, .dark)
        .onAppear { model.load() }
        .onReceive(model.app.$historyVersion.dropFirst()) { _ in model.load() }
    }

    private var totals: some View {
        HStack(spacing: 28) {
            figure("\(model.stats.plays)", "plays")
            figure(hours(model.stats.seconds), "listened")
            figure("\(model.stats.tracks)", "tracks")
            figure("\(model.stats.artists)", "artists")
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart(model.stats.days, id: \.day) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.seconds / 60))
                .foregroundStyle(Color(nsColor: Theme.nord8))
        }
        .chartYAxisLabel("min")
        .frame(height: 140)
    }

    private func top(_ title: String, _ items: [ListeningStats.Item], reveal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title.isEmpty ? "—" : item.title).font(.system(size: 12)).lineLimit(1)
                                if let s = item.subtitle { Text(s).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 4)
                            Text("\(item.plays)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if reveal { model.onShow?(URL(fileURLWithPath: item.key)) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hours(_ s: Double) -> String {
        s >= 3600 ? String(format: "%.1f h", s / 3600) : "\(Int(s / 60)) min"
    }
}

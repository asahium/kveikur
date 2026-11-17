import AppKit
import KveikurCore

final class ColumnTableView: NSTableView {
    var onBackForward: ((Bool) -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: onBackForward?(true)
        case 4: onBackForward?(false)
        default: super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return super.menu(for: event)
    }
}

final class EntryCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    var nameColor: NSColor = Theme.text
    var iconColor: NSColor = Theme.secondaryText
    var selectedColor: NSColor = Theme.selectionText

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func applyColors() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? selectedColor : nameColor
        icon.contentTintColor = selected ? selectedColor : iconColor
        detail.textColor = selected ? selectedColor.withAlphaComponent(0.75) : Theme.secondaryText
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [icon, name, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = icon
        textField = name
        name.lineBreakMode = .byTruncatingTail
        name.font = Self.font
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = Theme.secondaryText
        detail.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
}

/// Data source for one of the three columns.
@MainActor
final class ColumnController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Role { case parent, current, preview }

    let role: Role
    let table = ColumnTableView()
    let scroll = NSScrollView()
    private(set) var entries: [Entry] = []
    weak var browser: BrowserModel?
    var playingPath: String?
    var showDetails: Bool

    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?

    private static let symbols: [Entry.Kind: String] = [
        .root: "music.note.house.fill", .folder: "folder.fill", .track: "music.note",
        .playlist: "music.note.list", .playlistsRoot: "list.bullet.rectangle",
    ]

    init(role: Role) {
        self.role = role
        showDetails = role == .current
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 21
        table.style = .plain
        table.allowsTypeSelect = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
    }

    func set(_ list: [Entry], highlight: Int?) {
        let changed = list != entries
        entries = list
        if changed { table.reloadData() } else { refreshVisibleRows() }
        select(highlight)
    }

    func refreshVisibleRows() {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { table.reloadData(); return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<range.location + range.length),
                         columnIndexes: IndexSet(integer: 0))
    }

    func select(_ row: Int?) {
        guard let r = row, entries.indices.contains(r) else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRow != r { table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        table.scrollRowToVisible(r)
    }

    var visibleRowCount: Int { max(1, Int(scroll.contentView.bounds.height / table.rowHeight)) }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        onClick?(row, NSApp.currentEvent?.modifierFlags ?? [])
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        onDoubleClick?(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? EntryCell ?? {
            let c = EntryCell()
            c.identifier = id
            return c
        }()
        let e = entries[row]
        let playing = e.kind == .track && e.url?.path == playingPath
        let symbol = playing ? "speaker.wave.2.fill" : (Self.symbols[e.kind] ?? "doc")
        cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.name.stringValue = browser?.displayName(e) ?? e.name
        let marked = role == .current && (browser?.isMarked(e, at: row) ?? false)
        let base: NSColor = switch e.kind {
        case .folder, .root, .playlistsRoot: Theme.folder
        case .playlist: Theme.playlist
        case .track: Theme.text
        }
        cell.nameColor = marked ? Theme.marked : (playing ? Theme.playing : base)
        cell.iconColor = marked ? Theme.marked : (playing ? Theme.playing : (e.kind == .track ? Theme.track : base))
        cell.selectedColor = role == .current ? Theme.selectionText : Theme.inactiveSelectionText
        cell.name.font = marked || playing ? EntryCell.boldFont : EntryCell.font
        cell.applyColors()
        if showDetails, let m = browser?.metadata(e) {
            var parts: [String] = []
            if m.duration > 0 { parts.append(Format.duration(m.duration)) }
            if let f = m.format { parts.append(f.shortLabel) }
            cell.detail.stringValue = parts.joined(separator: "  ")
        } else {
            cell.detail.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = PillRowView()
        v.dimmed = role != .current
        return v
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let u = entries[row].url else { return nil }
        return CueTrackRef.audioFile(u) as NSURL
    }
}

extension ColumnController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, let built = menuForRow?(row) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}

final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        bounds.fill()
    }
}

/// Lays out the first `visibleCount` columns side by side with equal widths.
final class AncestorPane: NSView {
    private let columns: [NSView]
    private let lines: [SeparatorLine]

    var visibleCount = 1 {
        didSet { if visibleCount != oldValue { needsLayout = true } }
    }

    init(columns: [NSView]) {
        self.columns = columns
        lines = columns.map { _ in SeparatorLine() }
        super.init(frame: .zero)
        for (c, l) in zip(columns, lines) {
            c.translatesAutoresizingMaskIntoConstraints = true
            addSubview(c)
            addSubview(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let n = max(1, min(visibleCount, columns.count))
        let w = bounds.width / CGFloat(n)
        for (i, (c, l)) in zip(columns, lines).enumerated() {
            let hidden = i >= n
            c.isHidden = hidden
            l.isHidden = hidden || i == n - 1
            guard !hidden else { continue }
            let x = (CGFloat(i) * w).rounded()
            let right = (CGFloat(i + 1) * w).rounded()
            c.frame = NSRect(x: x, y: 0, width: right - x - (i == n - 1 ? 0 : 1), height: bounds.height)
            l.frame = NSRect(x: right - 1, y: 0, width: 1, height: bounds.height)
        }
    }
}

/// yazi-style selection: a rounded accent pill, always drawn as emphasized so the text turns white.
final class PillRowView: NSTableRowView {
    var dimmed = false

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 1)
        (dimmed ? Theme.inactiveSelection : Theme.selection).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

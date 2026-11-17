import AppKit
import KveikurCore

struct PaletteItem: Sendable {
    enum Payload: Sendable {
        case folder(URL)
        case track(URL)
        case command(String)
        case queueIndex(Int)
        case playlist(URL)
        case newPlaylist
    }

    var title: String
    var subtitle: String
    var detail: String
    var payload: Payload
    /// Text the fuzzy matcher sees.
    var key: String
}

enum PaletteMode {
    case list(prompt: String, items: [PaletteItem])
    case prompt(prompt: String, initial: String)
}

/// Overlay with a query field and fuzzy-ranked results; arrows, Ctrl-N/P, Enter, Esc and the mouse all work.
@MainActor
final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSVisualEffectView()
    private let field = NSTextField()
    private let promptLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!

    private var index: FuzzyIndex<PaletteItem>?
    private var results: [PaletteItem] = []
    private var generation = 0
    private var isPrompt = false
    private let searchQueue = DispatchQueue(label: "kveikur.palette", qos: .userInitiated)

    var onSubmit: ((PaletteItem, NSEvent.ModifierFlags) -> Void)?
    var onPromptSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isOpen = false

    override init() {
        super.init()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false

        promptLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        promptLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Type to search…"

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let header = NSStackView(views: [promptLabel, NSView(), countLabel])
        let sep = NSBox()
        sep.boxType = .separator
        for v in [header, field, sep, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 420)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            heightConstraint,
        ])
    }

    func open(_ mode: PaletteMode, in window: NSWindow?) {
        isOpen = true
        view.isHidden = false
        generation += 1
        switch mode {
        case .list(let prompt, let items):
            isPrompt = false
            promptLabel.stringValue = prompt.uppercased()
            field.stringValue = ""
            scroll.isHidden = false
            heightConstraint.constant = 420
            results = Array(items.prefix(200))
            countLabel.stringValue = "\(items.count)"
            table.reloadData()
            selectRow(0)
            let gen = generation
            searchQueue.async {
                let idx = FuzzyIndex(items: items, key: \.key)
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.index = idx
                    if !self.field.stringValue.isEmpty { self.search(self.field.stringValue) }
                }
            }
        case .prompt(let prompt, let initial):
            isPrompt = true
            index = nil
            promptLabel.stringValue = prompt.uppercased()
            field.stringValue = initial
            countLabel.stringValue = ""
            scroll.isHidden = true
            heightConstraint.constant = 70
        }
        window?.makeFirstResponder(field)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        view.isHidden = true
        index = nil
        results = []
        table.reloadData()
        generation += 1
        onClose?()
    }

    private func search(_ q: String) {
        guard let idx = index else { return }
        generation += 1
        let gen = generation
        searchQueue.async {
            let hits = idx.search(q, limit: 300).map(\.item)
            let total = q.isEmpty ? idx.items.count : hits.count
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.results = hits
                self.countLabel.stringValue = "\(total)"
                self.table.reloadData()
                self.selectRow(0)
            }
        }
    }

    private func selectRow(_ r: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(r, results.count - 1))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func submit(modifiers: NSEvent.ModifierFlags) {
        if isPrompt {
            let text = field.stringValue
            close()
            onPromptSubmit?(text)
            return
        }
        let row = table.selectedRow
        guard results.indices.contains(row) else { return }
        let item = results[row]
        close()
        onSubmit?(item, modifiers)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        selectRow(table.clickedRow)
        submit(modifiers: [])
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        if !isPrompt { search(field.stringValue) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            selectRow(table.selectedRow + 1)
        case #selector(NSResponder.moveUp(_:)):
            selectRow(table.selectedRow - 1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            selectRow(table.selectedRow + 10)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            selectRow(table.selectedRow - 10)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            submit(modifiers: flags)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.insertTab(_:)):
            selectRow(table.selectedRow + 1)
        case #selector(NSResponder.insertBacktab(_:)):
            selectRow(table.selectedRow - 1)
        default:
            return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pc")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteCell ?? {
            let c = PaletteCell()
            c.identifier = id
            return c
        }()
        let item = results[row]
        cell.title.stringValue = item.title
        cell.subtitle.stringValue = item.subtitle
        cell.detail.stringValue = item.detail
        return cell
    }
}

final class PaletteCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        for t in [title, subtitle] { t.lineBreakMode = .byTruncatingMiddle }
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        for v in [texts, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: texts.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

import AppKit
import Combine
import KveikurCore
import SwiftUI

@MainActor
final class MainViewController: NSViewController, NSTextFieldDelegate, NSSplitViewDelegate {
    private let app: AppModel
    private let browser: BrowserModel
    private let inspector: InspectorModel
    private let ancestorCols = (0..<BrowserModel.maxAncestors).map { _ in ColumnController(role: .parent) }
    private lazy var ancestorPane = AncestorPane(columns: ancestorCols.map(\.scroll))
    private let inspectorPane = FilledView(color: Theme.inspectorBackground)
    private let previewPane = NSView()
    private let currentCol = ColumnController(role: .current)
    private let previewCol = ColumnController(role: .preview)
    private let palette = PaletteController()
    private let shortcutOverlay = ShortcutOverlay()
    private lazy var karaoke = KaraokeOverlay(inspector: inspector, player: app.player)
    private let commandHold = CommandHoldDetector()
    private lazy var fileActions = FileActions(app: app, browser: browser, inspector: inspector)
    private let router = KeyRouter()

    private let split = ThemedSplitView()
    private let previewStack = NSStackView()
    private var inspectorHost: NSView!
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let inputPrompt = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let emptyHint = NSTextField(labelWithString: "No music folders yet.\nPress ⌘O to add one.")

    private enum InputKind: Equatable { case filter, find(forward: Bool) }
    private var input: InputKind?
    private var findOrigin = 0
    private var monitor: Any?
    private var bag = Set<AnyCancellable>()
    private var didSetInitialSplit = false
    private var adjustingSplit = false
    private var shownAncestors = 1
    private var ancestorWidth: CGFloat {
        get { max(Self.minAncestorColumn, CGFloat(UserDefaults.standard.object(forKey: "ancestorColumnWidth") as? Double ?? 170)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "ancestorColumnWidth") }
    }
    private func storedWidth(_ key: String) -> CGFloat? {
        (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) }
    }
    private var lastPlayingURL: URL?

    init(app: AppModel) {
        self.app = app
        browser = BrowserModel(app: app)
        inspector = InspectorModel(app: app)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 780))
        view = root

        for c in ancestorCols + [currentCol, previewCol] {
            c.browser = browser
            c.table.onBackForward = { [weak self] back in back ? self?.browser.goBack() : self?.browser.goForward() }
        }

        previewStack.orientation = .vertical
        previewStack.spacing = 6
        previewStack.edgeInsets = NSEdgeInsetsZero
        previewStack.addArrangedSubview(previewCol.scroll)

        let host = NSHostingView(rootView: InspectorContent(model: inspector, player: app.player))
        let tabBar = NSHostingView(rootView: InspectorTabBar(model: inspector))
        host.sizingOptions = []
        tabBar.sizingOptions = [.intrinsicContentSize]
        tabBar.setContentHuggingPriority(.init(1), for: .horizontal)
        tabBar.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        inspectorHost = host
        for v in [tabBar, inspectorHost!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            inspectorPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: inspectorPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: inspectorPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: inspectorPane.trailingAnchor),
            inspectorHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            inspectorHost.bottomAnchor.constraint(equalTo: inspectorPane.bottomAnchor),
            inspectorHost.leadingAnchor.constraint(equalTo: inspectorPane.leadingAnchor),
            inspectorHost.trailingAnchor.constraint(equalTo: inspectorPane.trailingAnchor),
        ])

        let currentPane = NSView()
        currentCol.scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.alignment = .center
        emptyHint.textColor = Theme.secondaryText
        emptyHint.font = .systemFont(ofSize: 14)
        currentPane.addSubview(currentCol.scroll)
        currentPane.addSubview(emptyHint)
        NSLayoutConstraint.activate([
            currentCol.scroll.topAnchor.constraint(equalTo: currentPane.topAnchor),
            currentCol.scroll.bottomAnchor.constraint(equalTo: currentPane.bottomAnchor),
            currentCol.scroll.leadingAnchor.constraint(equalTo: currentPane.leadingAnchor),
            currentCol.scroll.trailingAnchor.constraint(equalTo: currentPane.trailingAnchor),
            emptyHint.centerXAnchor.constraint(equalTo: currentPane.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: currentPane.centerYAnchor),
        ])

        split.isVertical = true
        split.delegate = self
        for v in [previewStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            previewStack.topAnchor.constraint(equalTo: previewPane.topAnchor),
            previewStack.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            previewStack.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
        ])
        split.dividerStyle = .thin
        split.addSubview(ancestorPane)
        split.addSubview(currentPane)
        split.addSubview(previewPane)
        split.addSubview(inspectorPane)
        for pane in [currentPane, previewPane, inspectorPane] { ThemedSplitView.addLeadingEdge(to: pane) }
        inspectorPane.isHidden = UserDefaults.standard.bool(forKey: "inspectorHidden")

        let statusBar = makeStatusBar()
        let transport = NSHostingView(rootView: TransportBar(player: app.player) { [weak self] in self?.perform(.revealPlaying) })
        transport.wantsLayer = true
        transport.layer?.backgroundColor = Theme.barBackground.cgColor
        let sep1 = SeparatorLine()
        let sep2 = SeparatorLine()

        for v in [split, sep1, statusBar, sep2, transport, karaoke, palette.view, shortcutOverlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep1.topAnchor.constraint(equalTo: split.bottomAnchor),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep1.heightAnchor.constraint(equalToConstant: 1),
            sep2.heightAnchor.constraint(equalToConstant: 1),
            statusBar.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            sep2.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            palette.view.topAnchor.constraint(equalTo: root.topAnchor, constant: 60),
            palette.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            palette.view.widthAnchor.constraint(equalToConstant: 680),
            karaoke.topAnchor.constraint(equalTo: root.topAnchor),
            karaoke.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            karaoke.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            karaoke.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shortcutOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            shortcutOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            shortcutOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shortcutOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        wireUp()
    }

    private func makeStatusBar() -> NSView {
        let bar = FilledView(color: Theme.barBackground)
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Theme.secondaryText
        statusLabel.alignment = .right
        inputPrompt.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        inputPrompt.textColor = Theme.nord8
        pathLabel.textColor = Theme.nord8
        inputField.textColor = Theme.text
        inputField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputPrompt.isHidden = true
        inputField.isHidden = true
        let stack = NSStackView(views: [pathLabel, inputPrompt, inputField, statusLabel])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        inputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialSplit, split.bounds.width > 100 else { return }
        didSetInitialSplit = true
        let w = split.bounds.width
        let d = split.dividerThickness
        let insp = inspectorPane.isHidden ? 0 : inspectorTargetWidth
        let preview = previewPane.isHidden ? 0 : previewTargetWidth
        let n = max(1, browser.ancestors.count)
        let anc = ancestorWidth * CGFloat(n)
        let visibleDividers = CGFloat(split.subviews.filter { !$0.isHidden }.count - 1)
        setPaneWidths([anc, max(Self.minWidth[1], w - anc - preview - insp - visibleDividers * d), preview, insp])
        shownAncestors = n
        layoutAncestors()
    }

    private var previewTargetWidth: CGFloat {
        min(max(storedWidth("previewPaneWidth") ?? split.bounds.width * 0.24, Self.minWidth[2]), split.bounds.width * 0.3)
    }

    /// The preview column only exists when the current folder has subfolders; track-only folders get the full width.
    private func setPreviewHidden(_ hidden: Bool) {
        guard hidden != previewPane.isHidden else { return }
        guard didSetInitialSplit else { previewPane.isHidden = hidden; return }
        let d = split.dividerThickness
        var widths = split.subviews.map(\.frame.width)
        previewPane.isHidden = hidden
        if hidden {
            widths[1] += widths[2] + d
        } else {
            widths[2] = previewTargetWidth
            widths[1] = max(Self.minWidth[1], widths[1] - widths[2] - d)
        }
        setPaneWidths(widths)
    }

    private var inspectorTargetWidth: CGFloat {
        min(max(storedWidth("inspectorPaneWidth") ?? 340, Self.minWidth[3]), split.bounds.width * 0.4)
    }

    /// Assigns pane frames directly; NSSplitView's setPosition is clamped by the delegate against stale frames.
    private func setPaneWidths(_ widths: [CGFloat]) {
        let d = split.dividerThickness
        let visible = zip(split.subviews, widths).filter { !$0.0.isHidden }
        var x: CGFloat = 0
        adjustingSplit = true
        for (i, (v, w)) in visible.enumerated() {
            let width = i == visible.count - 1 ? max(0, split.bounds.width - x) : w.rounded()
            v.frame = NSRect(x: x, y: 0, width: width, height: split.bounds.height)
            x += width + d
        }
        split.adjustSubviews()
        adjustingSplit = false
    }

    /// Minimum widths of ancestors, current, preview and inspector panes.
    private static let minWidth: [CGFloat] = [100, 220, 160, 280]
    private static let minAncestorColumn: CGFloat = 110

    /// One column per ancestor (1…maxAncestors); the left pane grows with depth, the panes to the right keep their width.
    private func layoutAncestors() {
        let n = max(1, browser.ancestors.count)
        let offset = n - browser.ancestors.count
        ancestorPane.visibleCount = n
        for (i, c) in ancestorCols.enumerated() {
            let j = i - offset
            let a = browser.ancestors.indices.contains(j) ? browser.ancestors[j] : nil
            c.set(a?.entries ?? [], highlight: a?.highlight)
        }
        guard didSetInitialSplit, n != shownAncestors else { return }
        shownAncestors = n
        var widths = split.subviews.map(\.frame.width)
        let room = widths[0] + widths[1] - Self.minWidth[1]
        let target = min(ancestorWidth * CGFloat(n), max(room, Self.minWidth[0]))
        widths[1] -= target - widths[0]
        widths[0] = target
        setPaneWidths(widths)
    }

    /// Persists widths only when the user drags a divider, never for programmatic or window-driven resizes.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !adjustingSplit, didSetInitialSplit,
              let idx = notification.userInfo?["NSSplitViewDividerIndex"] as? Int,
              let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseUp else { return }
        let d = UserDefaults.standard
        switch idx {
        case 0:
            ancestorWidth = max(Self.minAncestorColumn, ancestorPane.frame.width / CGFloat(max(1, shownAncestors)))
        default:
            if !previewPane.isHidden {
                d.set(Double(previewPane.frame.width), forKey: "previewPaneWidth")
            }
            if !inspectorPane.isHidden, inspectorPane.frame.width >= Self.minWidth[3] {
                d.set(Double(inspectorPane.frame.width), forKey: "inspectorPaneWidth")
            }
        }
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === splitView.subviews[1]
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView.subviews[i].frame.minX + Self.minWidth[i]
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        let next = splitView.subviews[i + 1]
        let edge = i + 1 == splitView.subviews.count - 1 || next.isHidden ? splitView.bounds.width : next.frame.maxX
        return edge - Self.minWidth[i + 1] - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let path = ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT"] {
            let actions = (ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_ACTIONS"] ?? "")
                .split(separator: ",").compactMap { Command(rawValue: String($0)) }
            if ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_SHORTCUTS"] != nil { shortcutOverlay.show() }
            for (i, c) in actions.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * Double(ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_STEP"] ?? "0.4")!) { [weak self] in self?.perform(c) }
            }
            if let size = ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2, let w = view.window {
                w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: size[0], height: size[1])), display: true)
            }
            NSApp.activate()
            let fileAction = ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_FILE"]
            if let a = fileAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(actions.count) * 0.4) { [weak self] in
                    let item = NSMenuItem()
                    item.representedObject = a
                    self?.fileMenu(item)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(actions.count) * 0.4) { [weak self] in
                let named = ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT_WINDOW"]
                let sheet = fileAction != nil ? self?.view.window?.attachedSheet : nil
                guard let w = sheet ?? named.flatMap({ n in NSApp.windows.first { $0.title == n } }) ?? self?.view.window,
                      let v = w.contentView else { return }
                var rep = Self.windowImage(w).map(NSBitmapImageRep.init(cgImage:))
                if rep == nil, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: r)
                    rep = r
                }
                try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        view.window?.makeFirstResponder(currentCol.table)
    }

    /// The window as the window server draws it; `cacheDisplay` drops layer backgrounds.
    /// `CGWindowListCreateImage` is unavailable in the macOS 15 SDK but still works for own windows.
    private static func windowImage(_ w: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(sym, to: Capture.self)
        return capture(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    private func setInspectorHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: "inspectorHidden")
        guard hidden != inspectorPane.isHidden else { return }
        let d = split.dividerThickness
        var widths = split.subviews.map(\.frame.width)
        let insp = inspectorTargetWidth
        inspectorPane.isHidden = hidden
        if hidden {
            widths[1] += widths[3] + d
            widths[3] = 0
        } else {
            widths[1] = max(Self.minWidth[1], widths[1] - insp - d)
            widths[3] = insp
        }
        setPaneWidths(widths)
    }

    // MARK: State

    func saveState() {
        browser.saveState()
        if let data = try? JSONEncoder().encode(app.player.snapshot()) {
            UserDefaults.standard.set(data, forKey: "playerState")
        }
    }

    private func restorePlayer() {
        guard let data = UserDefaults.standard.data(forKey: "playerState"),
              let s = try? JSONDecoder().decode(PlayerSnapshot.self, from: data) else { return }
        app.player.restore(s)
    }

    // MARK: Wiring

    private func wireUp() {
        browser.onChange = { [weak self] change in self?.apply(change) }

        currentCol.onClick = { [weak self] row, flags in
            guard let self else { return }
            if flags.contains(.command) {
                self.browser.setCursor(row)
                self.browser.toggleMark(advance: false)
            } else if flags.contains(.shift) {
                self.browser.setCursor(row, extendMarks: true)
            } else {
                self.browser.setCursor(row)
            }
            self.view.window?.makeFirstResponder(self.currentCol.table)
        }
        currentCol.onDoubleClick = { [weak self] row in
            self?.browser.setCursor(row)
            self?.open(self?.browser.cursorEntry)
        }
        currentCol.menuForRow = { [weak self] row in self?.contextMenu(row: row) }

        for (i, c) in ancestorCols.enumerated() {
            c.onClick = { [weak self] row, _ in self?.openAncestorRow(column: i, row: row) }
            c.onDoubleClick = { [weak self] row in self?.openAncestorRow(column: i, row: row) }
        }

        previewCol.onClick = { [weak self] row, _ in self?.openPreviewRow(row, activate: false) }
        previewCol.onDoubleClick = { [weak self] row in self?.openPreviewRow(row, activate: true) }

        palette.onClose = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.currentCol.table)
        }

        commandHold.onHold = { [weak self] in
            guard let self, self.view.window?.isKeyWindow == true, !self.palette.isOpen else { return }
            self.shortcutOverlay.show()
        }
        commandHold.onRelease = { [weak self] in self?.shortcutOverlay.hide() }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commandHold.cancel() }
            }
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .swipe]) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var result: NSEvent?
            MainActor.assumeIsolated { result = self.handle(e) }
            return result
        }

        app.player.$index.combineLatest(app.player.$queue)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.playingChanged() }
            }
            .store(in: &bag)
        app.$roots.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.browser.invalidate(.home)
                self?.updateStatus()
            }
        }.store(in: &bag)
        app.$showTagTitles.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAllRows() }
        }.store(in: &bag)
        app.$scanStatus.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }.store(in: &bag)
        inspector.$followCursor.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.updatePreview() } }.store(in: &bag)
        inspector.$tab.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.updatePreview() } }.store(in: &bag)

        app.onFilesChanged = { [weak self] paths in self?.browser.clearCache(paths: paths) }
        app.onLibraryIndexed = { [weak self] in self?.refreshAllRows() }
        app.$historyVersion.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.browser.historyChanged() } }.store(in: &bag)

        restorePlayer()
        browser.start()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveState() }
        }
    }

    private func apply(_ change: BrowserChange) {
        if change.contains(.current) {
            currentCol.set(browser.visible, highlight: browser.cursor)
        } else if change.contains(.cursor) {
            currentCol.select(browser.cursor)
        }
        if change.contains(.parent) { layoutAncestors() }
        if change.contains(.preview) { updatePreview() }
        if change.contains(.status) || change.contains(.current) { updateStatus() }
        emptyHint.isHidden = !(browser.location == .home && app.roots.isEmpty)
    }

    private func refreshAllRows() {
        currentCol.refreshVisibleRows()
        ancestorCols.forEach { $0.refreshVisibleRows() }
        previewCol.refreshVisibleRows()
    }

    private func playingChanged() {
        let path = app.player.currentURL?.path
        for c in ancestorCols + [currentCol, previewCol] { c.playingPath = path }
        refreshAllRows()
        let now = app.player.currentURL
        if now != lastPlayingURL {
            lastPlayingURL = now
            if now != nil, inspectorPane.isHidden { setInspectorHidden(false) }
        }
        updatePreview()
    }

    /// The preview column lists the folder under the cursor and stays empty for tracks. The inspector sticks to the
    /// loaded track, paused or not, until another one starts; `followCursor` makes it show the cursor track instead.
    private func updatePreview() {
        var cursorTrack: URL?
        if case .track(let u) = browser.preview { cursorTrack = u }
        let playing = app.player.currentURL
        inspector.showInfo(inspector.followCursor ? (cursorTrack ?? playing) : (playing ?? cursorTrack))
        setPreviewHidden(!browser.visible.contains { $0.isContainer })
        if case .entries(_, let list) = browser.preview {
            previewCol.set(list, highlight: nil)
        } else {
            previewCol.set([], highlight: nil)
        }
    }

    private func updateStatus() {
        pathLabel.stringValue = locationTitle(browser.location)
        var parts: [String] = []
        if !router.pendingKeys.isEmpty { parts.append(router.pendingKeys) }
        if !app.scanStatus.isEmpty { parts.append(app.scanStatus) }
        if browser.isVisual { parts.append("VISUAL") }
        if !browser.filter.isEmpty, input != .filter { parts.append("filter: \(browser.filter)") }
        if browser.markCount > 0 { parts.append("\(browser.markCount) selected") }
        if browser.loading { parts.append("loading…") }
        let n = browser.visible.count
        parts.append(n == 0 ? "0/0" : "\(browser.cursor + 1)/\(n)")
        statusLabel.stringValue = parts.joined(separator: "   ")
    }

    private func locationTitle(_ loc: Location) -> String {
        switch loc {
        case .home: return "Library"
        case .playlists: return "Playlists"
        case .playlist(let u): return "Playlists/" + u.deletingPathExtension().lastPathComponent
        case .smart(let k): return "Playlists/" + k.title
        case .folder(let u):
            let home = NSHomeDirectory()
            return u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path
        }
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === view.window else { return event }
        if event.type == .flagsChanged {
            commandHold.flagsChanged(event)
            return event
        }
        if event.type == .keyDown { commandHold.cancel() }
        if event.type == .swipe {
            if event.deltaX > 0 { browser.goBack() } else if event.deltaX < 0 { browser.goForward() }
            return nil
        }
        if palette.isOpen || input != nil { return event }
        if let tv = view.window?.firstResponder as? NSTextView, tv.isEditable { return event }
        guard let token = Keymap.token(for: event) else { return event }
        if karaoke.isShown, token == "<Esc>" {
            karaoke.hide()
            router.reset()
            return nil
        }
        switch router.handle(token) {
        case .command(let c):
            perform(c)
            updateStatus()
            return nil
        case .consumed:
            updateStatus()
            return nil
        case .passThrough:
            return event
        }
    }

    func perform(_ c: Command) {
        let page = currentCol.visibleRowCount
        let player = app.player
        switch c {
        case .down: browser.moveCursor(by: 1)
        case .up: browser.moveCursor(by: -1)
        case .top: browser.setCursor(0)
        case .bottom: browser.setCursor(browser.visible.count - 1)
        case .halfDown: browser.moveCursor(by: max(1, page / 2))
        case .halfUp: browser.moveCursor(by: -max(1, page / 2))
        case .pageDown: browser.moveCursor(by: page)
        case .pageUp: browser.moveCursor(by: -page)
        case .extendDown: browser.setCursor(browser.cursor + 1, extendMarks: true)
        case .extendUp: browser.setCursor(browser.cursor - 1, extendMarks: true)
        case .parent: browser.goParent()
        case .open: open(browser.cursorEntry)
        case .back: browser.goBack()
        case .forward: browser.goForward()
        case .home: browser.goHome()
        case .playlists: browser.navigate(to: .playlists)
        case .revealPlaying:
            if let u = player.currentURL { browser.reveal(u) }
        case .find: beginInput(.find(forward: true))
        case .findBack: beginInput(.find(forward: false))
        case .findNext: browser.findNext(reverse: false)
        case .findPrev: browser.findNext(reverse: true)
        case .filter: beginInput(.filter)
        case .jumpFolder: openFolderJump()
        case .searchTracks: openTrackSearch()
        case .palette: openCommandPalette()
        case .toggleMark: browser.toggleMark()
        case .toggleVisual: browser.toggleVisual()
        case .clearMarks: browser.clearMarks()
        case .selectAll: browser.markAll()
        case .play: playTargets(.replace)
        case .playAll:
            Task {
                let urls = await browser.tracks(for: browser.entries)
                app.player.play(urls)
            }
        case .enqueue: playTargets(.append)
        case .playNext: playTargets(.next)
        case .playPause: player.playPause()
        case .nextTrack: player.next()
        case .prevTrack: player.previous()
        case .seekForward: player.seek(by: 5)
        case .seekBackward: player.seek(by: -5)
        case .volumeUp: player.volume = min(1, player.volume + 0.05)
        case .volumeDown: player.volume = max(0, player.volume - 0.05)
        case .toggleShuffle: player.shuffle.toggle()
        case .cycleRepeat: player.repeatMode = TransportBar.nextRepeat(player.repeatMode)
        case .cycleInspectorTab: inspector.cycleTab(by: 1)
        case .prevInspectorTab: inspector.cycleTab(by: -1)
        case .tabInfo: inspector.tab = .info
        case .tabLyrics: inspector.tab = .lyrics
        case .tabQueue: inspector.tab = .queue
        case .tabAnalysis: inspector.tab = .analysis
        case .tabOutput: inspector.tab = .output
        case .pinNowPlaying: inspector.followCursor.toggle()
        case .fetchLyrics:
            inspector.tab = .lyrics
            inspector.fetchOnline()
        case .revealInFinder:
            let urls = Array(Set(browser.targets().compactMap(\.url).map(CueTrackRef.audioFile)))
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .copyPath:
            let paths = browser.targets().compactMap { $0.url.map(CueTrackRef.audioFile)?.path }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        case .showQueue: openQueue()
        case .addToPlaylist: openPlaylistPicker()
        case .newPlaylist: promptNewPlaylist(with: browser.targets())
        case .removeFromPlaylist: removeFromPlaylist()
        case .moveEntryDown: movePlaylistEntry(by: 1)
        case .moveEntryUp: movePlaylistEntry(by: -1)
        case .rescan: app.rescan()
        case .togglePreview: setInspectorHidden(!inspectorPane.isHidden)
        case .addFolder:
            app.chooseFolder(title: "Add music folder") { [weak self] u in
                self?.app.addRoot(u)
                self?.browser.navigate(to: .folder(u.standardizedFileURL))
            }
        case .settings:
            NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
        case .equalizer:
            NSApp.sendAction(#selector(AppDelegate.showEqualizer), to: nil, from: nil)
        case .duplicates:
            NSApp.sendAction(#selector(AppDelegate.showDuplicates), to: nil, from: nil)
        case .statistics:
            NSApp.sendAction(#selector(AppDelegate.showStatistics), to: nil, from: nil)
        case .toggleEQ: player.equalizer.enabled.toggle()
        case .karaoke: karaoke.toggle()
        case .cycleReplayGain:
            let all = ReplayGainMode.allCases
            player.replayGain.mode = all[(all.firstIndex(of: player.replayGain.mode)! + 1) % all.count]
        case .escape:
            if browser.isVisual || browser.markCount > 0 {
                browser.clearMarks()
            } else if !browser.filter.isEmpty {
                browser.setFilter("")
            }
            router.reset()
        }
    }

    // MARK: Actions

    private func open(_ e: Entry?) {
        guard let e else { return }
        if let loc = e.location {
            browser.navigate(to: loc)
        } else if e.kind == .track {
            playListing(startingAt: e)
        }
    }

    /// Queue = tracks of the current listing, starting from `e`.
    private func playListing(startingAt e: Entry) {
        let tracks = browser.currentTracks
        let urls = tracks.compactMap(\.url)
        let start = tracks.firstIndex { $0.id == e.id } ?? 0
        app.player.play(urls, startAt: start)
    }

    private enum PlayMode { case replace, append, next }

    private func playTargets(_ mode: PlayMode) {
        let targets = browser.targets()
        let usedMarks = browser.markCount > 0
        if mode == .replace, !usedMarks, targets.count == 1, targets[0].kind == .track {
            playListing(startingAt: targets[0])
            return
        }
        Task {
            let urls = await browser.tracks(for: targets)
            guard !urls.isEmpty else { return }
            switch mode {
            case .replace: app.player.play(urls)
            case .append: app.player.enqueue(urls)
            case .next: app.player.playNext(urls)
            }
            if usedMarks { browser.clearMarks() }
        }
    }

    private func openAncestorRow(column: Int, row: Int) {
        let i = column - (max(1, browser.ancestors.count) - browser.ancestors.count)
        guard browser.ancestors.indices.contains(i), browser.ancestors[i].entries.indices.contains(row) else { return }
        let e = browser.ancestors[i].entries[row]
        if let loc = e.location { browser.navigate(to: loc) } else if let u = e.url { browser.reveal(u) }
    }

    private func openPreviewRow(_ row: Int, activate: Bool) {
        guard case .entries(let loc, let list) = browser.preview, list.indices.contains(row) else { return }
        let e = list[row]
        browser.navigate(to: loc, cursorOn: e.id)
        if activate { open(e) }
    }

    private func playFolder(containing url: URL) {
        Task {
            let entries = await Task.detached { BrowserModel.listFolder(url.deletingLastPathComponent()) }.value
            let tracks = entries.filter { $0.kind == .track }.compactMap(\.url)
            app.player.play(tracks, startAt: tracks.firstIndex(of: url) ?? 0)
        }
    }

    private func removeFromPlaylist() {
        guard case .playlist(let u) = browser.location else { return }
        let idx = IndexSet(browser.targets().compactMap(\.playlistIndex))
        guard !idx.isEmpty else { return }
        try? app.playlists.remove(at: idx, from: u)
        browser.clearMarks()
        browser.invalidate(.playlist(u))
    }

    private func movePlaylistEntry(by d: Int) {
        guard case .playlist(let u) = browser.location, let e = browser.cursorEntry, let i = e.playlistIndex,
              browser.filter.isEmpty else { return }
        let j = i + d
        guard j >= 0, j < browser.entries.count else { return }
        try? app.playlists.move(from: i, to: j, in: u)
        browser.navigate(to: .playlist(u), record: false, cursorOn: "\(j):\(e.url?.path ?? "")")
        browser.invalidate(.playlist(u))
    }

    private func contextMenu(row: Int) -> NSMenu {
        if browser.visible.indices.contains(row), !browser.isMarked(browser.visible[row], at: row) {
            browser.setCursor(row)
        }
        let menu = NSMenu()
        func add(_ title: String, _ c: Command) {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            menu.addItem(item)
        }
        if browser.cursorEntry?.isContainer == true { add("Open", .open) }
        add("Play", .play)
        add("Play Next", .playNext)
        add("Add to Queue", .enqueue)
        menu.addItem(.separator())
        add("Add to Playlist…", .addToPlaylist)
        add("New Playlist from Selection…", .newPlaylist)
        if case .playlist = browser.location { add("Remove from Playlist", .removeFromPlaylist) }
        menu.addItem(.separator())
        if browser.cursorEntry?.kind == .track {
            add("Show Lyrics", .fetchLyrics)
        }
        add("Reveal in Finder", .revealInFinder)
        add("Copy Path", .copyPath)

        let targets = browser.targets()
        let modifiable = targets.filter(FileActions.canModify)
        func file(_ title: String, _ action: String, color: NSColor? = nil) {
            let item = NSMenuItem(title: title, action: #selector(fileMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            if let color { item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color]) }
            menu.addItem(item)
        }
        if targets.contains(where: { $0.kind == .track || $0.kind == .folder || $0.kind == .playlist }) || !modifiable.isEmpty {
            menu.addItem(.separator())
        }
        if targets.contains(where: { $0.kind == .track || $0.kind == .folder || $0.kind == .playlist }) {
            file(targets.count == 1 && targets[0].kind == .track ? "Edit Tags…" : "Edit Tags of Selection…", "tags")
        }
        if targets.count == 1, FileActions.canModify(targets[0]) { file("Rename…", "rename") }
        if !modifiable.isEmpty {
            file(modifiable.count == 1 ? "Move to Trash…" : "Move \(modifiable.count) Items to Trash…", "trash", color: .systemRed)
        }
        return menu
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Command(rawValue: raw) else { return }
        perform(c)
    }

    /// Folders open in the browser; files are revealed with the cursor on them.
    func show(_ url: URL) {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue {
            browser.navigate(to: .folder(url))
        } else {
            browser.reveal(url)
        }
    }

    func trash(urls: [URL], from window: NSWindow, then done: @escaping ([URL]) -> Void) {
        fileActions.window = view.window
        fileActions.trash(urls: urls, from: window, then: done)
    }

    @objc private func fileMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        fileActions.window = view.window
        let targets = browser.targets()
        switch action {
        case "tags": fileActions.editTags(targets)
        case "rename": if let e = targets.first { fileActions.rename(e) }
        case "trash": fileActions.trash(targets)
        default: break
        }
    }

    // MARK: Palettes

    private func openFolderJump() {
        let library = app.library
        let roots = app.roots
        Task { [weak self] in
            guard let self else { return }
            let folders = await Task.detached { library.allFolders() }.value
            let all = Array(Set(folders + roots.map(\.path))).sorted()
            let items = all.map { path -> PaletteItem in
                let root = roots.first { path == $0.path || path.hasPrefix($0.path + "/") }
                let rel = root.map { $0.lastPathComponent + path.dropFirst($0.path.count) } ?? path
                return PaletteItem(title: (path as NSString).lastPathComponent, subtitle: rel, detail: "",
                                   payload: .folder(URL(fileURLWithPath: path)), key: rel)
            }
            palette.onSubmit = { [weak self] item, _ in
                if case .folder(let u) = item.payload { self?.browser.navigate(to: .folder(u)) }
            }
            palette.open(.list(prompt: "Jump to folder", items: items), in: view.window)
        }
    }

    private func openTrackSearch() {
        let library = app.library
        Task { [weak self] in
            guard let self else { return }
            let rows = await Task.detached { library.searchRows() }.value
            let items = rows.map { r -> PaletteItem in
                let file = (r.path as NSString).lastPathComponent
                let title = r.title ?? (file as NSString).deletingPathExtension
                let sub = [r.artist, r.album].compactMap { $0 }.joined(separator: " — ")
                let folder = ((r.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return PaletteItem(title: title, subtitle: sub.isEmpty ? folder : sub, detail: "",
                                   payload: .track(URL(fileURLWithPath: r.path)),
                                   key: "\(title) \(r.artist ?? "") \(r.album ?? "") \(folder)")
            }
            palette.onSubmit = { [weak self] item, flags in
                guard let self, case .track(let u) = item.payload else { return }
                if flags.contains(.command) {
                    self.app.player.enqueue([u])
                } else if flags.contains(.shift) {
                    self.playFolder(containing: u)
                } else {
                    self.browser.reveal(u)
                }
            }
            palette.open(.list(prompt: "Search tracks  ·  ⏎ reveal  ⇧⏎ play  ⌘⏎ queue", items: items), in: view.window)
        }
    }

    private func openCommandPalette() {
        let items = Command.allCases.filter { $0 != .escape && $0 != .palette }.map { c in
            PaletteItem(title: c.title, subtitle: "", detail: Keymap.keys(for: c).prefix(3).joined(separator: "  "),
                        payload: .command(c.rawValue), key: c.title)
        }
        palette.onSubmit = { [weak self] item, _ in
            if case .command(let raw) = item.payload, let c = Command(rawValue: raw) { self?.perform(c) }
        }
        palette.open(.list(prompt: "Commands and keys", items: items), in: view.window)
    }

    private func openQueue() {
        let player = app.player
        let items = player.queue.enumerated().map { i, u -> PaletteItem in
            let m = app.metadata.cached(u.path)
            let sub = [m?.artist, m?.album].compactMap { $0 }.joined(separator: " — ")
            var detail = m.map { Format.duration($0.duration) } ?? ""
            if i == player.index { detail = "▶ " + detail }
            return PaletteItem(title: m?.displayTitle ?? u.deletingPathExtension().lastPathComponent,
                               subtitle: sub, detail: detail, payload: .queueIndex(i),
                               key: "\(m?.displayTitle ?? u.lastPathComponent) \(sub)")
        }
        palette.onSubmit = { [weak self] item, flags in
            guard case .queueIndex(let i) = item.payload else { return }
            if flags.contains(.command) { self?.app.player.removeFromQueue(at: i) } else { self?.app.player.jump(toQueueIndex: i) }
        }
        palette.open(.list(prompt: "Queue (\(items.count))  ·  ⏎ play  ⌘⏎ remove", items: items), in: view.window)
    }

    private func openPlaylistPicker() {
        let targets = browser.targets()
        var items = [PaletteItem(title: "New playlist…", subtitle: "", detail: "gn", payload: .newPlaylist, key: "new playlist")]
        items += app.playlists.playlists().map {
            PaletteItem(title: $0.deletingPathExtension().lastPathComponent, subtitle: "", detail: "",
                        payload: .playlist($0), key: $0.lastPathComponent)
        }
        palette.onSubmit = { [weak self] item, _ in
            guard let self else { return }
            switch item.payload {
            case .newPlaylist:
                DispatchQueue.main.async { self.promptNewPlaylist(with: targets) }
            case .playlist(let u):
                Task {
                    let urls = await self.browser.tracks(for: targets)
                    try? self.app.playlists.append(self.playlistEntries(urls), to: u)
                    self.browser.invalidate(.playlist(u))
                    self.browser.invalidate(.playlists)
                    self.browser.clearMarks()
                }
            default:
                break
            }
        }
        palette.open(.list(prompt: "Add \(targets.count) item(s) to playlist", items: items), in: view.window)
    }

    private func promptNewPlaylist(with targets: [Entry]) {
        palette.onPromptSubmit = { [weak self] name in
            guard let self, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task {
                let urls = await self.browser.tracks(for: targets)
                _ = try? self.app.playlists.create(named: name, with: self.playlistEntries(urls))
                self.browser.invalidate(.playlists)
                self.browser.clearMarks()
            }
        }
        palette.open(.prompt(prompt: "New playlist name", initial: ""), in: view.window)
    }

    private func playlistEntries(_ urls: [URL]) -> [PlaylistEntry] {
        urls.map { u in
            let m = app.metadata.cached(u.path)
            let title = m.map { [$0.artist, $0.title].compactMap { $0 }.joined(separator: " - ") }
            return PlaylistEntry(url: u, title: title?.isEmpty == false ? title : nil, duration: m.map { Int($0.duration) })
        }
    }

    // MARK: Inline input (filter / find)

    private func beginInput(_ kind: InputKind) {
        input = kind
        switch kind {
        case .filter:
            inputPrompt.stringValue = "filter:"
            inputField.stringValue = browser.filter
        case .find(let forward):
            inputPrompt.stringValue = forward ? "find:" : "find ↑:"
            inputField.stringValue = ""
            findOrigin = browser.cursor
        }
        inputPrompt.isHidden = false
        inputField.isHidden = false
        view.window?.makeFirstResponder(inputField)
        updateStatus()
    }

    private func endInput(commit: Bool) {
        guard let kind = input else { return }
        if !commit {
            switch kind {
            case .filter: browser.setFilter("")
            case .find: browser.setCursor(findOrigin)
            }
        }
        input = nil
        inputPrompt.isHidden = true
        inputField.isHidden = true
        view.window?.makeFirstResponder(currentCol.table)
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let kind = input else { return }
        let q = inputField.stringValue
        switch kind {
        case .filter:
            browser.setFilter(q)
        case .find(let forward):
            browser.setCursor(findOrigin)
            browser.find(q, forward: forward)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === inputField else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            endInput(commit: true)
        case #selector(NSResponder.cancelOperation(_:)):
            endInput(commit: false)
        case #selector(NSResponder.moveDown(_:)):
            browser.moveCursor(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            browser.moveCursor(by: -1)
        default:
            return false
        }
        return true
    }
}

import AppKit
import KveikurCore
import SwiftUI

/// Rename, Move to Trash and Edit Tags. Reachable only from the context menu, never from keys.
@MainActor
final class FileActions {
    private let app: AppModel
    private let browser: BrowserModel
    private let inspector: InspectorModel
    weak var window: NSWindow?
    private var sheet: NSWindow?

    init(app: AppModel, browser: BrowserModel, inspector: InspectorModel) {
        self.app = app
        self.browser = browser
        self.inspector = inspector
    }

    /// Cue tracks and sheet containers are views into an image, not files of their own.
    static func canModify(_ e: Entry) -> Bool {
        guard let u = e.url, !CueTrackRef.isCue(u), !CueFolders.isSheet(u) else { return false }
        return e.kind == .track || e.kind == .folder || e.kind == .playlist
    }

    // MARK: Rename

    func rename(_ e: Entry) {
        guard let url = e.url, let window else { return }
        let alert = NSAlert()
        alert.messageText = e.kind == .folder ? "Rename Folder" : "Rename File"
        if e.kind == .track { alert.informativeText = "Lyrics and cue files with the same name are renamed too." }
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.performRename(url, to: field.stringValue) }
        }
        DispatchQueue.main.async {
            let base = e.kind == .folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    private func performRename(_ url: URL, to name: String) {
        do {
            let moves = try FileOperations.rename(url, to: name)
            guard let dest = moves.first?.1 else { return }
            app.player.remapQueue { FileOperations.remap($0, moves) ?? $0 }
            for p in app.playlists.followMoves(moves) { browser.invalidate(.playlist(p)) }
            app.metadata.forget(moves.map(\.0.path))
            browser.filesChanged(in: [url.deletingLastPathComponent().path], cursorOn: dest.path)
            app.rescan()
        } catch {
            show(error, title: "Couldn't rename “\(url.lastPathComponent)”")
        }
    }

    // MARK: Trash

    func trash(_ entries: [Entry]) {
        let urls = entries.filter(Self.canModify).compactMap(\.url)
        guard !urls.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
                                            : "Move \(urls.count) items to the Trash?"
        var names = urls.prefix(8).map { "• " + $0.lastPathComponent }
        if urls.count > 8 { names.append("…and \(urls.count - 8) more") }
        alert.informativeText = (urls.count > 1 ? names.joined(separator: "\n") + "\n\n" : "")
            + "You can put them back from the Trash in Finder."
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        trash.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.performTrash(urls) }
        }
    }

    private func performTrash(_ urls: [URL]) {
        let r = FileOperations.trash(urls)
        if !r.moved.isEmpty {
            app.player.remapQueue { FileOperations.isInside($0, r.moved) ? nil : $0 }
            app.metadata.forget(r.moved.map(\.path))
            browser.clearMarks()
            browser.filesChanged(in: Array(Set(r.moved.map { $0.deletingLastPathComponent().path })), cursorOn: nil)
            app.rescan()
        }
        if let (u, error) = r.failed.first {
            show(error, title: r.failed.count == 1 ? "Couldn't move “\(u.lastPathComponent)” to the Trash"
                                                   : "\(r.failed.count) items couldn't be moved to the Trash")
        }
    }

    // MARK: Tags

    func editTags(_ entries: [Entry]) {
        let targets = entries.filter { $0.kind != .root && $0.kind != .playlistsRoot }
        Task {
            let urls = await browser.tracks(for: targets)
            var files: [TrackMetadata] = []
            var readOnly: [String] = []
            for u in urls {
                if await Task.detached(operation: { TagWriter.canWrite(u) }).value, let m = await app.metadata.metadata(for: u) {
                    files.append(m)
                } else {
                    readOnly.append(CueTrackRef.isCue(u) ? "\(u.deletingLastPathComponent().lastPathComponent) #\(u.lastPathComponent)" : u.lastPathComponent)
                }
            }
            guard let window else { return }
            guard !files.isEmpty else {
                let a = NSAlert()
                a.messageText = "These tags can't be edited"
                a.informativeText = "Kveikur writes tags to FLAC, MP3 and M4A files. WAV, AIFF and Ogg are read-only for now."
                a.beginSheetModal(for: window) { _ in }
                return
            }
            presentEditor(files, readOnly: readOnly, in: window)
        }
    }

    private func presentEditor(_ files: [TrackMetadata], readOnly: [String], in window: NSWindow) {
        let view = TagEditorView(files: files, readOnly: readOnly, onSave: { [weak self] changes in
            self?.closeSheet()
            self?.write(changes, to: files)
        }, onCancel: { [weak self] in self?.closeSheet() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.inspectorBackground
        sheet = w
        window.beginSheet(w)
    }

    private func closeSheet() {
        guard let s = sheet else { return }
        window?.endSheet(s)
        sheet = nil
    }

    /// Track/disc numbers and totals share one ID3/MP4 field, so a touched half is completed from each file.
    static func edit(_ changes: [TagField: String], for m: TrackMetadata) -> TagEdit {
        var e = TagEdit(changes)
        for (n, t) in [(TagField.track, TagField.trackTotal), (.disc, .discTotal)] where changes[n] != nil || changes[t] != nil {
            if e[n] == nil { e[n] = TagEditorView.value(n, m) }
            if e[t] == nil { e[t] = TagEditorView.value(t, m) }
        }
        return e
    }

    private func write(_ changes: [TagField: String], to files: [TrackMetadata]) {
        guard !changes.isEmpty else { return }
        Task {
            var failed: [(String, Error)] = []
            for m in files {
                do {
                    try await TagWriter.write(Self.edit(changes, for: m), to: m.url)
                } catch {
                    failed.append((m.fileName, error))
                }
                await app.metadata.refresh(m.url)
            }
            app.player.reloadCurrentMetadata()
            inspector.reloadInfo()
            browser.metadataChanged()
            if let (name, error) = failed.first {
                show(error, title: failed.count == 1 ? "Couldn't save tags of “\(name)”" : "\(failed.count) files couldn't be saved")
            }
        }
    }

    private func show(_ error: Error, title: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = error.localizedDescription
        if let window { a.beginSheetModal(for: window) { _ in } } else { a.runModal() }
    }
}

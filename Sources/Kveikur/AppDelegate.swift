import AppKit
import KveikurCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var main: MainViewController!
    private var settingsWindow: NSWindow?
    private var equalizerWindow: NSWindow?
    private var duplicatesWindow: NSWindow?
    private var statisticsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        model = AppModel()
        main = MainViewController(app: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Kveikur"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = true
        window.contentViewController = main
        window.minSize = NSSize(width: 900, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("KveikurMain") { window.center() }
        window.setFrameAutosaveName("KveikurMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = buildMenu()
        NSApp.activate()
        if ProcessInfo.processInfo.environment["KVEIKUR_SNAPSHOT"] == nil { model.updater.checkOnLaunch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        main.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(app: model, player: model.player))
            let w = NSWindow(contentViewController: host)
            w.title = "Kveikur Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showEqualizer() {
        if equalizerWindow == nil {
            let host = NSHostingController(rootView: EqualizerView(player: model.player))
            let w = NSWindow(contentViewController: host)
            w.title = "Equalizer"
            w.styleMask = [.titled, .closable]
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Theme.inspectorBackground
            w.isReleasedWhenClosed = false
            w.center()
            equalizerWindow = w
        }
        equalizerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkForUpdates() {
        model.updater.check(interactive: true)
    }

    @objc func showDuplicates() {
        if duplicatesWindow == nil {
            let m = DuplicatesModel(app: model)
            m.onShow = { [weak self] u in self?.showInBrowser(u) }
            let w = auxWindow(NSHostingController(rootView: DuplicatesView(model: m)), title: "Duplicates", autosave: "KveikurDuplicates")
            m.onTrash = { [weak self, weak w] urls, done in
                guard let self, let w else { return }
                self.main.trash(urls: urls, from: w, then: done)
            }
            duplicatesWindow = w
        }
        duplicatesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showStatistics() {
        if statisticsWindow == nil {
            let m = StatisticsModel(app: model)
            m.onShow = { [weak self] u in self?.showInBrowser(u) }
            statisticsWindow = auxWindow(NSHostingController(rootView: StatisticsView(model: m)), title: "Listening Statistics",
                                         autosave: "KveikurStatistics")
        }
        statisticsWindow?.makeKeyAndOrderFront(nil)
    }

    private func auxWindow(_ host: NSViewController, title: String, autosave: String) -> NSWindow {
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.inspectorBackground
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
        return w
    }

    private func showInBrowser(_ url: URL) {
        window.makeKeyAndOrderFront(nil)
        main.show(url)
    }

    @objc private func command(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Command(rawValue: raw) else { return }
        window.makeKeyAndOrderFront(nil)
        main.perform(c)
    }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kveikur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kveikur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Kveikur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(submenu(appMenu, title: "Kveikur"))

        let file = NSMenu(title: "File")
        add(file, "Add Music Folder…", .addFolder)
        add(file, "Rescan Library", .rescan)
        add(file, "Find Duplicates…", .duplicates)
        add(file, "Listening Statistics", .statistics)
        file.addItem(.separator())
        add(file, "New Playlist from Selection…", .newPlaylist)
        add(file, "Add to Playlist…", .addToPlaylist)
        add(file, "Remove from Playlist", .removeFromPlaylist)
        file.addItem(.separator())
        add(file, "Reveal in Finder", .revealInFinder)
        add(file, "Copy Path", .copyPath)
        bar.addItem(commandMenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(submenu(edit, title: "Edit"))

        let select = NSMenu(title: "Select")
        add(select, "Toggle Mark", .toggleMark)
        add(select, "Visual Mode", .toggleVisual)
        add(select, "Select All in Folder", .selectAll)
        add(select, "Clear Selection", .clearMarks)
        select.addItem(.separator())
        add(select, "Filter Folder…", .filter)
        add(select, "Find…", .find)
        add(select, "Find Next", .findNext)
        add(select, "Find Previous", .findPrev)
        bar.addItem(commandMenu(select))

        let go = NSMenu(title: "Go")
        add(go, "Jump to Folder…", .jumpFolder)
        add(go, "Search Tracks…", .searchTracks)
        add(go, "Command Palette…", .palette)
        go.addItem(.separator())
        add(go, "Back", .back)
        add(go, "Forward", .forward)
        add(go, "Enclosing Folder", .parent)
        add(go, "Open", .open)
        go.addItem(.separator())
        add(go, "Top", .top)
        add(go, "Bottom", .bottom)
        go.addItem(.separator())
        add(go, "Library", .home)
        add(go, "Playlists", .playlists)
        add(go, "Reveal Playing Track", .revealPlaying)
        bar.addItem(commandMenu(go))

        let playback = NSMenu(title: "Playback")
        add(playback, "Play / Pause", .playPause)
        add(playback, "Next Track", .nextTrack)
        add(playback, "Previous Track", .prevTrack)
        add(playback, "Seek Forward", .seekForward)
        add(playback, "Seek Backward", .seekBackward)
        playback.addItem(.separator())
        add(playback, "Play Selection", .play)
        add(playback, "Play Folder", .playAll)
        add(playback, "Add to Queue", .enqueue)
        add(playback, "Play Next", .playNext)
        playback.addItem(.separator())
        add(playback, "Volume Up", .volumeUp)
        add(playback, "Volume Down", .volumeDown)
        playback.addItem(.separator())
        add(playback, "Show Queue", .showQueue)
        add(playback, "Toggle Shuffle", .toggleShuffle)
        add(playback, "Cycle Repeat", .cycleRepeat)
        playback.addItem(.separator())
        add(playback, "Equalizer…", .equalizer)
        add(playback, "Equalizer On / Off", .toggleEQ)
        add(playback, "Cycle ReplayGain", .cycleReplayGain)
        playback.addItem(.separator())
        let sleep = NSMenu(title: "Sleep Timer")
        sleep.delegate = self
        playback.addItem(submenu(sleep, title: "Sleep Timer"))
        bar.addItem(commandMenu(playback))

        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Toggle Inspector", .togglePreview)
        add(viewMenu, "Next Inspector Tab", .cycleInspectorTab)
        add(viewMenu, "Previous Inspector Tab", .prevInspectorTab)
        viewMenu.addItem(.separator())
        add(viewMenu, "Info", .tabInfo)
        add(viewMenu, "Lyrics", .tabLyrics)
        add(viewMenu, "Queue", .tabQueue)
        add(viewMenu, "Analysis", .tabAnalysis)
        add(viewMenu, "Output", .tabOutput)
        viewMenu.addItem(.separator())
        add(viewMenu, "Inspector Follows Cursor", .pinNowPlaying)
        add(viewMenu, "Find Lyrics Online", .fetchLyrics)
        add(viewMenu, "Full-Screen Lyrics", .karaoke)
        bar.addItem(commandMenu(viewMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        bar.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu
        return bar
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    /// Menus of app commands: shortcuts are shown but never matched by the menu, since the key router owns those keys
    /// (most are bare letters that must keep working as text in search fields).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Sleep Timer" else { return }
        let player = model.player
        menu.removeAllItems()
        func item(_ title: String, _ tag: Int, on: Bool) {
            let i = menu.addItem(withTitle: title, action: #selector(sleepTimer(_:)), keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.state = on ? .on : .off
        }
        item("Off", 0, on: player.sleep == .off)
        if let left = player.sleepRemaining {
            item("\(Int((left / 60).rounded(.up))) min left", -2, on: true)
        }
        menu.addItem(.separator())
        for m in PlayerController.sleepChoices { item("\(m) min", m, on: false) }
        item("End of Track", -1, on: player.sleep == .endOfTrack)
    }

    @objc private func sleepTimer(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: model.player.setSleep(minutes: nil)
        case -1: model.player.setSleepEndOfTrack()
        case -2: break
        default: model.player.setSleep(minutes: sender.tag)
        }
    }

    private func commandMenu(_ menu: NSMenu) -> NSMenuItem {
        menu.delegate = self
        return submenu(menu, title: menu.title)
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    private func add(_ menu: NSMenu, _ title: String, _ c: Command) {
        let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = c.rawValue
        switch Keymap.menuShortcut(for: c) {
        case .key(let k, let mods)?:
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = mods
        case .sequence(let seq)?:
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "\t" + seq, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
            item.attributedTitle = text
        case nil:
            break
        }
        menu.addItem(item)
    }
}

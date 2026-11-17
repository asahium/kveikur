import AppKit
import Carbon.HIToolbox

enum Command: String, CaseIterable {
    case down, up, top, bottom, halfDown, halfUp, pageDown, pageUp, extendDown, extendUp
    case parent, open, back, forward, home, playlists, revealPlaying
    case find, findBack, findNext, findPrev, filter, jumpFolder, searchTracks, palette
    case toggleMark, toggleVisual, clearMarks, selectAll
    case play, playAll, enqueue, playNext, playPause, nextTrack, prevTrack
    case seekForward, seekBackward, volumeUp, volumeDown, toggleShuffle, cycleRepeat
    case cycleInspectorTab, prevInspectorTab, tabInfo, tabLyrics, tabQueue, tabAnalysis, tabOutput, pinNowPlaying, fetchLyrics, revealInFinder, copyPath, showQueue
    case addToPlaylist, newPlaylist, removeFromPlaylist, moveEntryDown, moveEntryUp
    case rescan, togglePreview, addFolder, settings, escape
    case equalizer, toggleEQ, cycleReplayGain, karaoke

    var title: String {
        switch self {
        case .down: return "Move down"
        case .up: return "Move up"
        case .top: return "Go to top"
        case .bottom: return "Go to bottom"
        case .halfDown: return "Half page down"
        case .halfUp: return "Half page up"
        case .pageDown: return "Page down"
        case .pageUp: return "Page up"
        case .extendDown: return "Extend selection down"
        case .extendUp: return "Extend selection up"
        case .parent: return "Go to parent folder"
        case .open: return "Open folder / play track"
        case .back: return "Back in history"
        case .forward: return "Forward in history"
        case .home: return "Go to library root"
        case .playlists: return "Go to playlists"
        case .revealPlaying: return "Reveal playing track"
        case .find: return "Find in folder"
        case .findBack: return "Find backwards"
        case .findNext: return "Next match"
        case .findPrev: return "Previous match"
        case .filter: return "Filter folder"
        case .jumpFolder: return "Jump to folder (fuzzy)"
        case .searchTracks: return "Search library tracks (fuzzy)"
        case .palette: return "Command palette"
        case .toggleMark: return "Mark / unmark"
        case .toggleVisual: return "Visual selection"
        case .clearMarks: return "Clear selection"
        case .selectAll: return "Select all"
        case .play: return "Play selection (folders recursively)"
        case .playAll: return "Play whole folder recursively"
        case .enqueue: return "Add to queue"
        case .playNext: return "Play next"
        case .playPause: return "Play / pause"
        case .nextTrack: return "Next track"
        case .prevTrack: return "Previous track"
        case .seekForward: return "Seek forward 5 s"
        case .seekBackward: return "Seek back 5 s"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .toggleShuffle: return "Toggle shuffle"
        case .cycleRepeat: return "Cycle repeat mode"
        case .cycleInspectorTab: return "Next inspector tab"
        case .prevInspectorTab: return "Previous inspector tab"
        case .tabInfo: return "Inspector: Info"
        case .tabLyrics: return "Inspector: Lyrics"
        case .tabQueue: return "Inspector: Queue"
        case .tabAnalysis: return "Inspector: Analysis"
        case .tabOutput: return "Inspector: Output"
        case .pinNowPlaying: return "Inspector: follow cursor / now playing"
        case .fetchLyrics: return "Find lyrics online"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy path"
        case .showQueue: return "Show queue"
        case .addToPlaylist: return "Add to playlist"
        case .newPlaylist: return "New playlist from selection"
        case .removeFromPlaylist: return "Remove from playlist"
        case .moveEntryDown: return "Move playlist entry down"
        case .moveEntryUp: return "Move playlist entry up"
        case .rescan: return "Rescan library"
        case .togglePreview: return "Toggle inspector panel"
        case .addFolder: return "Add music folder"
        case .settings: return "Settings"
        case .escape: return "Cancel / clear"
        case .equalizer: return "Equalizer window"
        case .toggleEQ: return "Equalizer on / off"
        case .cycleReplayGain: return "Cycle ReplayGain (off / track / album)"
        case .karaoke: return "Full-screen lyrics"
        }
    }
}

enum Keymap {
    static let bindings: [(String, Command)] = [
        ("j", .down), ("<Down>", .down), ("k", .up), ("<Up>", .up),
        ("gg", .top), ("<Home>", .top), ("G", .bottom), ("<End>", .bottom),
        ("<C-d>", .halfDown), ("<C-u>", .halfUp),
        ("<PageDown>", .pageDown), ("<C-f>", .pageDown), ("<PageUp>", .pageUp), ("<C-b>", .pageUp),
        ("<S-Down>", .extendDown), ("J", .moveEntryDown), ("<S-Up>", .extendUp), ("K", .moveEntryUp),
        ("h", .parent), ("<Left>", .parent), ("<D-Up>", .parent), ("<Backspace>", .parent),
        ("l", .open), ("<Right>", .open), ("<Enter>", .open), ("<D-Down>", .open),
        ("H", .back), ("L", .forward), ("<D-[>", .back), ("<D-]>", .forward),
        ("gh", .home), ("gp", .playlists), ("gr", .revealPlaying),
        ("/", .find), ("?", .findBack), ("n", .findNext), ("N", .findPrev), ("f", .filter),
        ("z", .jumpFolder), ("s", .searchTracks), (":", .palette), ("~", .palette), ("<F1>", .palette),
        ("<D-f>", .filter), ("<D-k>", .palette),
        ("<Space>", .toggleMark), ("v", .toggleVisual), ("V", .clearMarks), ("<C-a>", .selectAll), ("<D-a>", .selectAll),
        ("p", .play), ("P", .playAll), ("a", .enqueue), ("A", .playNext),
        ("c", .playPause), ("<C-Space>", .playPause), ("]", .nextTrack), ("[", .prevTrack),
        (">", .seekForward), (".", .seekForward), ("<", .seekBackward), (",", .seekBackward),
        ("+", .volumeUp), ("=", .volumeUp), ("-", .volumeDown), ("S", .toggleShuffle), ("r", .cycleRepeat),
        ("<Tab>", .cycleInspectorTab), ("<S-Tab>", .prevInspectorTab),
        ("1", .tabInfo), ("2", .tabLyrics), ("3", .tabQueue), ("4", .tabAnalysis), ("5", .tabOutput), ("i", .pinNowPlaying), ("gl", .fetchLyrics),
        ("o", .revealInFinder), ("y", .copyPath), ("t", .showQueue),
        ("ga", .addToPlaylist), ("gn", .newPlaylist), ("dd", .removeFromPlaylist), ("<Delete>", .removeFromPlaylist),
        ("R", .rescan), ("<D-0>", .togglePreview), ("<D-o>", .addFolder), ("<Esc>", .escape),
        ("<D-e>", .equalizer), ("E", .toggleEQ), ("gR", .cycleReplayGain), ("<D-l>", .karaoke), ("gk", .karaoke),
    ]

    static func keys(for c: Command) -> [String] {
        bindings.filter { $0.1 == c }.map(\.0)
    }

    enum MenuShortcut {
        case key(String, NSEvent.ModifierFlags)
        /// Multi-key sequence like "gh", shown as text because menus can't express it.
        case sequence(String)
    }

    /// Shortcut shown next to a menu item: a ⌘ binding if there is one (mac convention), else the first single key.
    static func menuShortcut(for c: Command) -> MenuShortcut? {
        let parsed = keys(for: c).map { ($0, menuKey($0)) }.filter { _, k in
            guard let k, k.1 == .command else { return true }
            return !standardCommandKeys.contains(k.0)
        }
        if let k = parsed.first(where: { $0.1?.1.contains(.command) == true })?.1 { return .key(k.0, k.1) }
        if let k = parsed.first(where: { $0.1 != nil })?.1 { return .key(k.0, k.1) }
        return parsed.first.map { .sequence($0.0.map(String.init).joined(separator: " ")) }
    }

    /// ⌘ keys owned by the standard App/Edit/Window menu items.
    private static let standardCommandKeys: Set<String> = ["a", "c", "v", "x", "z", "q", "w", "h", "m", ","]

    private static let menuSpecials: [String: String] = [
        "Enter": "\r", "Esc": "\u{1b}", "Tab": "\t", "Space": " ", "Backspace": "\u{8}",
        "Delete": String(Character(UnicodeScalar(NSDeleteFunctionKey)!)),
        "Up": String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "Down": String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "Left": String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "Right": String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "Home": String(Character(UnicodeScalar(NSHomeFunctionKey)!)),
        "End": String(Character(UnicodeScalar(NSEndFunctionKey)!)),
        "PageUp": String(Character(UnicodeScalar(NSPageUpFunctionKey)!)),
        "PageDown": String(Character(UnicodeScalar(NSPageDownFunctionKey)!)),
        "F1": String(Character(UnicodeScalar(NSF1FunctionKey)!)),
    ]

    /// Token -> NSMenuItem key equivalent and modifiers; nil for multi-key sequences.
    private static func menuKey(_ token: String) -> (String, NSEvent.ModifierFlags)? {
        guard token.hasPrefix("<"), token.hasSuffix(">"), token.count > 2 else {
            return token.count == 1 ? (token, []) : nil
        }
        var body = String(token.dropFirst().dropLast())
        var mods: NSEvent.ModifierFlags = []
        let prefixes: [(String, NSEvent.ModifierFlags)] = [("C-", .control), ("D-", .command), ("A-", .option), ("S-", .shift)]
        var matched = true
        while matched {
            matched = false
            for (p, m) in prefixes where body.hasPrefix(p) && body.count > p.count {
                mods.insert(m)
                body.removeFirst(p.count)
                matched = true
            }
        }
        if let s = menuSpecials[body] { return (s, mods) }
        return body.count == 1 ? (body, mods) : nil
    }

    private static let table: [String: Command] = Dictionary(bindings, uniquingKeysWith: { a, _ in a })
    private static let prefixes: Set<String> = Set(bindings.flatMap { k, _ -> [String] in
        guard !k.hasPrefix("<"), k.count > 1 else { return [] }
        return (1..<k.count).map { String(k.prefix($0)) }
    })

    static func command(_ keys: String) -> Command? { table[keys] }
    static func isPrefix(_ keys: String) -> Bool { prefixes.contains(keys) }

    /// Event -> token like "j", "G", "<C-d>", "<S-Up>", "<Enter>". Letters come from the ASCII layout,
    /// so vim keys keep working on Cyrillic and other layouts.
    static func token(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ctrl = flags.contains(.control)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let shift = flags.contains(.shift)
        var mods = ""
        if ctrl { mods += "C-" }
        if cmd { mods += "D-" }
        if opt { mods += "A-" }

        let special: String?
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: special = "Enter"
        case kVK_Escape: special = "Esc"
        case kVK_Tab: special = "Tab"
        case kVK_Space: special = "Space"
        case kVK_Delete: special = "Backspace"
        case kVK_ForwardDelete: special = "Delete"
        case kVK_UpArrow: special = "Up"
        case kVK_DownArrow: special = "Down"
        case kVK_LeftArrow: special = "Left"
        case kVK_RightArrow: special = "Right"
        case kVK_Home: special = "Home"
        case kVK_End: special = "End"
        case kVK_PageUp: special = "PageUp"
        case kVK_PageDown: special = "PageDown"
        case kVK_F1: special = "F1"
        default: special = nil
        }
        if let s = special {
            return "<\(mods)\(shift ? "S-" : "")\(s)>"
        }
        guard var ch = event.charactersIgnoringModifiers, !ch.isEmpty else { return nil }
        if let ascii = KeyTranslator.ascii(keyCode: event.keyCode, shift: shift),
           !(ch.unicodeScalars.first.map { $0.isASCII } ?? false) || ctrl || opt {
            ch = ascii
        }
        if ctrl || opt { ch = ch.lowercased() }
        return mods.isEmpty ? ch : "<\(mods)\(ch)>"
    }
}

/// Maps a key code to the character it produces on the current ASCII-capable layout.
enum KeyTranslator {
    private static var cache: [Int: String] = [:]

    static func ascii(keyCode: UInt16, shift: Bool) -> String? {
        let key = Int(keyCode) * 2 + (shift ? 1 : 0)
        if let c = cache[key] { return c }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let mods: UInt32 = shift ? UInt32(shiftKey >> 8) : 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len)
        cache[key] = s
        return s
    }
}

/// Collects multi-key sequences such as "gg" or "dd".
final class KeyRouter {
    private var pending = ""
    private var pendingAt = Date.distantPast

    var pendingKeys: String { pending }

    enum Result {
        case command(Command)
        case consumed
        case passThrough
    }

    func handle(_ token: String) -> Result {
        if Date().timeIntervalSince(pendingAt) > 1.2 { pending = "" }
        let seq = pending + token
        if let c = Keymap.command(seq) {
            pending = ""
            return .command(c)
        }
        if Keymap.isPrefix(seq) {
            pending = seq
            pendingAt = Date()
            return .consumed
        }
        let hadPending = !pending.isEmpty
        pending = ""
        if hadPending, let c = Keymap.command(token) { return .command(c) }
        return hadPending ? .consumed : .passThrough
    }

    func reset() { pending = "" }
}

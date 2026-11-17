import AppKit
import KveikurCore

/// Looks for a newer GitHub release once a day (or on demand) and offers to download the DMG.
@MainActor
final class Updater: ObservableObject {
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "updateCheckAutomatic") } }
    @Published var token: String { didSet { defaults.set(token, forKey: "githubToken") } }
    @Published private(set) var status = ""
    @Published private(set) var checking = false

    private let defaults = UserDefaults.standard
    private var skipped: String? {
        get { defaults.string(forKey: "updateSkippedVersion") }
        set { defaults.set(newValue, forKey: "updateSkippedVersion") }
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    init() {
        automatic = defaults.object(forKey: "updateCheckAutomatic") as? Bool ?? true
        token = defaults.string(forKey: "githubToken") ?? ""
    }

    func checkOnLaunch() {
        guard automatic else { return }
        let last = defaults.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(interactive: false)
    }

    func check(interactive: Bool) {
        guard !checking else { return }
        checking = true
        status = "Checking…"
        Task {
            defer { checking = false }
            do {
                let release = try await ReleaseCheck.latest(token: token.trimmingCharacters(in: .whitespaces))
                defaults.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
                let current = Self.currentVersion
                guard let r = release, ReleaseCheck.isNewer(r.version, than: current) else {
                    status = "Kveikur \(current) is the latest version"
                    if interactive { inform(status, nil) }
                    return
                }
                status = "Kveikur \(r.version) is available"
                if interactive || skipped != r.version { offer(r, current: current, interactive: interactive) }
            } catch {
                status = error.localizedDescription
                if interactive { inform("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private func offer(_ r: Release, current: String, interactive: Bool) {
        let a = NSAlert()
        a.messageText = "Kveikur \(r.version) is available"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "You have \(current)." + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if !interactive { a.addButton(withTitle: "Skip This Version") }
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.page)
        case .alertThirdButtonReturn: skipped = r.version
        default: break
        }
    }

    private func inform(_ title: String, _ text: String?) {
        let a = NSAlert()
        a.messageText = title
        if let text { a.informativeText = text }
        a.runModal()
    }
}

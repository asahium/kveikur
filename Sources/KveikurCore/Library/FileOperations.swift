import Foundation

public enum FileOperationError: LocalizedError {
    case invalidName
    case exists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "The name can't be empty or contain “/” or “:”."
        case .exists(let n): return "“\(n)” already exists in this folder."
        }
    }
}

public enum FileOperations {
    static let sidecarExtensions = ["lrc", "LRC", "txt", "cue"]

    /// Renames a file or folder in place. Lyrics/cue sidecars of a track follow it.
    /// Returns old → new URL pairs, the item itself first.
    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> [(URL, URL)] {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            throw FileOperationError.invalidName
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        guard dest.lastPathComponent != url.lastPathComponent else { return [] }
        let fm = FileManager.default
        let caseOnly = dest.path.lowercased() == url.path.lowercased()
        if !caseOnly, fm.fileExists(atPath: dest.path) { throw FileOperationError.exists(name) }
        try fm.moveItem(at: url, to: dest)
        var moved = [(url, dest)]

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir), !isDir.boolValue else { return moved }
        let oldBase = url.deletingPathExtension()
        let newBase = dest.deletingPathExtension()
        guard oldBase.lastPathComponent != newBase.lastPathComponent else { return moved }
        for ext in sidecarExtensions {
            let from = oldBase.appendingPathExtension(ext)
            let to = newBase.appendingPathExtension(ext)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            if (try? fm.moveItem(at: from, to: to)) != nil { moved.append((from, to)) }
        }
        return moved
    }

    /// Moves items to the Trash; returns the ones that were moved.
    public static func trash(_ urls: [URL]) -> (moved: [URL], failed: [(URL, Error)]) {
        var moved: [URL] = []
        var failed: [(URL, Error)] = []
        for u in urls {
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                moved.append(u)
            } catch {
                failed.append((u, error))
            }
        }
        return (moved, failed)
    }

    /// Maps `url` through renames of files or of any containing folder; nil when it is not affected.
    public static func remap(_ url: URL, _ moves: [(URL, URL)]) -> URL? {
        let p = url.path
        for (from, to) in moves {
            if p == from.path { return to }
            if p.hasPrefix(from.path + "/") { return URL(fileURLWithPath: to.path + p.dropFirst(from.path.count)) }
        }
        return nil
    }

    /// True when `url` is one of `items` or lies inside one of them.
    public static func isInside(_ url: URL, _ items: [URL]) -> Bool {
        let p = url.path
        return items.contains { p == $0.path || p.hasPrefix($0.path + "/") }
    }
}

import Foundation

public struct FileStamp: Sendable {
    public let url: URL
    public let mtime: Double
    public let size: Int64

    public init(url: URL, mtime: Double, size: Int64) {
        self.url = url
        self.mtime = mtime
        self.size = size
    }
}

/// Tag lookup for the UI: memory cache, then the index, then the file itself (written back to the index).
public final class MetadataStore: @unchecked Sendable {
    private final class Box {
        let value: TrackMetadata
        init(_ v: TrackMetadata) { value = v }
    }

    private let library: LibraryStore
    private let memory = NSCache<NSString, Box>()

    public init(library: LibraryStore) {
        self.library = library
        memory.countLimit = 4000
    }

    public func cached(_ path: String) -> TrackMetadata? {
        memory.object(forKey: path.pathKey as NSString)?.value
    }

    private func remember(_ m: TrackMetadata) {
        memory.setObject(Box(m), forKey: m.path.pathKey as NSString)
    }

    /// Resolves tags for files of one folder; `update` is called on the main actor in batches.
    public func load(folder: String, files: [FileStamp], update: @escaping @MainActor ([TrackMetadata]) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [self] in
            let indexed = library.tracks(inFolder: folder)
            var ready: [TrackMetadata] = []
            var missing: [URL] = []
            for f in files {
                if let m = cached(f.url.path), m.mtime == f.mtime, m.size == f.size { continue }
                if let m = indexed[f.url.path], m.mtime == f.mtime, m.size == f.size {
                    remember(m)
                    ready.append(m)
                } else {
                    missing.append(f.url)
                }
            }
            if !ready.isEmpty {
                let r = ready
                await MainActor.run { update(r) }
            }
            var fresh: [TrackMetadata] = []
            for u in missing {
                if Task.isCancelled { break }
                guard let m = await MetadataReader.read(u) else { continue }
                remember(m)
                fresh.append(m)
                if fresh.count % 24 == 0 {
                    let r = Array(fresh.suffix(24))
                    await MainActor.run { update(r) }
                }
            }
            library.upsert(fresh)
            let tail = Array(fresh.suffix(fresh.count % 24))
            if !tail.isEmpty { await MainActor.run { update(tail) } }
        }
    }

    public func metadata(for url: URL) async -> TrackMetadata? {
        let path = url.path
        if let m = cached(path) { return m }
        if let m = library.track(path: path) {
            remember(m)
            return m
        }
        guard let m = await MetadataReader.read(url) else { return nil }
        remember(m)
        library.upsert([m])
        return m
    }
}

import Foundation
#if os(macOS)
import CoreServices
#endif

public struct ScanProgress: Sendable {
    public var running: Bool
    public var processed: Int
    public var total: Int
}

/// Incremental scanner: walks roots, reads tags only for new or changed files.
public final class LibraryScanner: @unchecked Sendable {
    private let store: LibraryStore
    private var task: Task<Void, Never>?
    public var onProgress: (@MainActor (ScanProgress) -> Void)?
    public var onFinished: (@MainActor () -> Void)?

    public init(store: LibraryStore) {
        self.store = store
    }

    public func scan(roots: [URL]) {
        task?.cancel()
        let store = store
        let progress = onProgress
        let finished = onFinished
        task = Task.detached(priority: .utility) {
            for root in roots {
                if Task.isCancelled { return }
                await Self.scanRoot(root, store: store, progress: progress)
            }
            await MainActor.run {
                progress?(ScanProgress(running: false, processed: 0, total: 0))
                finished?()
            }
        }
    }

    private static func scanRoot(_ root: URL, store: LibraryStore, progress: (@MainActor (ScanProgress) -> Void)?) async {
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var existing = store.stamps(underRoot: rootPath)
        var changed: [URL] = []
        var folders = Set<String>()

        while let url = walker.nextObject() as? URL {
            if Task.isCancelled { return }
            guard AudioFiles.isAudio(url), let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            let path = url.standardizedFileURL.path
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count >= rootPath.count, folders.insert(dir).inserted {
                dir = (dir as NSString).deletingLastPathComponent
            }
            let mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = Int64(v.fileSize ?? 0)
            if let old = existing.removeValue(forKey: path), old.0 == mtime, old.1 == size { continue }
            changed.append(URL(fileURLWithPath: path))
        }
        store.delete(paths: Array(existing.keys))
        store.replaceFolders(root: rootPath, folders: folders.sorted())

        let total = changed.count
        guard total > 0 else { return }
        var processed = 0
        var batch: [TrackMetadata] = []
        await withTaskGroup(of: TrackMetadata?.self) { group in
            var iterator = changed.makeIterator()
            for _ in 0..<6 {
                guard let u = iterator.next() else { break }
                group.addTask { await MetadataReader.read(u) }
            }
            for await result in group {
                if Task.isCancelled { group.cancelAll(); break }
                processed += 1
                if let m = result { batch.append(m) }
                if batch.count >= 200 {
                    store.upsert(batch)
                    batch.removeAll(keepingCapacity: true)
                    let p = ScanProgress(running: true, processed: processed, total: total)
                    await MainActor.run { progress?(p) }
                }
                if let u = iterator.next() { group.addTask { await MetadataReader.read(u) } }
            }
        }
        store.upsert(batch)
    }
}

#if os(macOS)
/// FSEvents on library roots, debounced; reports the changed directories.
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void
    private var pendingPaths = Set<String>()
    private var debounce: DispatchWorkItem?

    public init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    public func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.received(Array(arr.prefix(count)))
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
            FSEventStreamStart(s)
        }
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func received(_ paths: [String]) {
        pendingPaths.formUnion(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let p = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            self.handler(p)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
#else
/// iOS has no FSEvents; folders are rescanned on demand instead.
public final class FolderWatcher {
    public init(handler: @escaping ([String]) -> Void) {}
    public func watch(_ paths: [String]) {}
    public func stop() {}
}
#endif

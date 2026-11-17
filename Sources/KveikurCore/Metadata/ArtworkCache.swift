import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lazily extracts and downsizes artwork; thumbnails persist on disk, a few stay in memory.
public final class ArtworkCache: @unchecked Sendable {
    public static let shared = ArtworkCache()

    private let memory = NSCache<NSString, CGImage>()
    private let missesLock = NSLock()
    private var misses = Set<String>()
    private let dir: URL

    private static let folderNames = ["cover", "folder", "front", "album", "albumart", "artwork"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]

    init() {
        memory.countLimit = 96
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("Kveikur/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func image(forTrack url: URL, maxPixel: Int = 600) async -> CGImage? {
        let key = cacheKey(url, maxPixel)
        if let img = cached(key) { return img }
        if isMiss(key) { return nil }
        var data = await MetadataReader.embeddedArtwork(url)
        if data == nil { data = folderImageData(url.deletingLastPathComponent()) }
        return store(data, key: key, maxPixel: maxPixel)
    }

    public func image(forFolder url: URL, maxPixel: Int = 600) async -> CGImage? {
        let key = cacheKey(url, maxPixel)
        if let img = cached(key) { return img }
        if isMiss(key) { return nil }
        var data = folderImageData(url)
        if data == nil, let first = firstTrack(in: url) { data = await MetadataReader.embeddedArtwork(first) }
        return store(data, key: key, maxPixel: maxPixel)
    }

    // MARK: Internals

    private func cacheKey(_ url: URL, _ size: Int) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(mtime)|\(size)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func cached(_ key: String) -> CGImage? {
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent(key + ".jpg")
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    private func isMiss(_ key: String) -> Bool {
        missesLock.lock()
        defer { missesLock.unlock() }
        return misses.contains(key)
    }

    private func store(_ data: Data?, key: String, maxPixel: Int) -> CGImage? {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            missesLock.lock()
            misses.insert(key)
            missesLock.unlock()
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        memory.setObject(thumb, forKey: key as NSString)
        let file = dir.appendingPathComponent(key + ".jpg")
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return thumb
    }

    private func folderImageData(_ folder: URL) -> Data? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let images = names.filter { Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        let preferred = images.first { name in
            let base = (name as NSString).deletingPathExtension.lowercased()
            return Self.folderNames.contains(base)
        } ?? images.sorted().first!
        return try? Data(contentsOf: folder.appendingPathComponent(preferred))
    }

    private func firstTrack(in folder: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appendingPathComponent($0) }
            .first(where: AudioFiles.isAudio)
    }
}

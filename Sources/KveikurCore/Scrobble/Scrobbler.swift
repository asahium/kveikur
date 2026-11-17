import CryptoKit
import Foundation

public struct ScrobbleTrack: Codable, Equatable, Sendable {
    public var artist: String
    public var title: String
    public var album: String?
    public var albumArtist: String?
    public var duration: TimeInterval
    public var trackNumber: Int?
    /// Unix time the track started playing.
    public var timestamp: Int

    public init(artist: String, title: String, album: String? = nil, albumArtist: String? = nil,
                duration: TimeInterval, trackNumber: Int? = nil, timestamp: Int) {
        self.artist = artist
        self.title = title
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
        self.timestamp = timestamp
    }

    public init?(_ m: TrackMetadata, startedAt date: Date) {
        guard let artist = m.artist ?? m.albumArtist, !artist.isEmpty, let title = m.title, !title.isEmpty else { return nil }
        self.init(artist: artist, title: title, album: m.album, albumArtist: m.albumArtist,
                  duration: m.duration, trackNumber: m.trackNumber, timestamp: Int(date.timeIntervalSince1970))
    }
}

public enum ScrobbleRules {
    /// Listening time after which a play counts: half the track or 4 minutes; tracks of 30 s or less never count.
    public static func threshold(duration: TimeInterval) -> TimeInterval? {
        duration > 30 ? min(duration / 2, 240) : nil
    }
}

public enum ScrobbleError: Error, LocalizedError {
    case http(Int, String)
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .service(let m): return m
        }
    }

    /// Auth and malformed-request errors are not worth retrying.
    public var isPermanent: Bool {
        if case .http(let code, _) = self { return code == 400 || code == 401 || code == 403 }
        return false
    }
}

public protocol ScrobbleService: Sendable {
    var id: String { get }
    func nowPlaying(_ track: ScrobbleTrack) async throws
    func scrobble(_ tracks: [ScrobbleTrack]) async throws
}

// MARK: Last.fm

public struct LastFMService: ScrobbleService {
    public let id = "lastfm"
    public let apiKey: String
    public let secret: String
    public let sessionKey: String

    public init(apiKey: String, secret: String, sessionKey: String) {
        self.apiKey = apiKey
        self.secret = secret
        self.sessionKey = sessionKey
    }

    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// api_sig: md5 of the sorted key/value pairs (without format) followed by the secret.
    static func signature(_ params: [String: String], secret: String) -> String {
        let base = params.filter { $0.key != "format" }.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { k, v in
            (k.addingPercentEncoding(withAllowedCharacters: unreserved) ?? k) + "=" + (v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v)
        }.joined(separator: "&")
    }

    static func call(_ method: String, _ params: [String: String], apiKey: String, secret: String,
                     post: Bool) async throws -> [String: Any] {
        var p = params
        p["method"] = method
        p["api_key"] = apiKey
        p["api_sig"] = signature(p, secret: secret)
        p["format"] = "json"
        let query = formEncode(p)
        var req: URLRequest
        if post {
            req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(query.utf8)
        } else {
            req = URLRequest(url: URL(string: endpoint.absoluteString + "?" + query)!)
        }
        req.setValue("Kveikur/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let err = json["error"] as? Int {
            let msg = json["message"] as? String ?? "error \(err)"
            // 9: invalid session, 4/14: auth — permanent; 11/16: service offline — retry.
            throw [4, 9, 10, 13, 14, 26].contains(err) ? ScrobbleError.http(403, msg) : ScrobbleError.service(msg)
        }
        guard (200..<300).contains(code) else { throw ScrobbleError.http(code, String(decoding: data, as: UTF8.self)) }
        return json
    }

    public static func requestToken(apiKey: String, secret: String) async throws -> String {
        let r = try await call("auth.getToken", [:], apiKey: apiKey, secret: secret, post: false)
        guard let t = r["token"] as? String else { throw ScrobbleError.service("No token in response") }
        return t
    }

    public static func authURL(apiKey: String, token: String) -> URL {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
    }

    /// After the user approved `token` in the browser: (user name, session key).
    public static func session(apiKey: String, secret: String, token: String) async throws -> (String, String) {
        let r = try await call("auth.getSession", ["token": token], apiKey: apiKey, secret: secret, post: false)
        guard let s = r["session"] as? [String: Any], let name = s["name"] as? String, let key = s["key"] as? String else {
            throw ScrobbleError.service("Not authorized yet")
        }
        return (name, key)
    }

    static func fields(_ t: ScrobbleTrack, suffix: String = "") -> [String: String] {
        var p = ["artist\(suffix)": t.artist, "track\(suffix)": t.title]
        if let a = t.album { p["album\(suffix)"] = a }
        if let a = t.albumArtist, a != t.artist { p["albumArtist\(suffix)"] = a }
        if t.duration > 0 { p["duration\(suffix)"] = String(Int(t.duration)) }
        if let n = t.trackNumber { p["trackNumber\(suffix)"] = String(n) }
        return p
    }

    public func nowPlaying(_ track: ScrobbleTrack) async throws {
        var p = Self.fields(track)
        p["sk"] = sessionKey
        _ = try await Self.call("track.updateNowPlaying", p, apiKey: apiKey, secret: secret, post: true)
    }

    public func scrobble(_ tracks: [ScrobbleTrack]) async throws {
        for chunk in stride(from: 0, to: tracks.count, by: 50).map({ Array(tracks[$0..<min($0 + 50, tracks.count)]) }) {
            var p = ["sk": sessionKey]
            for (i, t) in chunk.enumerated() {
                p.merge(Self.fields(t, suffix: "[\(i)]")) { a, _ in a }
                p["timestamp[\(i)]"] = String(t.timestamp)
            }
            _ = try await Self.call("track.scrobble", p, apiKey: apiKey, secret: secret, post: true)
        }
    }
}

// MARK: ListenBrainz

public struct ListenBrainzService: ScrobbleService {
    public let id = "listenbrainz"
    public let token: String

    public init(token: String) { self.token = token }

    static let base = URL(string: "https://api.listenbrainz.org/1/")!

    static func payload(_ t: ScrobbleTrack, listenedAt: Bool) -> [String: Any] {
        var info: [String: Any] = ["media_player": "Kveikur", "submission_client": "Kveikur", "submission_client_version": "1.0"]
        if t.duration > 0 { info["duration_ms"] = Int(t.duration * 1000) }
        if let n = t.trackNumber { info["tracknumber"] = n }
        var meta: [String: Any] = ["artist_name": t.artist, "track_name": t.title, "additional_info": info]
        if let a = t.album { meta["release_name"] = a }
        var item: [String: Any] = ["track_metadata": meta]
        if listenedAt { item["listened_at"] = t.timestamp }
        return item
    }

    private func submit(_ type: String, _ items: [[String: Any]]) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("submit-listens"))
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["listen_type": type, "payload": items])
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ScrobbleError.http(code, String(decoding: data, as: UTF8.self)) }
    }

    public func nowPlaying(_ track: ScrobbleTrack) async throws {
        try await submit("playing_now", [Self.payload(track, listenedAt: false)])
    }

    public func scrobble(_ tracks: [ScrobbleTrack]) async throws {
        for chunk in stride(from: 0, to: tracks.count, by: 100).map({ Array(tracks[$0..<min($0 + 100, tracks.count)]) }) {
            try await submit(chunk.count == 1 ? "single" : "import", chunk.map { Self.payload($0, listenedAt: true) })
        }
    }

    /// User name for a valid token.
    public static func validate(token: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("validate-token"))
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["valid"] as? Bool == true, let name = json["user_name"] as? String else {
            throw ScrobbleError.service(json["message"] as? String ?? "Invalid token")
        }
        return name
    }
}

// MARK: Queue

/// Scrobbles waiting per service, persisted so offline plays are sent later.
public actor ScrobbleQueue {
    private var pending: [String: [ScrobbleTrack]] = [:]
    private let file: URL
    private var flushing = false
    public private(set) var lastError: String?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kveikur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("scrobbles.json")
        if let data = try? Data(contentsOf: file),
           let p = try? JSONDecoder().decode([String: [ScrobbleTrack]].self, from: data) {
            pending = p
        }
    }

    public func count(for id: String) -> Int { pending[id]?.count ?? 0 }

    public func add(_ track: ScrobbleTrack, for ids: [String]) {
        for id in ids { pending[id, default: []].append(track) }
        save()
    }

    public func discard(_ id: String) {
        pending[id] = nil
        save()
    }

    /// Sends everything queued for each service; keeps what failed for a transient reason.
    public func flush(_ services: [any ScrobbleService]) async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for s in services {
            guard let items = pending[s.id], !items.isEmpty else { continue }
            do {
                try await s.scrobble(items)
                pending[s.id] = Array((pending[s.id] ?? []).dropFirst(items.count))
                lastError = nil
            } catch {
                lastError = "\(s.id): \(error.localizedDescription)"
                if (error as? ScrobbleError)?.isPermanent == true { pending[s.id] = nil }
            }
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: file, options: .atomic) }
    }
}

/// Counts real listening time for the loaded track and reports once it crosses the scrobble threshold.
public struct ListenCounter: Sendable {
    public private(set) var listened: TimeInterval = 0
    public private(set) var reported = false
    public let threshold: TimeInterval?

    public init(duration: TimeInterval) { threshold = ScrobbleRules.threshold(duration: duration) }

    /// Adds `seconds` of playback; true exactly once, when the play starts to count.
    public mutating func add(_ seconds: TimeInterval) -> Bool {
        listened += seconds
        guard !reported, let t = threshold, listened >= t else { return false }
        reported = true
        return true
    }
}

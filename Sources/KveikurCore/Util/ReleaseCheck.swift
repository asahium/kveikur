import Foundation

/// Latest GitHub release of the app; private repositories need a token with read access to contents.
public struct Release: Sendable, Equatable {
    public var version: String
    public var page: URL
    public var dmg: URL?
    public var notes: String
}

public enum ReleaseCheckError: LocalizedError {
    case notVisible
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notVisible: return "Releases aren't visible. The repository is private: add a GitHub token in Settings → Updates."
        case .http(let code): return "GitHub answered \(code)."
        }
    }
}

public enum ReleaseCheck {
    public static let repository = "asahium/kveikur"

    public static func latest(token: String?) async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return parse(data)
        case 404 where token?.isEmpty ?? true, 401, 403: throw ReleaseCheckError.notVisible
        case 404: return nil
        case let code: throw ReleaseCheckError.http(code)
        }
    }

    static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, dmg: dmg,
                       notes: o["body"] as? String ?? "")
    }

    /// Dotted numeric comparison: "0.10.0" > "0.9.2", "1.0" == "1.0.0".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func numbers(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

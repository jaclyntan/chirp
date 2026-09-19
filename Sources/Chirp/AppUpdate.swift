import Foundation

/// A real, available release — never fabricated. Everything here comes
/// from GitHub's own Releases API for this repo; there's no appcast, no
/// Sparkle, no auto-installer. "Update Now" opens the release's page (or
/// its asset) in the browser rather than downloading and replacing the
/// running app bundle in place — that's a much bigger, riskier feature
/// (unpacking an archive, verifying it, relaunching into it) than
/// translating this page's design calls for.
struct AppUpdate: Identifiable, Equatable {
    var version: String
    /// Raw bullet lines from the release body, marker stripped. Not
    /// split into a title/detail pair per row like the mockup's own
    /// illustration — that presumes a two-part structure a real release
    /// body may not have, so each line renders as one plain row instead.
    var notes: [String]
    var sizeBytes: Int64?
    var publishedAt: Date?
    /// Where "Update Now" sends you: the matching downloadable asset if
    /// the release has one, otherwise the release page itself.
    var downloadURL: URL
    var id: String { version }
}

enum UpdateChecker {
    /// Where releases are published. Must match the repo the DMG is
    /// actually uploaded to — a stale value here silently offers users
    /// someone else's releases as Chirp updates.
    private static let repo = "jaclyntan/chirp"

    /// Fetches the latest GitHub release and returns it only if its tag
    /// is newer than the running app's own `CFBundleShortVersionString`.
    /// Returns `nil` on any failure (offline, rate-limited, no releases
    /// yet) — a failed check should never surface as an error to the
    /// user, just silently mean "nothing to show."
    static func checkLatest() async -> AppUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return nil }

        let latestVersion = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst()) : release.tagName
        let runningVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(latestVersion, than: runningVersion) else { return nil }

        let asset = release.assets.first {
            $0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip")
        }
        guard let downloadURL = asset.flatMap({ URL(string: $0.browserDownloadURL) })
            ?? URL(string: release.htmlURL)
        else { return nil }

        let notes = (release.body ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("*") || $0.hasPrefix("•") }
            .map { $0.drop(while: { "-*• ".contains($0) }) }
            .map(String.init)

        let formatter = ISO8601DateFormatter()
        return AppUpdate(
            version: latestVersion,
            notes: notes,
            sizeBytes: asset?.size,
            publishedAt: release.publishedAt.flatMap(formatter.date(from:)),
            downloadURL: downloadURL)
    }

    /// Dotted-numeric comparison ("1.10.0" > "1.9.0"), padding whichever
    /// side has fewer components with zeros rather than requiring both
    /// tags to share the same shape.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = a.split(separator: ".").map { Int($0) ?? 0 }
        let partsB = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}

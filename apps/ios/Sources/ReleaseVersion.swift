import Foundation

// 和发布脚本一致：数字三段版本，可选 bN；正式版高于同号 Beta。
struct ReleaseVersion: Comparable {
    let text: String
    let parts: [Int]
    let beta: Int?

    init?(_ text: String) {
        guard text.range(of: "\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(b[1-9][0-9]*)?\\z", options: .regularExpression) != nil else { return nil }
        let pieces = text.split(separator: "b")
        let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let beta = pieces.count == 2 ? Int(pieces[1]) : nil
        guard pieces.count == 1 || beta != nil else { return nil }
        self.text = text; parts = numbers; self.beta = beta
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        if let left = lhs.beta, let right = rhs.beta { return left < right }
        return lhs.beta != nil && rhs.beta == nil
    }
}

struct ReleaseManifest {
    let version: ReleaseVersion
    let filename: String
    let sha256: String

    init?(_ text: String, platform: String) {
        guard text.utf8.count <= 65536, platform == "ios" || platform == "android" else { return nil }
        let suffix = platform == "ios" ? "-ios-arm64-unsigned.ipa" : "-android-arm64.apk"
        var matches: [(ReleaseVersion, String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0].range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil else { return nil }
            let name = String(fields[1])
            guard name.hasPrefix("weq-remote-"), name.hasSuffix(suffix) else { continue }
            let raw = String(name.dropFirst("weq-remote-".count).dropLast(suffix.count))
            guard let version = ReleaseVersion(raw) else { return nil }
            matches.append((version, name, String(fields[0])))
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        version = match.0; filename = match.1; sha256 = match.2
    }
}

struct RemoteRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]
    struct Asset: Decodable { let name: String }
    var version: ReleaseVersion? {
        guard tag_name.hasPrefix("v") else { return nil }
        return ReleaseVersion(String(tag_name.dropFirst()))
    }
    static func select(_ data: Data, includePrerelease: Bool) throws -> RemoteRelease? {
        try JSONDecoder().decode([RemoteRelease].self, from: data).filter { release in
            guard !release.draft, release.published_at != nil, let version = release.version,
                  release.assets.contains(where: { $0.name == "SHA256SUMS" }) else { return false }
            return includePrerelease || (!release.prerelease && version.beta == nil)
        }.max { $0.version! < $1.version! }
    }
}

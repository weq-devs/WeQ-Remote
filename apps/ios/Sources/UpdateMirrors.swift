import Foundation

struct UpdateMirror {
    let prefix: String
    let manifest: ReleaseManifest
    let milliseconds: Double
    var label: String { prefix.isEmpty ? "github.com（直连）" : URL(string: prefix)?.host ?? prefix }
    var downloadURL: URL { URL(string: "\(prefix)https://github.com/weq-devs/WeQ-Remote/releases/download/v\(manifest.version.text)/\(manifest.filename)")! }
}

enum UpdateMirrors {
    static func resolve(prefixes: [String], release: RemoteRelease? = nil, load: (@Sendable (URL, Bool) async throws -> Data)? = nil) async throws -> [UpdateMirror] {
        guard !prefixes.isEmpty, prefixes.count <= 64 else { throw RemoteError.response }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let healthy = await withTaskGroup(of: UpdateMirror?.self, returning: [UpdateMirror].self) { group in
            for prefix in prefixes {
                group.addTask {
                    do {
                        let start = ContinuousClock.now
                        let directory = release.map { "download/\($0.tag_name)" } ?? "latest/download"
                        let url = URL(string: "\(prefix)https://github.com/weq-devs/WeQ-Remote/releases/\(directory)/SHA256SUMS")!
                        let text: Data
                        if let load { text = try await load(url, false) }
                        else { text = try await read(session, url: url, limit: 65536) }
                        guard let raw = String(data: text, encoding: .utf8), let manifest = ReleaseManifest(raw, platform: "ios") else { return nil }
                        if let release, manifest.version != release.version { return nil }
                        let elapsed = ContinuousClock.now - start
                        return UpdateMirror(prefix: prefix, manifest: manifest, milliseconds: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                    } catch { return nil }
                }
            }
            var results: [UpdateMirror] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        guard let latest = healthy.map({ $0.manifest.version }).max() else { throw RemoteError.network }
        // 镜像可能缓存旧清单，只在最新的同一发布里比较速度。
        let candidates = healthy.filter { $0.manifest.version == latest }.sorted { $0.milliseconds < $1.milliseconds }
        let measured = await withTaskGroup(of: (Int, Double)?.self, returning: [(Int, Double)].self) { group in
            for (index, mirror) in candidates.prefix(3).enumerated() {
                group.addTask {
                    do {
                        let start = ContinuousClock.now
                        let data: Data
                        if let load { data = try await load(mirror.downloadURL, true) }
                        else { data = try await read(session, url: mirror.downloadURL, limit: 262144, range: true) }
                        guard data.count >= 65536 else { return nil }
                        let elapsed = ContinuousClock.now - start
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        return seconds > 0 ? (index, Double(data.count) / seconds) : nil
                    } catch { return nil }
                }
            }
            var results: [(Int, Double)] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        let order = measured.sorted { $0.1 > $1.1 }.map(\.0)
        return order.map { candidates[$0] } + candidates.enumerated().filter { !order.contains($0.offset) }.map(\.element)
    }

    static func release(includePrerelease: Bool) async throws -> RemoteRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://api.github.com/repos/weq-devs/WeQ-Remote/releases?per_page=100")!
        let data = try await read(session, url: url, limit: 4 * 1024 * 1024)
        guard let release = try RemoteRelease.select(data, includePrerelease: includePrerelease) else { throw RemoteError.response }
        return release
    }

    private static func read(_ session: URLSession, url: URL, limit: Int, range: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if range { request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206,
              response.url?.scheme == "https" else { throw RemoteError.response }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit {
                if range { break }
                throw RemoteError.response
            }
        }
        return data
    }
}

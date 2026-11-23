import CryptoKit
import Foundation
import WebKit

/// 同一电脑、授权与证书使用稳定的数据存储，跨进程复用资源缓存。
@MainActor
final class RemoteWebDataStore {
    private var identity: SHA256.Digest?
    private var store: WKWebsiteDataStore?
    private var business: RemoteBusinessCache?

    func dataStore(endpoint: URL, token: String, fingerprint: String?) -> WKWebsiteDataStore {
        let key = SHA256.hash(data: Data("\(endpoint.absoluteString)\n\(token)\n\(fingerprint ?? "")".utf8))
        if identity != key || store == nil {
            if #available(iOS 17.0, macOS 14.0, *) {
                let bytes = Array(key.prefix(16))
                let identifier = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                store = WKWebsiteDataStore(forIdentifier: identifier)
            } else {
                store = .nonPersistent()
            }
            identity = key
        }
        return store!
    }

    func clear(completion: @escaping @Sendable () -> Void = {}) {
        if let store {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: completion)
        } else { completion() }
        store = nil
        identity = nil
    }

    func businessCache(token: String) -> RemoteBusinessCache {
        let directory = RemoteBusinessCache.directory(token: token)
        if business?.directory != directory { business = RemoteBusinessCache(directory: directory) }
        return business!
    }

    func clearBusinessCache(token: String?) {
        business?.clear()
        if let token {
            let directory = RemoteBusinessCache.directory(token: token)
            if business?.directory != directory { RemoteBusinessCache(directory: directory).clear() }
        }
        business = nil
    }
}

/// WebKit storage is tied to web origins. Only the approved account snapshots are shared across routes.
@MainActor
final class RemoteBusinessCache {
    enum Kind: String, Sendable {
        case business, avatar, messages

        var maxPayload: Int {
            switch self {
            case .business: return 6 * 1024 * 1024
            case .avatar: return 384 * 1024
            case .messages: return 768 * 1024
            }
        }
        var maxFiles: Int { self == .avatar ? 192 : 4 }
        var maxBytes: Int {
            switch self {
            case .business: return 32 * 1024 * 1024
            case .avatar: return 12 * 1024 * 1024
            case .messages: return 4 * 1024 * 1024
            }
        }
    }

    private struct Snapshot: Codable, Sendable {
        let savedAt: Double
        let payload: String
    }

    private static let queue = DispatchQueue(label: "io.github.weqdevs.remote.business-cache", qos: .utility)
    let directory: URL
    private(set) var valid = true

    init(directory: URL) { self.directory = directory }

    static func directory(token: String) -> URL {
        let hash = digest("weq-business-v1\n\(token)")
        return URL.cachesDirectory.appendingPathComponent("WeQBusiness/\(hash)", isDirectory: true)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(scope: String, kind: Kind) -> URL? {
        guard valid, !scope.isEmpty, scope.utf8.count <= 512 else { return nil }
        return directory.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(Self.digest(scope))
    }

    private nonisolated static func read(_ file: URL, maxPayload: Int) -> Snapshot? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxPayload * 2 + 128, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.payload.utf8.count <= maxPayload else { return nil }
        return snapshot
    }

    func get(scope: String, kind: Kind = .business, newerThan: Double = 0) async -> String? {
        guard let file = file(scope: scope, kind: kind) else { return nil }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Self.queue.async {
                let snapshot = Self.read(file, maxPayload: kind.maxPayload)
                continuation.resume(returning: snapshot.flatMap { $0.savedAt > newerThan ? $0.payload : nil })
            }
        }
        return valid ? result : nil
    }

    func put(scope: String, kind: Kind = .business, payload: String, savedAt: Double) async {
        guard let file = file(scope: scope, kind: kind), payload.utf8.count <= kind.maxPayload,
              savedAt.isFinite, savedAt > 0, savedAt <= Date().timeIntervalSince1970 * 1000 + 60_000 else { return }
        let directory = file.deletingLastPathComponent()
        let snapshot = Snapshot(savedAt: savedAt, payload: payload)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                defer { continuation.resume() }
                if let previous = Self.read(file, maxPayload: kind.maxPayload), previous.savedAt > savedAt { return }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(snapshot)
                    #if os(iOS)
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    #else
                    try data.write(to: file, options: .atomic)
                    #endif
                    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                    let newest = files.compactMap { url -> (URL, Date, Int)? in
                        guard let values = try? url.resourceValues(forKeys: keys),
                              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
                        return (url, date, size)
                    }.sorted { $0.1 > $1.1 }
                    var total = 0
                    for (i, entry) in newest.enumerated() {
                        total += entry.2
                        if i >= kind.maxFiles || total > kind.maxBytes { try? FileManager.default.removeItem(at: entry.0) }
                    }
                } catch { /* The webpage keeps its origin-local copy. */ }
            }
        }
    }

    func clear() {
        valid = false
        let directory = self.directory
        Self.queue.async { try? FileManager.default.removeItem(at: directory) }
    }
}

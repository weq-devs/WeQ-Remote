import CryptoKit
import Foundation

struct RemoteInstantSnapshot: Codable, Equatable, Sendable {
    struct Chat: Codable, Equatable, Identifiable, Sendable {
        struct Row: Codable, Equatable, Identifiable, Sendable {
            let id: String
            let text: String
            let mine: Bool
        }
        let id: String
        let title: String
        let expiresAt: Double
        let rows: [Row]
    }

    let scope: String?
    let chats: [Chat]?

    static let maxBytes = 256 * 1024
    static func decode(_ data: Data) -> Self? {
        guard data.count <= maxBytes, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.scope == nil || (1...512).contains(value.scope!.utf8.count),
              (value.chats?.count ?? 0) <= 6 else { return nil }
        var ids = Set<String>()
        for chat in value.chats ?? [] {
            guard (1...240).contains(chat.id.utf8.count), ids.insert(chat.id).inserted,
                  !chat.title.isEmpty, chat.title.utf8.count <= 480, chat.expiresAt.isFinite,
                  (1...24).contains(chat.rows.count) else { return nil }
            var rowIDs = Set<String>()
            for row in chat.rows {
                guard (1...240).contains(row.id.utf8.count), rowIDs.insert(row.id).inserted,
                      !row.text.isEmpty, row.text.utf8.count <= 1440 else { return nil }
            }
        }
        return value
    }

    func current(now: Double = Date().timeIntervalSince1970 * 1000) -> Self? {
        guard let scope else { return nil }
        let current = (chats ?? []).filter { $0.expiresAt > now && $0.expiresAt <= now + 86_460_000 }
        return current.isEmpty ? nil : Self(scope: scope, chats: current)
    }
}

enum RemoteInstantStore {
    private static let queue = DispatchQueue(label: "io.github.weqdevs.remote.instant", qos: .userInitiated)

    private static func file(_ token: String) -> URL {
        let hash = SHA256.hash(data: Data("weq-instant-v1\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appendingPathComponent("WeQInstant/\(hash)")
    }

    private static func read(_ file: URL) -> RemoteInstantSnapshot? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= RemoteInstantSnapshot.maxBytes, let bytes = try? Data(contentsOf: file) else { return nil }
        return RemoteInstantSnapshot.decode(bytes)?.current()
    }

    static func load(_ token: String) async -> RemoteInstantSnapshot? {
        await withCheckedContinuation { result in queue.async { result.resume(returning: read(file(token))) } }
    }

    static func update(_ text: String, token: String) {
        queue.async {
            let target = file(token)
            guard let update = RemoteInstantSnapshot.decode(Data(text.utf8)) else { return }
            let previous = read(target)
            if update.chats == nil, update.scope != nil, update.scope == previous?.scope { return }
            guard let current = update.current() else { try? FileManager.default.removeItem(at: target); return }
            if previous == current { return }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(current)
                #if os(iOS)
                try data.write(to: target, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: target, options: .atomic)
                #endif
            } catch { /* The online workspace remains available. */ }
        }
    }

    static func clear(_ token: String) { queue.async { try? FileManager.default.removeItem(at: file(token)) } }
}

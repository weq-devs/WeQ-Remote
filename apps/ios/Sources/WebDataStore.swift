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
    enum Kind: String, Sendable, CaseIterable {
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

    private final class Generation {
        let lanes: [Kind: SnapshotLane]
        var valid = true

        init(directory: URL) {
            lanes = Dictionary(uniqueKeysWithValues: Kind.allCases.map { kind in
                (kind, SnapshotLane(directory: directory.appendingPathComponent(kind.rawValue, isDirectory: true), kind: kind))
            })
        }
    }

    private struct WeakGeneration {
        weak var value: Generation?
    }

    private static var generations: [String: WeakGeneration] = [:]
    private let generation: Generation
    private let directoryPath: String
    let directory: URL

    init(directory: URL) {
        directoryPath = directory.standardizedFileURL.path
        self.directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        Self.generations = Self.generations.filter { $0.value.value != nil }
        if let shared = Self.generations[directoryPath]?.value {
            generation = shared
        } else {
            generation = Generation(directory: self.directory)
            Self.generations[directoryPath] = WeakGeneration(value: generation)
        }
    }

    static func directory(token: String) -> URL {
        let hash = digest("weq-business-v1\n\(token)")
        return URL.cachesDirectory.appendingPathComponent("WeQBusiness/\(hash)", isDirectory: true)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func target(scope: String, kind: Kind) -> (SnapshotLane, String)? {
        guard generation.valid, !scope.isEmpty, scope.utf8.count <= 512,
              let lane = generation.lanes[kind] else { return nil }
        return (lane, Self.digest(scope))
    }

    func get(scope: String, kind: Kind = .business, newerThan: Double = 0) async -> String? {
        guard let (lane, name) = target(scope: scope, kind: kind) else { return nil }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            lane.queue.async { continuation.resume(returning: lane.get(name, newerThan: newerThan)) }
        }
        return generation.valid ? result : nil
    }

    func put(scope: String, kind: Kind = .business, payload: String, savedAt: Double) async {
        guard let (lane, name) = target(scope: scope, kind: kind), payload.utf8.count <= kind.maxPayload,
              savedAt.isFinite, savedAt > 0, savedAt <= Date().timeIntervalSince1970 * 1000 + 60_000 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lane.queue.async {
                lane.put(name, payload: payload, savedAt: savedAt)
                continuation.resume()
            }
        }
    }

    func getRecords(scope: String, kind: Kind, newerThan: Double) async -> BusinessCacheRecordRead? {
        guard kind != .avatar, let (lane, name) = target(scope: scope, kind: kind) else { return nil }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<BusinessCacheRecordRead?, Never>) in
            lane.queue.async { continuation.resume(returning: lane.getRecords(name, newerThan: newerThan)) }
        }
        return generation.valid ? result : nil
    }

    func putRecords(scope: String, kind: Kind, request: BusinessCacheRecordWrite) async -> BusinessCacheRecordResult {
        guard kind != .avatar, let (lane, name) = target(scope: scope, kind: kind),
              request.savedAt.isFinite, request.savedAt > 0,
              request.savedAt <= Date().timeIntervalSince1970 * 1000 + 60_000 else { return .unavailable }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<BusinessCacheRecordResult, Never>) in
            lane.queue.async { continuation.resume(returning: lane.putRecords(name, request: request)) }
        }
        return generation.valid ? result : .unavailable
    }

    func clear() {
        guard generation.valid else { return }
        generation.valid = false
        Self.generations.removeValue(forKey: directoryPath)
        for lane in generation.lanes.values {
            // 同类型的旧读写、清理、新授权首次写入按提交顺序执行。
            lane.queue.async { lane.clear() }
        }
    }
}

/// 每个类型独立排队；同一类型的磁盘读写和元数据只在该队列上访问。
private final class SnapshotLane: @unchecked Sendable {
    private static let queues: [RemoteBusinessCache.Kind: DispatchQueue] = Dictionary(
        uniqueKeysWithValues: RemoteBusinessCache.Kind.allCases.map { kind in
            (kind, DispatchQueue(label: "io.github.weqdevs.remote.business-cache.\(kind.rawValue)", qos: .utility))
        }
    )

    private struct Snapshot: Codable {
        let savedAt: Double
        let payload: String
    }

    private struct Stamp: Equatable {
        let bytes: Int
        let modified: Date
        let inode: UInt64?
    }

    private struct Entry {
        let stamp: Stamp
        var savedAt: Double?
    }

    let queue: DispatchQueue
    private let directory: URL
    private let kind: RemoteBusinessCache.Kind
    private let records: BusinessCacheRecords
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var indexed = false
    private var maxSnapshotBytes: Int { kind.maxPayload * 2 + 128 }

    init(directory: URL, kind: RemoteBusinessCache.Kind) {
        self.directory = directory
        self.kind = kind
        records = BusinessCacheRecords(directory: directory, maxBytes: kind.maxPayload)
        queue = Self.queues[kind]!
    }

    private func stamp(_ file: URL) -> Stamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = values[.size] as? Int, let modified = values[.modificationDate] as? Date,
              values[.type] as? FileAttributeType == .typeRegular else { return nil }
        return Stamp(bytes: size, modified: modified, inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func set(_ name: String, _ entry: Entry?) {
        bytes += (entry?.stamp.bytes ?? 0) - (entries[name]?.stamp.bytes ?? 0)
        entries[name] = entry
    }

    private func observe(_ file: URL) -> Entry? {
        let name = file.lastPathComponent
        guard let stamp = stamp(file) else {
            set(name, nil)
            return nil
        }
        if let known = entries[name], stamp.inode != nil, known.stamp == stamp { return known }
        let entry = Entry(stamp: stamp)
        set(name, entry)
        return entry
    }

    private func read(_ file: URL, entry: Entry) -> Snapshot? {
        guard entry.stamp.bytes <= maxSnapshotBytes, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.payload.utf8.count <= kind.maxPayload else { return nil }
        set(file.lastPathComponent, Entry(stamp: entry.stamp, savedAt: snapshot.savedAt))
        return snapshot
    }

    func get(_ name: String, newerThan: Double) -> String? {
        let file = directory.appendingPathComponent(name)
        guard let entry = observe(file), entry.savedAt.map({ $0 > newerThan }) != false,
              let snapshot = read(file, entry: entry), snapshot.savedAt > newerThan else { return nil }
        return snapshot.payload
    }

    private func legacySavedAt(_ name: String) -> Double? {
        let file = directory.appendingPathComponent(name)
        guard let entry = observe(file) else { return nil }
        return entry.savedAt ?? read(file, entry: entry)?.savedAt
    }

    func getRecords(_ name: String, newerThan: Double) -> BusinessCacheRecordRead? {
        let old = legacySavedAt(name) ?? 0
        let updated = records.savedAt(name) ?? 0
        if updated >= old, let result = records.get(name, newerThan: newerThan) { return result }
        if let payload = get(name, newerThan: newerThan) { return .legacy(payload) }
        return updated < old ? records.get(name, newerThan: newerThan) : nil
    }

    func putRecords(_ name: String, request: BusinessCacheRecordWrite) -> BusinessCacheRecordResult {
        if let old = legacySavedAt(name), old > request.savedAt { return .unchanged }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !indexed { try indexDirectory() }
        } catch { return .unavailable }
        let result = records.put(name, request: request)
        if result == .stored { prune() }
        return result
    }

    func put(_ name: String, payload: String, savedAt: Double) {
        let file = directory.appendingPathComponent(name)
        if let previous = legacySavedAt(name), previous > savedAt { return }
        let structured = kind == .avatar ? nil : records.savedAt(name)
        if let structured, structured > savedAt { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !indexed { try indexDirectory() }
            let data = try JSONEncoder().encode(Snapshot(savedAt: savedAt, payload: payload))
            guard data.count <= maxSnapshotBytes else { return }
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            set(name, stamp(file).map { Entry(stamp: $0, savedAt: savedAt) })
            if structured != nil { records.remove(name) }
            prune()
        } catch { /* The webpage keeps its origin-local copy. */ }
    }

    private func indexDirectory() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [])
        for file in files { _ = observe(file) }
        if kind != .avatar { records.index(files) }
        indexed = true
    }

    private var overBudget: Bool {
        if kind == .avatar { return entries.count > kind.maxFiles || bytes > kind.maxBytes }
        return Set(entries.keys).union(records.ages.keys).count > kind.maxFiles || bytes + records.bytes > kind.maxBytes
    }

    private func prune() {
        guard overBudget else { return }
        let structured = records.ages
        let ages = entries.mapValues { $0.stamp.modified }.merging(structured) { max($0, $1) }
        for (name, _) in ages.sorted(by: { $0.value < $1.value }) {
            guard overBudget else { break }
            if entries[name] != nil {
                let file = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.removeItem(at: file)
                    set(name, nil)
                } catch {
                    // 第三方已移走缓存时也把对应字节从索引扣除。
                    _ = observe(file)
                }
            }
            if structured[name] != nil { records.remove(name) }
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        entries.removeAll()
        records.reset()
        bytes = 0
        indexed = false
    }
}

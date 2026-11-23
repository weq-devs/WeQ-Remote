import Foundation

struct BusinessCacheRecord: Sendable {
    let key: String
    let payload: String
}

struct BusinessCacheRecordWrite: Sendable {
    let savedAt: Double
    let revision: String
    let base: String?
    let keys: [String]
    let records: [BusinessCacheRecord]
}

enum BusinessCacheRecordResult: String, Sendable {
    case stored, unchanged, needsFull, unavailable
}

enum BusinessCacheRecordRead: Sendable {
    case legacy(String)
    case records(savedAt: Double, [BusinessCacheRecord])
}

/// 每个账号、类型用一份原子清单指向独立查询文件。由 SnapshotLane 的队列访问。
final class BusinessCacheRecords {
    static let countLimit = 160
    static let keyLimit = 8 * 1024
    static let revisionLimit = 128
    private static let suffix = ".records"
    private static let manifestName = "current.json"

    private struct Row: Codable {
        let key: String
        let file: String
        let bytes: Int
    }

    private struct Manifest: Codable {
        let savedAt: Double
        let revision: String
        let rows: [Row]
    }

    private struct Stamp: Equatable {
        let bytes: Int
        let modified: Date
        let inode: UInt64?
    }

    private struct Entry {
        let manifest: Manifest
        let stamp: Stamp

        var bytes: Int { stamp.bytes + manifest.rows.reduce(0) { $0 + $1.bytes } }
    }

    private let directory: URL
    private let maxBytes: Int
    private var entries: [String: Entry] = [:]

    init(directory: URL, maxBytes: Int) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    var ages: [String: Date] { entries.mapValues { $0.stamp.modified } }
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    private func folder(_ name: String) -> URL {
        directory.appendingPathComponent(name + Self.suffix, isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return values?[.type] as? FileAttributeType == .typeDirectory
    }

    private func stamp(_ file: URL) -> Stamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = values[.size] as? Int, let date = values[.modificationDate] as? Date,
              values[.type] as? FileAttributeType == .typeRegular else { return nil }
        return Stamp(bytes: size, modified: date, inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func readManifest(_ name: String) -> Entry? {
        let root = folder(name)
        let file = root.appendingPathComponent(Self.manifestName)
        guard isDirectory(root), let info = stamp(file), info.bytes <= maxBytes else {
            entries[name] = nil
            return nil
        }
        if let known = entries[name], info.inode != nil, known.stamp == info { return known }
        guard let data = try? Data(contentsOf: file),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.savedAt.isFinite, manifest.savedAt > 0,
              Self.validRevision(manifest.revision), manifest.rows.count <= Self.countLimit,
              manifest.rows.allSatisfy({ Self.validKey($0.key) && UUID(uuidString: $0.file) != nil && $0.bytes > 0 && $0.bytes <= maxBytes }),
              Set(manifest.rows.map(\.key)).count == manifest.rows.count,
              Set(manifest.rows.map(\.file)).count == manifest.rows.count,
              manifest.rows.reduce(info.bytes, { $0 + $1.bytes }) <= maxBytes else {
            entries[name] = nil
            return nil
        }
        let entry = Entry(manifest: manifest, stamp: info)
        entries[name] = entry
        return entry
    }

    func savedAt(_ name: String) -> Double? { readManifest(name)?.manifest.savedAt }

    func get(_ name: String, newerThan: Double) -> BusinessCacheRecordRead? {
        guard let manifest = readManifest(name)?.manifest, manifest.savedAt > newerThan else { return nil }
        let root = folder(name)
        var result: [BusinessCacheRecord] = []
        for row in manifest.rows {
            let file = root.appendingPathComponent(row.file)
            guard stamp(file)?.bytes == row.bytes, let data = try? Data(contentsOf: file),
                  data.count == row.bytes, let payload = String(data: data, encoding: .utf8) else { return nil }
            result.append(BusinessCacheRecord(key: row.key, payload: payload))
        }
        return .records(savedAt: manifest.savedAt, result)
    }

    func put(_ name: String, request: BusinessCacheRecordWrite) -> BusinessCacheRecordResult {
        let previous = readManifest(name)?.manifest
        if let previous, previous.savedAt > request.savedAt || previous.revision == request.revision { return .unchanged }
        if let base = request.base, previous?.revision != base { return .needsFull }
        guard Self.validRevision(request.revision), request.keys.count <= Self.countLimit,
              request.keys.allSatisfy(Self.validKey), Set(request.keys).count == request.keys.count,
              request.records.count <= request.keys.count else { return .unavailable }

        let root = folder(name)
        let keys = Set(request.keys)
        var pending: [String: String] = [:]
        for record in request.records {
            guard keys.contains(record.key), !record.payload.isEmpty,
                  pending.updateValue(record.payload, forKey: record.key) == nil else { return .unavailable }
        }
        let old = Dictionary(uniqueKeysWithValues: (request.base == nil ? [] : previous?.rows ?? []).map { ($0.key, $0) })
        var rows: [Row] = []
        var changed: [(Row, String)] = []
        var total = 0
        for key in request.keys {
            let row: Row
            if let payload = pending[key] {
                row = Row(key: key, file: UUID().uuidString, bytes: payload.utf8.count)
                changed.append((row, payload))
            } else if let saved = old[key], stamp(root.appendingPathComponent(saved.file))?.bytes == saved.bytes {
                row = saved
            } else {
                return .needsFull
            }
            guard row.bytes <= maxBytes - total else { return .unavailable }
            total += row.bytes
            rows.append(row)
        }

        let manifest = Manifest(savedAt: request.savedAt, revision: request.revision, rows: rows)
        var written: [URL] = []
        do {
            let data = try JSONEncoder().encode(manifest)
            guard data.count <= maxBytes - total else { return .unavailable }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard isDirectory(root) else { return .unavailable }
            for (row, payload) in changed {
                let file = root.appendingPathComponent(row.file)
                try write(Data(payload.utf8), to: file)
                written.append(file)
            }
            let target = root.appendingPathComponent(Self.manifestName)
            try write(data, to: target)
            entries[name] = stamp(target).map { Entry(manifest: manifest, stamp: $0) }
        } catch {
            for file in written { try? FileManager.default.removeItem(at: file) }
            return .unavailable
        }
        removeOrphans(root, retaining: Set(rows.map(\.file)))
        return .stored
    }

    func index(_ files: [URL]) {
        for file in files where file.lastPathComponent.hasSuffix(Self.suffix) {
            let name = String(file.lastPathComponent.dropLast(Self.suffix.count))
            guard name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), isDirectory(file) else { continue }
            let manifest = file.appendingPathComponent(Self.manifestName)
            if let current = readManifest(name) {
                removeOrphans(file, retaining: Set(current.manifest.rows.map(\.file)))
            } else {
                // 读不到已有清单可能是暂时的文件保护，保留其引用内容。
                do { _ = try FileManager.default.attributesOfItem(atPath: manifest.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                    removeOrphans(file, retaining: [])
                } catch { }
            }
        }
    }

    func remove(_ name: String) {
        let root = folder(name)
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            entries[name] = nil
        } catch { _ = readManifest(name) }
    }

    func reset() { entries.removeAll() }

    private func removeOrphans(_ root: URL, retaining: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where UUID(uuidString: file.lastPathComponent) != nil && !retaining.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func validKey(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= keyLimit }
    private static func validRevision(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= revisionLimit }

    private func write(_ data: Data, to file: URL) throws {
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}

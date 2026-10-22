import CryptoKit
import Foundation
import WebKit

/// 仅在同一电脑和授权下复用内存缓存，不把网页数据持久化到磁盘。
@MainActor
final class RemoteWebDataStore {
    private var identity: SHA256.Digest?
    private var store: WKWebsiteDataStore?

    func dataStore(endpoint: URL, token: String, fingerprint: String?) -> WKWebsiteDataStore {
        let key = SHA256.hash(data: Data("\(endpoint.absoluteString)\n\(token)\n\(fingerprint ?? "")".utf8))
        if identity != key || store == nil {
            store = .nonPersistent()
            identity = key
        }
        return store!
    }

    func clear() {
        store = nil
        identity = nil
    }
}

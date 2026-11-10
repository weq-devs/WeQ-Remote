import CryptoKit
import Foundation
import WebKit

/// 同一电脑、授权与证书使用稳定的数据存储，跨进程复用资源缓存。
@MainActor
final class RemoteWebDataStore {
    private var identity: SHA256.Digest?
    private var store: WKWebsiteDataStore?

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
}

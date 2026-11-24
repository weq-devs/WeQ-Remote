import SwiftUI

@MainActor
struct RemoteLocalCache {
    nonisolated static let mib: Int64 = 1 << 20
    static let limits = 16...4096

    struct Status: Decodable {
        let bytes: Int64
        let limit: Int64

        var limitMiB: Int { Int(limit / RemoteLocalCache.mib) }
    }

    enum Operation {
        case read, setLimit(Int), clear

        var failure: String {
            switch self {
            case .read: "无法读取本机缓存，请重试。"
            case .setLimit: "无法保存缓存上限，请重试。"
            case .clear: "无法清除业务缓存，请重试。"
            }
        }
    }

    private static let transport = URLSession(configuration: EmbeddedNetwork.configuration(),
        delegate: NoRedirectDelegate(), delegateQueue: nil)
    let origin: URL
    let cookie: HTTPCookie

    func perform(_ operation: Operation) async throws -> Status {
        var url = origin.appending(path: "_weq-remote-local/cache")
        let method: String
        switch operation {
        case .read: method = "GET"
        case .setLimit(let limit):
            guard Self.limits.contains(limit) else { throw RemoteError.response }
            url.append(queryItems: [URLQueryItem(name: "limit", value: String(Int64(limit) * Self.mib))])
            method = "PUT"
        case .clear: method = "DELETE"
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: [cookie])
        let (data, response) = try await Self.transport.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.value(forHTTPHeaderField: "X-WeQ-Data-Cache") == "1" else { throw RemoteError.response }
        return try JSONDecoder().decode(Status.self, from: data)
    }
}

struct LocalCacheSection: View {
    let cache: RemoteLocalCache
    let onChange: (Bool) -> Void
    @State private var status: RemoteLocalCache.Status?
    @State private var busy = true
    @State private var notice: String?
    @State private var editingLimit = false
    @State private var confirmingClear = false
    @State private var limitInput = ""

    private var validLimit: Int? {
        guard let limit = Int(limitInput), RemoteLocalCache.limits.contains(limit) else { return nil }
        return limit
    }

    var body: some View {
        Section("本机缓存") {
            if let status {
                let used = (Double(status.bytes) / Double(RemoteLocalCache.mib)).formatted(.number.precision(.fractionLength(1)))
                LabeledContent("已用空间", value: "\(used) MiB")
                Button {
                    limitInput = String(status.limitMiB)
                    editingLimit = true
                } label: {
                    LabeledContent("缓存上限", value: "\(status.limitMiB) MiB")
                }.disabled(busy)
                Button("清除业务缓存", role: .destructive) { confirmingClear = true }
                    .disabled(busy)
            } else if !busy {
                Button("重试读取") { Task { await run(.read) } }
            }
            if busy {
                ProgressView(status == nil ? "正在读取本机缓存…" : "正在更新本机缓存…")
            } else if let notice {
                Text(notice).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .task { await run(.read) }
        .alert("缓存上限（MiB）", isPresented: $editingLimit) {
            TextField("16–4096", text: $limitInput).keyboardType(.numberPad)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let limit = validLimit { Task { await run(.setLimit(limit)) } }
            }.disabled(validLimit == nil || validLimit == status?.limitMiB)
        } message: {
            Text("输入 16–4096 MiB。超出上限时优先清理最久未使用的数据。")
        }
        .alert("清除业务缓存？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { Task { await run(.clear) } }
        } message: {
            Text("将清除当前电脑的本机聊天、图片和其他业务缓存。网页代码和配对信息会保留。")
        }
    }

    private func run(_ operation: RemoteLocalCache.Operation) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            status = try await cache.perform(operation)
            switch operation {
            case .read: break
            case .setLimit:
                notice = "缓存上限已保存。"
                onChange(false)
            case .clear:
                notice = "已清除业务缓存。"
                onChange(true)
            }
        } catch {
            if !Task.isCancelled { notice = operation.failure }
        }
    }
}

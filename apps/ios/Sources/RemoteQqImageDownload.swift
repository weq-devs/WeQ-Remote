import Foundation

struct RemoteQqImage: Sendable {
    let type: String
    let bytes: Data
}

/// 使用一个隔离的系统会话，按 URLSession 交付的数据块收取有界图片。
final class RemoteQqImageDownload: Sendable {
    private let receiver = Receiver()
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
    }

    func load(_ url: URL) async throws -> RemoteQqImage {
        guard let task = receiver.task(in: session, for: url) else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard receiver.register(task, continuation: continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if Task.isCancelled {
                    receiver.cancel(task)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            receiver.cancel(task)
        }
    }

    func close() {
        receiver.close()
        session.invalidateAndCancel()
    }

    deinit { close() }
}

private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 2 * 1024 * 1024
    private static let types: Set<String> = ["image/jpeg", "image/png", "image/apng", "image/gif", "image/webp", "image/avif"]

    // Transfer 只在持有 lock 时访问，交给调用方的是任务完成后的只读结果。
    private final class Transfer {
        let continuation: CheckedContinuation<RemoteQqImage, Error>
        var type: String?
        var bytes = Data()

        init(continuation: CheckedContinuation<RemoteQqImage, Error>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var closed = false

    func task(in session: URLSession, for url: URL) -> URLSessionDataTask? {
        lock.withLock { closed ? nil : session.dataTask(with: url) }
    }

    func register(_ task: URLSessionDataTask, continuation: CheckedContinuation<RemoteQqImage, Error>) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            transfers[task.taskIdentifier] = Transfer(continuation: continuation)
            return true
        }
    }

    func cancel(_ task: URLSessionDataTask) {
        remove(task)?.continuation.resume(throwing: CancellationError())
        task.cancel()
    }

    func close() {
        let pending = lock.withLock {
            closed = true
            let pending = transfers
            transfers.removeAll()
            return pending
        }
        for transfer in pending.values { transfer.continuation.resume(throwing: CancellationError()) }
    }

    private func remove(_ task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let type = http.mimeType, Self.types.contains(type),
              http.expectedContentLength <= Self.limit else {
            remove(dataTask)?.continuation.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let accepted = lock.withLock {
            guard let transfer = transfers[dataTask.taskIdentifier] else { return false }
            transfer.type = type
            if http.expectedContentLength > 0 {
                transfer.bytes.reserveCapacity(Int(http.expectedContentLength))
            }
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock {
            guard let transfer = transfers[dataTask.taskIdentifier] else { return false }
            guard data.count <= Self.limit - transfer.bytes.count else { return true }
            transfer.bytes.append(data)
            return false
        }
        if exceeded {
            remove(dataTask)?.continuation.resume(throwing: URLError(.dataLengthExceedsMaximum))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = remove(task) else { return }
        if let error {
            transfer.continuation.resume(throwing: error)
        } else if let type = transfer.type, !transfer.bytes.isEmpty {
            transfer.continuation.resume(returning: RemoteQqImage(type: type, bytes: transfer.bytes))
        } else {
            transfer.continuation.resume(throwing: URLError(.zeroByteResource))
        }
    }
}

import Foundation
import XCTest
@testable import WeQRemote

final class RemoteQqImageDownloadTests: XCTestCase {
    private func download() -> RemoteQqImageDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageProtocol.self]
        return RemoteQqImageDownload(configuration: configuration)
    }

    private func url(_ path: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://image.fixture.invalid/" + path))
    }

    func testReceivesCompleteChunkedImageAtLimit() async throws {
        let session = download()
        defer { session.close() }
        let image = try await session.load(url("limit"))
        XCTAssertEqual(image.type, "image/png")
        XCTAssertEqual(image.bytes, ImageProtocol.chunk + Data(repeating: 0x7b, count: (128 - 1) * ImageProtocol.chunk.count))
    }

    func testRejectsOversizeUnknownLengthAndInvalidHeaders() async throws {
        let session = download()
        defer { session.close() }
        for (path, code): (String, URLError.Code) in [
            ("overflow", .dataLengthExceedsMaximum),
            ("declared", .badServerResponse),
            ("wrong-type", .badServerResponse),
            ("bad-status", .badServerResponse),
            ("empty", .zeroByteResource),
        ] {
            do {
                _ = try await session.load(url(path))
                XCTFail("Accepted invalid image: " + path)
            } catch let error as URLError {
                XCTAssertEqual(error.code, code, path)
            }
        }
        let image = try await session.load(url("small"))
        XCTAssertEqual(image.bytes, ImageProtocol.chunk)
    }

    func testCancellationAndCloseFinishOutstandingTransfers() async throws {
        let session = download()
        let cancelled = try url("cancel")
        let started = expectation(description: "download started")
        ImageProtocol.expectStart(of: "cancel", started)
        let task = Task { try await session.load(cancelled) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled transfer returned an image")
        } catch is CancellationError {}
        let closing = try url("close")
        let pending = expectation(description: "second download started")
        ImageProtocol.expectStart(of: "close", pending)
        let other = Task { try await session.load(closing) }
        await fulfillment(of: [pending], timeout: 1)
        session.close()
        do {
            _ = try await other.value
            XCTFail("Closed session returned an image")
        } catch is CancellationError {}
    }
}

private final class ImageProtocol: URLProtocol {
    static let chunk = Data(repeating: 0x7b, count: 16 * 1024)
    private static let lock = NSLock()
    private static var starts: [String: XCTestExpectation] = [:]

    static func expectStart(of path: String, _ expectation: XCTestExpectation) {
        lock.withLock { starts[path] = expectation }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        if let started = Self.lock.withLock({ Self.starts.removeValue(forKey: path) }) {
            started.fulfill()
            return
        }
        var headers = ["Content-Type": path == "wrong-type" ? "text/html" : "image/png"]
        if path == "declared" { headers["Content-Length"] = String(2 * 1024 * 1024 + 1) }
        let response = HTTPURLResponse(url: url, statusCode: path == "bad-status" ? 404 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let count = path == "limit" ? 128 : path == "overflow" ? 129 : path == "empty" ? 0 : 1
        for _ in 0..<count { client?.urlProtocol(self, didLoad: Self.chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

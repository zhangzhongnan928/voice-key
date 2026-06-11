import Foundation

/// URLProtocol mock for API tests: success, 429, 500, timeout, malformed JSON.
final class MockURLProtocol: URLProtocol {
    /// Return (status, body) for a response, or throw to simulate a transport
    /// error (use URLError(.timedOut) for the timeout case).
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    /// Extra response headers (e.g. Retry-After), merged into every response.
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            var headers = ["Content-Type": "application/json"]
            headers.merge(Self.responseHeaders) { _, new in new }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

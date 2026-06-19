import Foundation

/// Test-only `URLProtocol` that intercepts every request issued by a
/// `URLSession` configured with `protocolClasses = [MockURLProtocol.self]`,
/// and feeds it back through a per-test handler.
///
/// Handler shape: `(URLRequest) throws -> (HTTPURLResponse, Data)`. Tests set
/// the handler with `setHandler` before exercising the system under test.
final nonisolated class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var _handler: Handler = { _ in
        throw URLError(.unknown)
    }
    private static let lock = NSLock()

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    static func reset() {
        setHandler { _ in throw URLError(.unknown) }
    }

    private static func currentHandler() -> Handler {
        lock.lock()
        defer { lock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.currentHandler()
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Marker class used to find this bundle for fixture loading.
nonisolated final class JellyBeatTestsBundleToken {}

/// Thread-safe captured-request store used by tests that assert on what the
/// client sent. Synchronous to avoid the test having to wait on detached
/// `Task` flushes.
nonisolated final class RequestCapture: @unchecked Sendable {
    private var requests: [URLRequest] = []
    private let lock = NSLock()

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    func all() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

nonisolated enum FixtureLoader {
    static func data(named name: String, ext: String = "json") throws -> Data {
        let bundle = Bundle(for: JellyBeatTestsBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw FixtureError.notFound(name + "." + ext)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        var description: String {
            switch self {
            case .notFound(let name): return "Fixture not found: \(name)"
            }
        }
    }
}

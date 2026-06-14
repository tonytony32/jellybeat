import Foundation
import Testing
@testable import JellySleeve

/// Test-only `URLProtocol` dedicated to this suite. Mirrors `MockURLProtocol`
/// but keeps its **own** static handler so this suite and `JellyfinClientTests`
/// — which run in parallel as sibling top-level suites — can't stomp each
/// other's global handler (`.serialized` only orders tests *within* a suite).
final nonisolated class BridgeMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var _handler: Handler = { _ in
        throw URLError(.unknown)
    }
    private static let lock = NSLock()

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock(); _handler = handler; lock.unlock()
    }

    private static func currentHandler() -> Handler {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.currentHandler()(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Tests for `YouTubeBridgeClient` using `BridgeMockURLProtocol` to intercept
/// the loopback `URLSession`. Cover the `focusTab` command wire format + status
/// handling and the `canFocusTab` capability parsing from `/v1/health`.
///
/// `.serialized` because the mock keeps a single static handler the suite's own
/// tests would otherwise race.
@Suite(.serialized)
nonisolated struct YouTubeBridgeClientTests {

    private func makeClient() -> YouTubeBridgeClient {
        YouTubeBridgeClient(protocolClasses: [BridgeMockURLProtocol.self])
    }

    private func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - focusTab command

    /// `focusTab` POSTs to `/v1/command` with `{"action":"focusTab"}` and **no
    /// value** — and crucially never sets an `Origin` header (the bridge 403s
    /// anything that looks browser-issued). A `202` response is success.
    @Test
    func focusTabPostsActionWithoutOriginOrValue() async throws {
        let capture = RequestCapture()
        BridgeMockURLProtocol.setHandler { req in
            capture.record(req)
            // URLSession moves the POST body onto the stream, so read it back
            // from `httpBodyStream` rather than `httpBody`.
            return (self.response(202, for: req), Data(#"{"queued":true}"#.utf8))
        }
        let client = makeClient()

        try await client.focusTab()

        let sent = capture.all()
        #expect(sent.count == 1)
        let req = try #require(sent.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/command")
        // No Origin header — a native client must not look browser-issued.
        #expect(req.value(forHTTPHeaderField: "Origin") == nil)

        let body = bodyData(of: req)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["action"] as? String == "focusTab")
        // `value` is omitted entirely for focusTab (encoded nil → absent key).
        #expect(json?.keys.contains("value") == false)
    }

    /// A `503 safari_disconnected` (tab went stale) surfaces as a thrown
    /// transport error — `PlayerStore.focusSource` swallows it, but the client
    /// itself must not silently treat it as success.
    @Test
    func focusTab503Throws() async throws {
        BridgeMockURLProtocol.setHandler { req in
            (self.response(503, for: req), Data(#"{"error":"safari_disconnected"}"#.utf8))
        }
        let client = makeClient()

        await #expect(throws: (any Error).self) {
            try await client.focusTab()
        }
    }

    /// A `409 no_active_player` is a non-2xx status and likewise throws (mapped
    /// to `serverError`), for the caller to swallow.
    @Test
    func focusTab409Throws() async throws {
        BridgeMockURLProtocol.setHandler { req in
            (self.response(409, for: req), Data(#"{"error":"no_active_player"}"#.utf8))
        }
        let client = makeClient()

        await #expect(throws: NetworkError.serverError(409)) {
            try await client.focusTab()
        }
    }

    // MARK: - canFocusTab capability

    /// `/v1/health` advertising `canFocusTab: true` lights up the capability.
    @Test
    func healthCanFocusTabTrueIsParsed() async throws {
        BridgeMockURLProtocol.setHandler { req in
            (self.response(200, for: req), Data(#"{"capabilities":{"canFocusTab":true}}"#.utf8))
        }
        let caps = await makeClient().fetchCapabilities()
        #expect(caps.canFocusTab == true)
    }

    /// An older bridge whose health omits `canFocusTab` defaults to `false`, so
    /// the artwork affordance stays hidden.
    @Test
    func healthMissingCanFocusTabDefaultsFalse() async throws {
        BridgeMockURLProtocol.setHandler { req in
            (self.response(200, for: req), Data(#"{"capabilities":{"canPlayPause":true}}"#.utf8))
        }
        let caps = await makeClient().fetchCapabilities()
        #expect(caps.canFocusTab == false)
    }

    /// An unreachable bridge falls back to the YouTube constant set, where
    /// `canFocusTab` is conservatively false until health confirms otherwise.
    @Test
    func unreachableBridgeFallsBackToFalse() async throws {
        BridgeMockURLProtocol.setHandler { _ in throw URLError(.cannotConnectToHost) }
        let caps = await makeClient().fetchCapabilities()
        #expect(caps.canFocusTab == false)
    }

    // MARK: - Helpers

    /// Read a request body whether URLSession kept it inline (`httpBody`) or
    /// moved it onto a stream (`httpBodyStream`), as it does for POSTs.
    private func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

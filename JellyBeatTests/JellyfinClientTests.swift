import Foundation
import Testing
@testable import JellyBeat

/// Tests for `JellyfinClient` using `MockURLProtocol` to intercept the
/// underlying `URLSession`. Cover the error-mapping table from plan §5 and
/// the contract that every request carries the `X-Emby-Token` auth header.
///
/// `.serialized` because `MockURLProtocol` keeps a single static handler that
/// would otherwise be raced by Swift Testing's default parallel execution.
@Suite(.serialized)
nonisolated struct JellyfinClientTests {
    private static let baseURL = URL(string: "https://example-server.local")!

    private func makeClient(allowSelfSigned: Bool = false) -> JellyfinClient {
        JellyfinClient(
            configuration: JellyfinConfiguration(
                baseURL: Self.baseURL,
                apiKey: "test-key-1234",
                userId: "test-user",
                allowSelfSigned: allowSelfSigned
            ),
            protocolClasses: [MockURLProtocol.self]
        )
    }

    private func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - Error mapping

    @Test
    func maps401ToUnauthorized() async throws {
        MockURLProtocol.setHandler { req in
            return (self.response(401, for: req), Data())
        }
        let client = makeClient()

        await #expect(throws: NetworkError.unauthorized) {
            _ = try await client.validateConnection()
        }
    }

    @Test
    func maps404ToNotFound() async throws {
        MockURLProtocol.setHandler { req in
            return (self.response(404, for: req), Data())
        }
        let client = makeClient()

        await #expect(throws: NetworkError.notFound) {
            _ = try await client.fetchSessions()
        }
    }

    @Test
    func maps500ToServerError() async throws {
        MockURLProtocol.setHandler { req in
            return (self.response(500, for: req), Data())
        }
        let client = makeClient()

        await #expect(throws: NetworkError.serverError(500)) {
            _ = try await client.fetchSessions()
        }
    }

    // MARK: - Auth header

    @Test
    func sendsXEmbyTokenHeaderOnEveryEndpoint() async throws {
        let capture = RequestCapture()

        MockURLProtocol.setHandler { req in
            capture.record(req)
            let body = Data("{\"Id\":\"x\",\"ServerName\":\"x\",\"Version\":\"x\"}".utf8)
            return (HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!, body)
        }
        let client = makeClient()

        _ = try? await client.validateConnection()
        try? await client.playPause(sessionId: "session-1")
        try? await client.nextTrack(sessionId: "session-1")
        try? await client.previousTrack(sessionId: "session-1")
        _ = try? await client.fetchArtwork(itemId: "item-1", tag: "tag-1")

        let captured = capture.all()
        #expect(captured.count == 5)
        for request in captured {
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "test-key-1234",
                    "Missing or wrong X-Emby-Token on \(request.url?.absoluteString ?? "?")")
        }
    }

    // MARK: - Happy path

    @Test
    func validateConnectionReturnsParsedServerInfo() async throws {
        let payload = try FixtureLoader.data(named: "system_info")
        MockURLProtocol.setHandler { req in
            (HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!, payload)
        }
        let client = makeClient()

        let info = try await client.validateConnection()
        #expect(info.serverName == "JellyfinTestServer")
        #expect(info.version == "10.10.3")
    }

    @Test
    func fetchSessionsParsesNowPlaying() async throws {
        let payload = try FixtureLoader.data(named: "sessions_playing")
        MockURLProtocol.setHandler { req in
            (HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!, payload)
        }
        let client = makeClient()

        let sessions = try await client.fetchSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].nowPlayingItem?.name == "Test Track")
    }

    @Test
    func sessionPlayPauseHitsExpectedURL() async throws {
        let capture = RequestCapture()
        MockURLProtocol.setHandler { req in
            capture.record(req)
            return (HTTPURLResponse(
                url: req.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!, Data())
        }
        let client = makeClient()
        try await client.playPause(sessionId: "session-test")

        let url = try #require(capture.all().first?.url)
        #expect(url.path.hasSuffix("/Sessions/session-test/Playing/PlayPause"))
    }
}

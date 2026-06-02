import Foundation
import os

/// Configuration consumed by `JellyfinClient`. Plain value type so it can be
/// freely shared across actor isolation domains.
nonisolated struct JellyfinConfiguration: Sendable, Equatable {
    let baseURL: URL
    let apiKey: String
    let userId: String
    let allowSelfSigned: Bool

    init(baseURL: URL, apiKey: String, userId: String, allowSelfSigned: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userId = userId
        self.allowSelfSigned = allowSelfSigned
    }
}

/// Stateless REST client for a remote Jellyfin server. Performs single
/// requests and returns parsed models; polling, caching, and command policy
/// belong to higher layers (`PlaybackPoller`, `ArtworkCache`, `PlayerStore`).
///
/// Two URLSessions are kept for distinct timeout budgets (plan §2):
///  - `pollingSession`: 5s — used by `fetchSessions` on the polling loop.
///  - `controlSession`: 15s — used by `validateConnection`, `fetchArtwork`,
///    and the playback command endpoints.
nonisolated struct JellyfinClient: Sendable {
    let configuration: JellyfinConfiguration
    private let pollingSession: URLSession
    private let controlSession: URLSession

    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "networking"
    )

    /// Designated initializer. `protocolClasses` accepts custom `URLProtocol`
    /// subclasses so tests can inject `MockURLProtocol` without spinning up a
    /// real server.
    init(
        configuration: JellyfinConfiguration,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.configuration = configuration

        let trustDelegate: URLSessionDelegate? = configuration.allowSelfSigned
            ? TrustingURLSessionDelegate(expectedHost: configuration.baseURL.host)
            : nil

        let pollingConfig = URLSessionConfiguration.ephemeral
        pollingConfig.timeoutIntervalForRequest = 5
        pollingConfig.waitsForConnectivity = false
        if let protocolClasses {
            pollingConfig.protocolClasses = protocolClasses
        }
        self.pollingSession = URLSession(
            configuration: pollingConfig,
            delegate: trustDelegate,
            delegateQueue: nil
        )

        let controlConfig = URLSessionConfiguration.ephemeral
        controlConfig.timeoutIntervalForRequest = 15
        if let protocolClasses {
            controlConfig.protocolClasses = protocolClasses
        }
        self.controlSession = URLSession(
            configuration: controlConfig,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - Public API

    func validateConnection() async throws -> ServerInfo {
        try await get(Endpoints.systemInfo, session: controlSession)
    }

    func fetchSessions() async throws -> [Session] {
        try await get(Endpoints.sessions, session: pollingSession)
    }

    /// Fetch the primary artwork bytes for an item. The optional `tag` is the
    /// `ImageTags.Primary` field; including it lets us key the cache off the
    /// tag so server-side artwork changes propagate automatically (plan §4).
    /// Fetch the album cover as PNG so there are no JPEG ringing artefacts
    /// around lettering. `fillHeight=900` covers a 200pt artwork on a 3x
    /// retina display with a comfortable downsampling margin. PNG output is
    /// larger than a quality-95 JPEG but the disk cache amortises it.
    func fetchArtwork(
        itemId: String,
        tag: String?,
        fillHeight: Int = 900
    ) async throws -> Data {
        var components = URLComponents()
        components.path = Endpoints.itemPrimaryImage(itemId: itemId)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fillHeight", value: "\(fillHeight)"),
            URLQueryItem(name: "format", value: "Png"),
        ]
        if let tag {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = queryItems
        guard let relative = components.url,
              let absolute = URL(string: relative.relativeString, relativeTo: configuration.baseURL)?.absoluteURL
        else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: absolute)
        request.httpMethod = "GET"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Emby-Token")

        let (data, response) = try await send(request, on: controlSession)
        try validate(response)
        return data
    }

    /// Fetch an "instant mix" seeded from `seedItemId`: a list of tracks the
    /// server considers similar, scoped to the configured user. Returned items
    /// share the `NowPlayingItem` shape (Id/Name/Artists/ImageTags/…), so the
    /// queue panel can render them with the same row as the play queue.
    func fetchInstantMix(seedItemId: String, limit: Int = 30) async throws -> [NowPlayingItem] {
        var components = URLComponents()
        components.path = Endpoints.itemInstantMix(itemId: seedItemId)
        components.queryItems = [
            URLQueryItem(name: "userId", value: configuration.userId),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let relative = components.url,
              let absolute = URL(string: relative.relativeString, relativeTo: configuration.baseURL)?.absoluteURL
        else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: absolute)
        request.httpMethod = "GET"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, on: controlSession)
        try validate(response)
        do {
            return try Self.makeDecoder().decode(InstantMixEnvelope.self, from: data).items
        } catch {
            Self.logger.error("Decoding instant mix failed: \(String(describing: error), privacy: .public)")
            throw NetworkError.decodingFailed(String(describing: error))
        }
    }

    func playPause(sessionId: String) async throws {
        try await postNoContent(Endpoints.sessionPlayPause(sessionId: sessionId))
    }

    func nextTrack(sessionId: String) async throws {
        try await postNoContent(Endpoints.sessionNext(sessionId: sessionId))
    }

    func previousTrack(sessionId: String) async throws {
        try await postNoContent(Endpoints.sessionPrevious(sessionId: sessionId))
    }

    /// Tell the active client to seek to `positionTicks` (Jellyfin's
    /// 100 ns units). Used by the progress-bar tap-to-seek interaction.
    func seek(sessionId: String, positionTicks: Int64) async throws {
        var components = URLComponents()
        components.path = Endpoints.sessionSeek(sessionId: sessionId)
        components.queryItems = [
            URLQueryItem(name: "seekPositionTicks", value: "\(positionTicks)")
        ]
        guard let relative = components.url,
              let absolute = URL(string: relative.relativeString, relativeTo: configuration.baseURL)?.absoluteURL
        else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: absolute)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Emby-Token")
        let (_, response) = try await send(request, on: controlSession)
        try validate(response)
    }

    /// Tell the active client to play `itemIds`, starting at `startIndex`
    /// (`PlayNow`). Used by the queue popover to jump to a tapped track: we
    /// resend the whole queue so its order is preserved and the client resumes
    /// from the chosen index, rather than just playing one item in isolation.
    func play(sessionId: String, itemIds: [String], startIndex: Int) async throws {
        var components = URLComponents()
        components.path = Endpoints.sessionPlaying(sessionId: sessionId)
        components.queryItems = [
            URLQueryItem(name: "playCommand", value: "PlayNow"),
            URLQueryItem(name: "itemIds", value: itemIds.joined(separator: ",")),
            URLQueryItem(name: "startIndex", value: "\(startIndex)")
        ]
        guard let relative = components.url,
              let absolute = URL(string: relative.relativeString, relativeTo: configuration.baseURL)?.absoluteURL
        else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: absolute)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Emby-Token")
        let (_, response) = try await send(request, on: controlSession)
        try validate(response)
    }

    /// Set the active client's output volume to `volume` (0...100). Sent as a
    /// `SetVolume` general command, whose single argument Jellyfin expects as a
    /// string. Used by the overlay's scroll-to-change-volume interaction.
    func setVolume(sessionId: String, volume: Int) async throws {
        let clamped = min(100, max(0, volume))
        var request = try makeRequest(
            path: Endpoints.sessionCommand(sessionId: sessionId),
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = GeneralCommandBody(
            name: "SetVolume",
            arguments: ["Volume": "\(clamped)"]
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await send(request, on: controlSession)
        try validate(response)
    }

    /// Mark or clear the favorite flag for `itemId` on the configured user.
    /// Jellyfin uses `POST` to favorite and `DELETE` to un-favorite the item.
    /// Both return a `UserItemDataDto`; we decode the resulting `IsFavorite` so
    /// the caller can trust the server's view rather than its own optimistic
    /// guess. Falls back to the requested value if the body can't be decoded.
    @discardableResult
    func setFavorite(itemId: String, isFavorite: Bool) async throws -> Bool {
        let path = Endpoints.userFavoriteItem(
            userId: configuration.userId,
            itemId: itemId
        )
        let request = try makeRequest(
            path: path,
            method: isFavorite ? "POST" : "DELETE"
        )
        let (data, response) = try await send(request, on: controlSession)
        try validate(response)
        if let dto = try? Self.makeDecoder().decode(NowPlayingItem.UserData.self, from: data) {
            return dto.isFavorite ?? isFavorite
        }
        return isFavorite
    }

    /// Read the authoritative favorite state for `itemId`. Used on track change
    /// because `/Sessions` doesn't reliably include `UserData` on the
    /// `NowPlayingItem`, so the heart can't be seeded from the poll alone.
    func fetchFavorite(itemId: String) async throws -> Bool {
        let path = Endpoints.userItem(userId: configuration.userId, itemId: itemId)
        let item: ItemUserDataEnvelope = try await get(path, session: controlSession)
        return item.userData?.isFavorite ?? false
    }

    // MARK: - Internals

    /// Body for a Jellyfin `GeneralCommand` (`POST /Sessions/{id}/Command`).
    /// `Arguments` values are always strings on the wire, even for numbers.
    private struct GeneralCommandBody: Encodable {
        let name: String
        let arguments: [String: String]
        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case arguments = "Arguments"
        }
    }

    /// Decode target for an instant-mix query: a Jellyfin
    /// `BaseItemDtoQueryResult`, of which we only read the `Items` array.
    private struct InstantMixEnvelope: Decodable, Sendable {
        let items: [NowPlayingItem]
        enum CodingKeys: String, CodingKey {
            case items = "Items"
        }
    }

    /// Minimal decode target for `userItem`: we only care about `UserData`.
    private struct ItemUserDataEnvelope: Decodable, Sendable {
        let userData: NowPlayingItem.UserData?
        enum CodingKeys: String, CodingKey {
            case userData = "UserData"
        }
    }

    private func get<T: Decodable & Sendable>(
        _ path: String,
        session: URLSession
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await send(request, on: session)
        try validate(response)
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("Decoding \(T.self, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw NetworkError.decodingFailed(String(describing: error))
        }
    }

    private func postNoContent(_ path: String) async throws {
        let request = try makeRequest(path: path, method: "POST")
        let (_, response) = try await send(request, on: controlSession)
        try validate(response)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        // Append `path` to `baseURL` while tolerating either-trailing-slash
        // configurations. `URL.appendingPathComponent` collapses double slashes.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = configuration.baseURL.appendingPathComponent(trimmed)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(
        _ request: URLRequest,
        on session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // Funnel every URLSession failure through one mapper so raw
            // NSURLError dumps never reach the UI. Self-signed/TLS, offline,
            // and generic transport errors are classified there.
            throw NetworkError.from(error)
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport("Non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw NetworkError.unauthorized
        case 404:
            throw NetworkError.notFound
        default:
            throw NetworkError.serverError(http.statusCode)
        }
    }

    /// `JSONDecoder` is configured per call to keep `JellyfinClient` a value
    /// type without leaking mutable state. Cost is negligible compared to the
    /// network round-trip.
    /// Exposed at module-internal visibility so tests can decode fixtures with
    /// the same strategy as production. Not part of the public API.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Jellyfin emits ISO-8601 with or without fractional seconds. Try both.
        // `Date.ISO8601FormatStyle` is Sendable, so capturing it inside the
        // @Sendable custom-strategy closure is safe under strict concurrency.
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            let strategies: [Date.ISO8601FormatStyle] = [
                .init(includingFractionalSeconds: true),
                .init(includingFractionalSeconds: false),
            ]
            for strategy in strategies {
                if let date = try? strategy.parse(string) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised ISO-8601 date: \(string)"
            )
        }
        return decoder
    }
}

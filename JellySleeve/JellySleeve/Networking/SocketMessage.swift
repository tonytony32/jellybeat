import Foundation

/// Outgoing WebSocket message from JellySleeve to the Jellyfin server.
///
/// Jellyfin's protocol uses PascalCase keys (`MessageType`, `Data`). The
/// `Data` payload is a string in every outgoing message JellySleeve sends.
nonisolated struct OutgoingSocketMessage: Encodable, Sendable {
    let messageType: String
    let data: String?

    enum CodingKeys: String, CodingKey {
        case messageType = "MessageType"
        case data = "Data"
    }

    /// Subscribe to the `Sessions` stream. The data string is
    /// `"initialDelayMs,intervalMs"`. We use 0 / 1500 ms which matches the
    /// poller's default refresh rate but at server-side push frequency.
    static func sessionsStart(intervalMs: Int = 1500) -> Self {
        OutgoingSocketMessage(messageType: "SessionsStart", data: "0,\(intervalMs)")
    }

    static func sessionsStop() -> Self {
        OutgoingSocketMessage(messageType: "SessionsStop", data: nil)
    }

    static func keepAlive() -> Self {
        OutgoingSocketMessage(messageType: "KeepAlive", data: nil)
    }
}

/// Incoming WebSocket message from the Jellyfin server.
///
/// Only the message types JellySleeve actually consumes are modelled; every
/// other type collapses into `.other`.
nonisolated enum IncomingSocketMessage: Sendable {
    case sessions([Session])
    case keepAlive
    /// The server is asking the client to send `KeepAlive` more often. The
    /// associated value is the suggested interval in seconds.
    case forceKeepAlive(seconds: Int)
    case other(String)

    /// Decode an incoming payload using the same date strategy as the REST
    /// client so embedded `Session` objects parse identically.
    static func decode(_ data: Data) throws -> IncomingSocketMessage {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let decoder = JellyfinClient.makeDecoder()
        switch envelope.messageType {
        case "Sessions":
            let payload = try decoder.decode(SessionsPayload.self, from: data)
            return .sessions(payload.data)
        case "KeepAlive":
            return .keepAlive
        case "ForceKeepAlive":
            let payload = try decoder.decode(ForceKeepAlivePayload.self, from: data)
            return .forceKeepAlive(seconds: payload.data)
        default:
            return .other(envelope.messageType)
        }
    }

    private struct Envelope: Decodable {
        let messageType: String
        enum CodingKeys: String, CodingKey { case messageType = "MessageType" }
    }

    private struct SessionsPayload: Decodable {
        let data: [Session]
        enum CodingKeys: String, CodingKey { case data = "Data" }
    }

    private struct ForceKeepAlivePayload: Decodable {
        let data: Int
        enum CodingKeys: String, CodingKey { case data = "Data" }
    }
}

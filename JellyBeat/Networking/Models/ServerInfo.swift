import Foundation

/// Subset of `/System/Info` used by the connection-validation flow (plan §4).
nonisolated struct ServerInfo: Codable, Sendable, Equatable {
    let id: String
    let serverName: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
    }
}

import Foundation

/// Subset of the `PlayState` field embedded inside a `Session` (plan §4).
nonisolated struct PlayState: Codable, Sendable, Equatable {
    let positionTicks: Int64?
    let isPaused: Bool?
    let volumeLevel: Int?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case volumeLevel = "VolumeLevel"
    }
}

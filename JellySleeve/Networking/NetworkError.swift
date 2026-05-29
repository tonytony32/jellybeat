import Foundation

/// Errors surfaced by `JellyfinClient`. Mapped from HTTP status codes,
/// `URLError`s, and decoding failures.
///
/// `unauthorized` is special: callers must stop polling on this error per
/// plan §5.2.
nonisolated enum NetworkError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case unauthorized
    case notFound
    case serverError(Int)
    case decodingFailed(String)
    case transport(String)
    case selfSignedCert

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The base URL or path is malformed."
        case .unauthorized:
            return "The Jellyfin server rejected the API key."
        case .notFound:
            return "The requested resource was not found on the server."
        case .serverError(let code):
            return "The Jellyfin server returned HTTP \(code)."
        case .decodingFailed(let detail):
            return "Failed to decode the server response: \(detail)"
        case .transport(let detail):
            return "Network transport error: \(detail)"
        case .selfSignedCert:
            return "The server presented a certificate that is not trusted by the system."
        }
    }
}

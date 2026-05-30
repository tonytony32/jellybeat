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
    /// The device has no network path at all (Wi-Fi off, airplane mode). Kept
    /// distinct from `.transport` so the UI can say "you're offline" rather
    /// than "the server is unreachable".
    case offline
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
            return detail
        case .offline:
            return "No internet connection."
        case .selfSignedCert:
            return "The server presented a certificate that is not trusted by the system."
        }
    }

    /// True when the error is a connectivity problem that retrying might heal
    /// (the server is down, the network blipped, or the device is offline) as
    /// opposed to a hard configuration/auth failure.
    var isConnectivity: Bool {
        switch self {
        case .transport, .offline:
            return true
        case .invalidURL, .unauthorized, .notFound, .serverError,
             .decodingFailed, .selfSignedCert:
            return false
        }
    }

    /// Map any thrown error into a `NetworkError` carrying *user-facing* copy.
    /// This is the single chokepoint that stops raw `NSError`/`URLError`
    /// descriptions (the `Error Domain=NSURLErrorDomain Code=-1004 …
    /// UserInfo={…}` dumps) from ever reaching the overlay. Anything that isn't
    /// already a `NetworkError` or a recognised `URLError` collapses to a
    /// generic, friendly transport message.
    static func from(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }
        guard let urlError = error as? URLError else {
            return .transport("Couldn't reach the server.")
        }
        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateHasBadDate:
            return .selfSignedCert
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            // Everything else (host unreachable, DNS, timeout, connection lost,
            // TLS handshake blip, …) is a "couldn't reach the server" condition
            // that the poller retries.
            return .transport("Couldn't reach the server.")
        }
    }
}

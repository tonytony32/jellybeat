import Foundation
import Testing
@testable import JellySleeve

/// `NetworkError.from(_:)` is the single chokepoint that stops raw NSURLError
/// dumps (`Error Domain=NSURLErrorDomain Code=-1004 … UserInfo={…}`) from ever
/// reaching the overlay. These tests pin the classification and, crucially,
/// that no user-facing string leaks NSError internals.
struct NetworkErrorTests {
    @Test
    func mapsNoInternetToOffline() {
        let mapped = NetworkError.from(URLError(.notConnectedToInternet))
        #expect(mapped == .offline)
    }

    @Test
    func mapsUnreachableServerToTransport() {
        for code in [URLError.Code.cannotConnectToHost,
                     .cannotFindHost,
                     .timedOut,
                     .networkConnectionLost,
                     .dnsLookupFailed] {
            let mapped = NetworkError.from(URLError(code))
            #expect(mapped == .transport("Couldn't reach the server."))
            #expect(mapped.isConnectivity)
        }
    }

    @Test
    func mapsCertificateErrorsToSelfSigned() {
        for code in [URLError.Code.serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid,
                     .serverCertificateHasBadDate] {
            #expect(NetworkError.from(URLError(code)) == .selfSignedCert)
        }
    }

    @Test
    func passesThroughExistingNetworkError() {
        #expect(NetworkError.from(NetworkError.unauthorized) == .unauthorized)
    }

    @Test
    func mapsUnknownErrorToFriendlyTransport() {
        struct Weird: Error {}
        let mapped = NetworkError.from(Weird())
        #expect(mapped == .transport("Couldn't reach the server."))
    }

    /// The whole point: a real URLError carries a gnarly `localizedDescription`
    /// /`debugDescription`, but the message we surface must be clean.
    @Test
    func neverLeaksRawNSURLErrorInternals() {
        let raw = URLError(.cannotConnectToHost)
        let message = NetworkError.from(raw).errorDescription ?? ""
        #expect(!message.contains("NSURLErrorDomain"))
        #expect(!message.contains("UserInfo"))
        #expect(!message.contains("kCFStream"))
        #expect(message == "Couldn't reach the server.")
    }

    /// Connectivity errors are retryable; auth/cert/decoding are not.
    @Test
    func connectivityClassification() {
        #expect(NetworkError.transport("x").isConnectivity)
        #expect(NetworkError.offline.isConnectivity)
        #expect(!NetworkError.unauthorized.isConnectivity)
        #expect(!NetworkError.selfSignedCert.isConnectivity)
        #expect(!NetworkError.serverError(500).isConnectivity)
    }
}

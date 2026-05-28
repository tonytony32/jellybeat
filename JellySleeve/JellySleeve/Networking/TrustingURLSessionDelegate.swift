import Foundation

/// URLSession delegate that opts into trusting self-signed TLS certificates.
///
/// Only enabled when `JellyfinConfiguration.allowSelfSigned == true`. Plan §8
/// risk table documents this as the canonical mitigation for Tailscale/Caddy
/// setups where the server presents an internal CA cert.
///
/// The delegate is intentionally stateless; URLSession invokes the callback on
/// its own internal queue but we never mutate anything, so `@unchecked
/// Sendable` is safe here.
final class TrustingURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedHost: String?

    init(expectedHost: String?) {
        self.expectedHost = expectedHost
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // If a host is configured, only override trust for that host. Defence
        // against accidentally trusting a different unrelated MITM.
        if let expectedHost, challenge.protectionSpace.host != expectedHost {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

import AppKit
import Foundation
import Testing
@testable import JellyBeat

/// Tests for `ArtworkView.retryingFetch`, the policy deciding how hard we try
/// before accepting that an item has no cover.
///
/// The covers this guards are the direct-URL ones (the YouTube bridge's).
/// They're cached nowhere — unlike Jellyfin's, which `ArtworkCache` keeps on
/// disk — and the load only re-runs when the track changes. So a single
/// swallowed failure used to leave a track coverless for as long as it stayed
/// on screen, which is exactly what a *stopped* track does.
@MainActor
struct ArtworkRetryTests {
    /// Zero delays: the schedule's shape is what's under test, not the waiting.
    private static let instant: [TimeInterval] = [0, 0]

    @Test
    func succeedsOnTheFirstAttemptWithoutRetrying() async {
        var attempts = 0
        let result = await ArtworkView.retryingFetch(backoff: Self.instant) {
            attempts += 1
            return NSImage()
        }
        #expect(result != nil)
        #expect(attempts == 1)
    }

    /// The case that motivated this: a blip on the first try must not cost the
    /// cover for the rest of the track's time on screen.
    @Test
    func retriesUntilTheFetchSucceeds() async {
        var attempts = 0
        let result = await ArtworkView.retryingFetch(backoff: Self.instant) {
            attempts += 1
            return attempts < 3 ? nil : NSImage()
        }
        #expect(result != nil)
        #expect(attempts == 3)
    }

    /// Exhausting the schedule is a definitive "no cover". The caller applies
    /// that nil, clearing the previous track's artwork instead of leaving it
    /// stranded under the new track's metadata.
    @Test
    func givesUpAfterTheScheduleIsExhausted() async {
        var attempts = 0
        let result = await ArtworkView.retryingFetch(backoff: Self.instant) {
            attempts += 1
            return nil
        }
        #expect(result == nil)
        #expect(attempts == Self.instant.count + 1)
    }

    /// An empty schedule is one attempt, not zero and not two — the loop bound
    /// is off-by-one bait.
    @Test
    func emptyScheduleMakesASingleAttempt() async {
        var attempts = 0
        _ = await ArtworkView.retryingFetch(backoff: []) {
            attempts += 1
            return nil
        }
        #expect(attempts == 1)
    }
}

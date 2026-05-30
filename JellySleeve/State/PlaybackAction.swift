import Foundation

/// Transport action vocabulary shared between `PlayerStore` (which records the
/// last-dispatched action for the on-overlay flash) and the UI controls that
/// trigger it.
///
/// Lives in the domain layer so `PlayerStore` doesn't have to reach up into a
/// view type (`ControlsView`) to name its own command feedback. The UI maps
/// these cases to icons/labels on its side of the boundary.
nonisolated enum PlaybackAction: Hashable, Sendable {
    case previous
    case playPause
    case next
}

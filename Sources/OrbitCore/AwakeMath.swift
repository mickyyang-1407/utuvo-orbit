import Foundation

// MARK: - Awake deadline math
//
// The live AwakeBackend records a real wall-clock deadline. UI must compute the
// remaining time from that deadline (not by guessing a decrement) so a paused
// runloop, suspend, or DST jump never lies to the user.

public enum AwakeMath {
    public enum Status: Equatable, Sendable {
        case inactive
        case active(remaining: TimeInterval)
        case expired
    }

    public static func status(state: AwakeState, now: Date) -> Status {
        guard state.isActive else { return .inactive }
        guard let deadline = state.deadline else { return .inactive }
        let remaining = deadline.timeIntervalSince(now)
        if remaining < 0 { return .expired }
        return .active(remaining: remaining)
    }

    /// Returns a "MM:SS" countdown string. Returns "—" for inactive states.
    public static func countdownLabel(state: AwakeState, now: Date) -> String {
        switch status(state: state, now: now) {
        case .inactive: return "—"
        case .expired: return "已到期"
        case .active(let remaining):
            let total = max(0, Int(remaining.rounded()))
            let minutes = total / 60
            let seconds = total % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Choose the next state when the caller polls. The backend itself is
    /// authoritative for IOPMAssertion lifecycle; this helper only translates
    /// the expired-but-still-active case into a UI hint.
    public static func reconcile(state: AwakeState, now: Date) -> AwakeState {
        switch status(state: state, now: now) {
        case .expired:
            var copy = state
            copy.isActive = false
            copy.deadline = nil
            return copy
        default:
            return state
        }
    }
}

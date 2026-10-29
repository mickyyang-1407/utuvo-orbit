import Foundation

/// A monotonic deadline, including time spent asleep. No timers or OS effects.
public struct OrbitCountdown: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, running, paused, finished }
    public private(set) var phase: Phase = .idle
    public private(set) var total: Double = 0
    public private(set) var remaining: Double = 0
    private var deadline: Double?
    public init() {}

    @discardableResult
    public mutating func start(seconds: Double, now: Double) -> Bool {
        guard seconds.isFinite, now.isFinite, seconds > 0, seconds <= 7200 else { return false }
        total = seconds; remaining = seconds; deadline = now + seconds; phase = .running
        return true
    }

    /// Returns true exactly once per completed run.
    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        guard phase == .running, let deadline, now.isFinite else { return false }
        remaining = max(0, min(total, deadline - now))
        if remaining == 0 { phase = .finished; self.deadline = nil; return true }
        return false
    }

    public mutating func pause(now: Double) {
        tick(now: now)
        guard phase == .running else { return }
        phase = .paused; deadline = nil
    }

    public mutating func resume(now: Double) {
        guard phase == .paused, now.isFinite else { return }
        deadline = now + remaining; phase = .running
    }

    public mutating func reset() { self = OrbitCountdown() }
}

import Foundation

// MARK: - Pure value transforms used by the live monitor + fakes
//
// Every helper here is `static`, has no Foundation side effects beyond
// allocations, and only consumes its arguments. This keeps it directly callable
// from XCTest with fixture data.

public enum AudioMath {
    /// Clamp to 0...1 preserving NaN/infinite as `nil`.
    public static func clamp(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    /// Convert 0...1 into 0...4 dot count (UI display only).
    public static func dots(for volume: Double?, muted: Bool) -> Int? {
        if muted { return 0 }
        guard let v = clamp(volume) else { return nil }
        return Int(ceil(v * 4))
    }

    /// Human-readable label matching the original StatusSnapshot conventions.
    public static func label(available: Bool?, muted: Bool, volume: Double?) -> String {
        guard let available else { return "讀取中" }
        guard available else { return "無輸出" }
        if muted { return "靜音" }
        return StatusSnapshot.percent(volume) ?? "由裝置控制"
    }
}

public enum NetworkMath {
    public struct Delta: Equatable, Sendable {
        /// Bytes/sec download. `nil` means "no valid delta" — the UI should
        /// render "—" until we have a clean second of samples.
        public var downloadBytesPerSecond: Double?
        public var uploadBytesPerSecond: Double?
        public var interfaceChanged: Bool
        public var reset: Bool
    }

    /// Produce a delta between two readings using monotonic seconds so paused
    /// runloops / wake-from-sleep / DST jumps never corrupt throughput.
    /// `previous == nil`, interface change, offline, an invalid counter read
    /// (on either side — a read failure now can't be masked by a stale-but-
    /// valid previous sample), counter rollback and non-monotonic deltas all
    /// return `.reset == true` so the UI shows "—" until the next clean
    /// sample. A genuinely valid zero-traffic reading still yields `0`, not
    /// a reset — validity and "no traffic" are different things.
    public static func delta(previous: NetworkReading?, current: NetworkReading) -> Delta {
        // `previous.interfaceName == current.interfaceName` alone lets
        // `nil == nil` pass as "same interface" — i.e. two readings that
        // both have NO known interface would otherwise be treated as a
        // valid, unchanged route instead of "we don't know," and (with
        // matching monotonic timestamps) could produce a spurious 0 B/s
        // instead of a reset. Require an actual non-empty name on both
        // sides before comparing them.
        guard let previous,
              let previousInterface = previous.interfaceName, !previousInterface.isEmpty,
              let currentInterface = current.interfaceName, !currentInterface.isEmpty,
              previousInterface == currentInterface,
              previous.interfaceType == current.interfaceType,
              current.isReachable, previous.isReachable,
              current.countersValid, previous.countersValid else {
            return Delta(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                         interfaceChanged: previous != nil, reset: true)
        }
        let interval = current.monotonicSeconds - previous.monotonicSeconds
        // Wake / DST / paused runloop / back-dated NTP can all produce a
        // near-zero or negative interval — treat anything under 0.5s as a
        // reset so we never divide by zero or produce spurious spikes.
        // Symmetrically, a gap over 10s (missed poll, suspended app, real
        // sleep now that the clock keeps ticking through sleep) would average
        // a burst of traffic across the whole gap and print a misleadingly
        // smoothed rate — treat that as a reset too so the UI shows "—"
        // until the next clean consecutive pair of samples.
        guard interval >= 0.5, interval <= 10 else {
            return Delta(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                         interfaceChanged: false, reset: true)
        }
        if current.receivedBytes < previous.receivedBytes || current.sentBytes < previous.sentBytes {
            return Delta(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                         interfaceChanged: false, reset: true)
        }
        let down = Double(current.receivedBytes - previous.receivedBytes) / interval
        let up = Double(current.sentBytes - previous.sentBytes) / interval
        // No artificial ceiling — a real multi-gigabit link should show its
        // real number rather than a lie clamped to some "generous" cap.
        let clamp: (Double) -> Double? = { v in
            guard v.isFinite, v >= 0 else { return nil }
            return v
        }
        return Delta(downloadBytesPerSecond: clamp(down), uploadBytesPerSecond: clamp(up),
                     interfaceChanged: false, reset: false)
    }

    /// Compact human-readable bytes/sec string. "—" for `nil`.
    public static func format(bytesPerSecond: Double?) -> String {
        guard let v = bytesPerSecond, v.isFinite, v >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB"]
        var value = v
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return String(format: "%.0f %@/s", value, units[unit]) }
        return String(format: "%.1f %@/s", value, units[unit])
    }
}

public enum MemoryMath {
    /// Used/total sanity bound. Returns nil when either side is missing, zero,
    /// or the ratio lies outside 0...1.05 (a tiny upper tolerance accounts for
    /// OS rounding where `used` momentarily exceeds `total`).
    public static func fraction(used: UInt64?, total: UInt64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        let ratio = Double(used) / Double(total)
        guard ratio.isFinite, ratio >= 0, ratio <= 1.05 else { return nil }
        return min(1, ratio)
    }

    /// Human label for a byte quantity.
    public static func label(bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return String(format: "%.0f %@", value, units[unit]) }
        return String(format: "%.1f %@", value, units[unit])
    }
}

public enum CPUHistory {
    public static func append(_ history: [Double], sample: Double?, capacity: Int) -> [Double] {
        guard let sample, sample.isFinite else { return history }
        var copy = history
        copy.append(min(1, max(0, sample)))
        if copy.count > capacity { copy.removeFirst(copy.count - capacity) }
        return copy
    }

    /// Mean of the supplied window, treating nil samples as 0.
    public static func mean(_ history: [Double]) -> Double? {
        guard !history.isEmpty else { return nil }
        return history.reduce(0, +) / Double(history.count)
    }
}

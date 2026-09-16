import Foundation

// MARK: - Pure glyph content decisions
//
// Kept separate from any rendering so both the combined and classic glyph
// renderers (and tests) share one source of truth for "what does the center
// number / degraded state actually mean right now."

/// Where a resolved percent numeral came from — purely informational, used
/// for AX/tooltip wording ("CPU 24%" vs a plain battery percent).
public enum PercentSource: Equatable, Sendable {
    case laptopBattery, desktopCPU
}

public enum CenterContentKind: Equatable, Sendable {
    case network
    case percent(value: Double, source: PercentSource)
}

public enum CenterContent {
    /// Resolve what the glyph center actually shows. Never derived blindly
    /// from `StatusSnapshot.ringFraction` — desktop `.power` returns a
    /// synthetic `1` there (a full decorative arc), not a real "100%"
    /// measurement, so it must not become a percent numeral. Only a laptop's
    /// own valid battery fraction, or a desktop's valid CPU usage when the
    /// ring is explicitly showing CPU, ever produce a numeral. Desktop
    /// `.power`/`.hidden`, unknown machine, and any non-finite value fall
    /// back to `.network` — the same content shown when the user has not
    /// opted into percent mode at all. A genuinely valid `0` or `1` (0%/100%)
    /// is preserved, never treated as "missing".
    public static func resolve(snapshot: StatusSnapshot, desktopRing: DesktopRing, ringCenter: RingCenter) -> CenterContentKind {
        guard ringCenter == .percent else { return .network }
        switch snapshot.machine {
        case .laptop:
            // The charging bolt lives in the top slot above the ring;
            // showing a percent numeral in the center at the same time was
            // not legible at a real 27pt render (checked via
            // `--export-glyphs`, not claimed from a mockup). Falling back
            // to the network center while charging preserves the charging
            // indicator instead of crowding both into one small glyph.
            if snapshot.battery?.charging == true { return .network }
            // Reject, never clamp: a `-0.01` or `1.01` is not a real
            // measurement that happens to be slightly off — it's invalid
            // input, and clamping it into range would print a fake "0%"/
            // "100%" as if it were a genuine reading.
            guard let fraction = snapshot.battery?.fraction, fraction.isFinite, fraction >= 0, fraction <= 1 else { return .network }
            return .percent(value: fraction, source: .laptopBattery)
        case .desktop:
            guard desktopRing == .cpu, let cpu = snapshot.cpu, cpu.isFinite, cpu >= 0, cpu <= 1 else { return .network }
            return .percent(value: cpu, source: .desktopCPU)
        case .unknown:
            return .network
        }
    }
}

/// A concrete, explainable reason the glyph should show a degraded/attention
/// cue. Every case has a strict, narrow trigger — no reason ever fires from
/// an "unknown" reading, only from a positively confirmed bad state.
public enum AttentionReason: String, Equatable, Sendable, CaseIterable {
    case offline
    case lowBattery
    case noAudioOutput

    public var localizedTitle: String {
        switch self {
        case .offline: return "網路離線"
        case .lowBattery: return "電量偏低"
        case .noAudioOutput: return "無可用音訊輸出"
        }
    }
}

public enum AttentionAnalysis {
    /// - `offline`: only `Connection.offline` — `.checking` (still reading)
    ///   is NOT a reason, it is unknown, not bad.
    /// - `lowBattery`: laptop only, a genuinely valid (finite) fraction
    ///   `<= 0.10`, AND not charging, AND not on AC power — "not charging"
    ///   alone does not mean "not plugged in" (on AC but paused/topped off).
    /// - `noAudioOutput`: only an explicit `hasAudioOutput == false`. `nil`
    ///   (still reading), a device-controlled volume (`nil`), and a user's
    ///   own mute are never treated as a failure.
    public static func reasons(snapshot: StatusSnapshot) -> [AttentionReason] {
        var reasons: [AttentionReason] = []
        if snapshot.connection == .offline { reasons.append(.offline) }
        if snapshot.machine == .laptop,
           let battery = snapshot.battery,
           let fraction = battery.fraction, fraction.isFinite, fraction >= 0, fraction <= 0.10,
           !battery.charging, !battery.onAC {
            reasons.append(.lowBattery)
        }
        if snapshot.hasAudioOutput == false { reasons.append(.noAudioOutput) }
        return reasons
    }

    public static func isDegraded(snapshot: StatusSnapshot) -> Bool {
        !reasons(snapshot: snapshot).isEmpty
    }
}

/// Truthful volume display state — separate from the raw `StatusSnapshot`
/// fields because those alone let a device that just went `hasAudioOutput
/// == false` keep showing a STALE `volume`/`muted` reading from before it
/// lost output (proven: a classic-allbad render with `hasAudioOutput ==
/// false` still showed 3 filled dots). `hasAudioOutput` is checked FIRST,
/// before either muted or volume is even consulted, so a stale level can
/// never leak through.
public enum VolumeDisplayState: Equatable, Sendable {
    /// 0...4, muted counts as 0 dots but is a distinguishable, separate
    /// fact the caller can still render its own mute cue for.
    case level(dots: Int, muted: Bool)
    /// `hasAudioOutput == false` — confirmed no output device at all.
    case unavailable
    /// `hasAudioOutput == nil` (still reading), or output is available but
    /// the volume itself is unreadable (device-controlled, `nil`/non-finite).
    case unknown
}

public enum VolumeDisplay {
    public static func resolve(hasAudioOutput: Bool?, muted: Bool, volume: Double?) -> VolumeDisplayState {
        guard let hasAudioOutput else { return .unknown }
        guard hasAudioOutput else { return .unavailable }
        if muted { return .level(dots: 0, muted: true) }
        guard let volume, volume.isFinite, volume >= 0, volume <= 1 else { return .unknown }
        return .level(dots: Int(ceil(volume * 4)), muted: false)
    }
}

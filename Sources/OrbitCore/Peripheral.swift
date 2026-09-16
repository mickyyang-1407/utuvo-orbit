import Foundation

// MARK: - Peripheral model (pure value types + protocol)
//
// Read-only, best-effort battery reporting for connected peripherals
// (AirPods/keyboard/trackpad/mouse/iPhone/other). Only ever reflects what
// the OS already exposes — never a guess, never a default 100%, never an
// inferred charging state.

public enum PeripheralKind: String, Sendable, Codable, CaseIterable, Equatable {
    case airpods, keyboard, trackpad, mouse, iphone, other
}

/// `Bool` cannot express "the OS didn't tell us" — this can.
public enum ChargingState: String, Sendable, Codable, Equatable {
    case unknown, charging, notCharging
}

public struct Peripheral: Equatable, Sendable, Codable, Identifiable {
    /// Stable runtime identity (e.g. an IORegistry entry id/path-derived
    /// string) — NEVER the device name alone, which can be user-renamed and
    /// duplicated across devices.
    public var id: String
    public var name: String
    public var kind: PeripheralKind
    /// 0...1, `nil` when unknown/unreadable. Only a finite, in-range value
    /// is ever accepted — see `init`.
    public var fraction: Double?
    public var charging: ChargingState
    /// Diagnostic: which read path produced this (e.g.
    /// "AppleDeviceManagementHIDEventService", "IOPS"), for `--diagnose`.
    public var source: String
    /// Diagnostic note when a read partially failed (e.g. "缺少電量欄位");
    /// nil when nothing noteworthy happened.
    public var statusNote: String?

    public init(id: String, name: String, kind: PeripheralKind, fraction: Double?,
                charging: ChargingState, source: String, statusNote: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        // Accept only real, finite, in-range data — never clamp a garbage
        // value into range (that would look like a real reading).
        if let fraction, fraction.isFinite, fraction >= 0, fraction <= 1 {
            self.fraction = fraction
        } else {
            self.fraction = nil
        }
        self.charging = charging
        self.source = source
        self.statusNote = statusNote
    }
}

/// Distinguishes "the read subsystem itself is unavailable/failed" from a
/// truthful empty `currentPeripherals()` result (queried fine, nothing
/// attached) — without this, `--diagnose` cannot tell "no readable device"
/// apart from "the source failed" when both produce an empty list.
public struct PeripheralReadStatus: Equatable, Sendable, Codable {
    public var available: Bool
    public var errorNote: String?
    public init(available: Bool, errorNote: String? = nil) {
        self.available = available
        self.errorNote = errorNote
    }
}

public protocol PeripheralBackend: AnyObject, Sendable {
    /// Snapshot of currently-visible peripherals with any battery data. An
    /// empty array is a truthful "none found/none readable", not an error.
    func currentPeripherals() -> [Peripheral]
    /// Defaults to `.init(available: true)` — backends with no meaningful
    /// distinction (fakes) never need to override this.
    func readStatus() -> PeripheralReadStatus
}

public extension PeripheralBackend {
    func readStatus() -> PeripheralReadStatus { PeripheralReadStatus(available: true) }
}

public enum PeripheralList {
    /// De-dup by stable `id`. A conflict (same `id` read more than once in
    /// one pass) previously kept whichever occurrence came first regardless
    /// of content — which is NOT deterministic in any meaningful sense when
    /// one reading is genuine data and the other is unknown/invalid for the
    /// SAME device: which one "wins" depended entirely on incidental read
    /// order. Now a conflict always prefers the occurrence with known valid
    /// data over an unknown one; among occurrences that agree on
    /// known-vs-unknown, the first occurrence wins (a real, stable tie
    /// rule, not an accident of order). Then sorted: known fraction
    /// ascending (0 is lowest, ties broken by `id`), all unknown-fraction
    /// entries last (ordered by `id` among themselves). Capped at `limit`,
    /// and because known entries are ordered first, trimming always drops
    /// unknowns before knowns. An all-unknown list is still returned (up to
    /// `limit`), never collapsed to empty.
    public static func dedupedSorted(_ items: [Peripheral], limit: Int = 4) -> [Peripheral] {
        var bestByID: [String: Peripheral] = [:]
        var order: [String] = []
        for item in items {
            if let existing = bestByID[item.id] {
                if existing.fraction == nil && item.fraction != nil {
                    bestByID[item.id] = item
                }
                // else: existing already known-valid, or both agree — first
                // occurrence's content stands, per the stable-tie rule.
            } else {
                bestByID[item.id] = item
                order.append(item.id)
            }
        }
        let unique = order.compactMap { bestByID[$0] }
        let known = unique.filter { $0.fraction != nil }.sorted { a, b in
            let fa = a.fraction ?? 0, fb = b.fraction ?? 0
            if fa != fb { return fa < fb }
            return a.id < b.id
        }
        let unknown = unique.filter { $0.fraction == nil }.sorted { $0.id < $1.id }
        return Array((known + unknown).prefix(max(0, limit)))
    }
}

/// In-memory fake for gallery/fixture/test use — never touches IOKit.
public final class FakePeripheralBackend: PeripheralBackend, @unchecked Sendable {
    private let box: Box<[Peripheral]>
    public init(peripherals: [Peripheral] = []) { box = Box(peripherals) }
    public func currentPeripherals() -> [Peripheral] { box.read { $0 } }
    public func update(_ peripherals: [Peripheral]) { box.mutate { $0 = peripherals } }
}

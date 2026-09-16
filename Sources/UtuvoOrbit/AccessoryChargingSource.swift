import Foundation
import OrbitCore

// MARK: - AccessoryChargingSource
//
// ORBIT-004 C: root's own verified evidence (docs/ORBIT-004-CHARGING-EVIDENCE.md,
// citing apple-oss-distributions/PowerManagement's pmset.m directly) —
// `/usr/bin/pmset -g accps -xml` is a public, fixed-argument system CLI (no
// private framework/API) that reports per-accessory `Is Charging`/
// `Is Present`/`Type`/`Accessory Identifier` as CFBoolean/String-typed
// plist fields. Root confirmed on this Mac: the CURRENT HID device's own
// `SerialNumber` (from `AppleDeviceManagementHIDEventService`) matches
// pmset's own `Accessory Identifier` EXACTLY for both a keyboard
// (charging=true) and a trackpad (USB, charging=false — proving USB must
// NOT be treated as charging). A SEPARATE, differently-identified legacy
// Bluetooth alias entry for the same physical devices also exists in
// pmset's output with `Is Charging` as an INTEGER (not CFBoolean) — that
// entry is deliberately never usable here: only an EXACT identifier match
// with a genuine CFBoolean value, on a genuine `Type == "Accessory
// Source"` entry, ever resolves to charging/not-charging.

/// One accessory entry from pmset's `-g accps -xml` output, after strict
/// type validation — a record only exists here if it is a genuine
/// `Type == "Accessory Source"` entry; `Is Charging`/`Is Present` are only
/// ever `Bool` if they were a genuine CFBoolean, never coerced.
struct AccessoryChargingRecord: Equatable {
    let identifier: String
    let isPresent: Bool?
    let isCharging: Bool?
}

enum AccessoryChargingParser {
    /// pmset's `-xml` output is SEVERAL concatenated `<plist>...</plist>`
    /// documents back to back — not one array — so this scans for each
    /// `<plist ...>...</plist>` span and parses them independently. A
    /// malformed/truncated span is skipped, never fails the whole parse.
    /// Non-accessory entries (missing/wrong `Type`) are dropped entirely —
    /// never recorded as a possible charging-match candidate at all.
    static func parseAccessories(_ data: Data) -> [AccessoryChargingRecord] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var records: [AccessoryChargingRecord] = []
        var searchStart = text.startIndex
        while let openRange = text.range(of: "<plist", range: searchStart..<text.endIndex) {
            guard let closeRange = text.range(of: "</plist>", range: openRange.upperBound..<text.endIndex) else { break }
            let docText = text[openRange.lowerBound..<closeRange.upperBound]
            guard let docData = String(docText).data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: docData, format: nil),
                  let dict = plist as? [String: Any],
                  let identifier = dict["Accessory Identifier"] as? String, !identifier.isEmpty,
                  (dict["Type"] as? String) == "Accessory Source" else {
                // This span didn't parse (or isn't an accessory source at
                // all) — advance past just the OPEN tag, not the whole
                // (possibly bogus) span, so a well-formed document whose
                // own `<plist>` happens to fall inside what looked like one
                // bad span is still found on the next pass, instead of
                // being silently swallowed along with the genuinely
                // malformed one.
                searchStart = openRange.upperBound
                continue
            }
            searchStart = closeRange.upperBound
            records.append(AccessoryChargingRecord(
                identifier: normalize(identifier),
                isPresent: strictBool(dict["Is Present"]),
                isCharging: strictBool(dict["Is Charging"])
            ))
        }
        return records
    }

    /// EXACTLY 6 groups of 2 hex digits, separated uniformly by `:` or
    /// `-`. Only identifiers matching this precise shape get separator/case
    /// normalization.
    static func isMACShaped(_ s: String) -> Bool {
        for separator: Character in [":", "-"] {
            let groups = s.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count == 6 else { continue }
            if groups.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) { return true }
        }
        return false
    }

    /// Root's correction: separator/case normalization is only valid for a
    /// POSITIVELY RECOGNIZED MAC-address shape (confirmed for both live
    /// devices on this Mac) — an ARBITRARY serial's punctuation may be
    /// semantically significant, so it compares via its EXACT TRIMMED
    /// string only ("A-B" must never collide with "AB").
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMACShaped(trimmed) else { return trimmed }
        return trimmed.lowercased().filter(\.isHexDigit)
    }

    /// Accepts ONLY a genuine CFBoolean — an `Int(1)`/`Int(0)` or a string
    /// `"true"` plist value must be rejected, not coerced, mirroring the
    /// EXACT distinction `LivePeripheralBackend.numericValue` makes in the
    /// opposite direction (there: reject CFBoolean; here: accept ONLY
    /// CFBoolean). Root's own evidence: a legacy alias entry reports
    /// `Is Charging` as an INTEGER, which must never read as true.
    static func strictBool(_ any: Any?) -> Bool? {
        guard let any else { return nil }
        let ref = any as CFTypeRef
        guard CFGetTypeID(ref) == CFBooleanGetTypeID() else { return nil }
        return any as? Bool
    }
}

enum AccessoryChargingMatcher {
    /// Resolves to `.charging`/`.notCharging` ONLY when EXACTLY ONE parsed
    /// record's normalized identifier matches one of the device's own
    /// candidate tokens (each token normalized the SAME way — MAC-shaped
    /// tokens fold case/separators, arbitrary ones compare exact-trimmed),
    /// AND that record has `isPresent == true` and a genuine (non-nil)
    /// `isCharging`. Any ambiguity — zero matches, multiple conflicting
    /// matches, not present, or a missing/wrong-typed `Is Charging` —
    /// resolves to `.unknown`, never guessed. `IsCharged` is deliberately
    /// never consulted: a full/topped-off battery that isn't actively
    /// drawing charge current is `.notCharging`, not `.charging`.
    static func resolve(candidateTokens: [String], records: [AccessoryChargingRecord]) -> ChargingState {
        let normalizedTokens = Set(candidateTokens.map(AccessoryChargingParser.normalize).filter { !$0.isEmpty })
        guard !normalizedTokens.isEmpty else { return .unknown }
        let matches = records.filter { normalizedTokens.contains($0.identifier) }
        guard matches.count == 1, let match = matches.first else { return .unknown }
        guard match.isPresent == true, let isCharging = match.isCharging else { return .unknown }
        return isCharging ? .charging : .notCharging
    }
}

/// Runs the actual `pmset` read — isolated behind a protocol so tests
/// inject a fake implementation and never launch a real process.
protocol AccessoryChargingExecutor: Sendable {
    /// Returns raw stdout bytes, or `nil` on failure/timeout/nonzero
    /// exit/truncated or incomplete output. The bound on the CALLING thread
    /// is `timeout` plus a bounded cleanup grace (up to 2s to escalate
    /// SIGTERM→SIGKILL on a timeout, and up to 1s waiting for the reader's
    /// EOF) — not `timeout` alone. `LivePeripheralBackend` only ever calls
    /// this from a background queue, never from the coordinator's
    /// main-actor poll.
    func run(timeout: TimeInterval) -> Data?
}

/// Fixed binary path, fixed arguments (no shell) — a public, documented
/// system CLI, not a private framework call.
struct PMSetAccessoryChargingExecutor: AccessoryChargingExecutor {
    static let maxBytes = 256 * 1024

    /// Appends as much of `chunk` as fits and reports whether ANY byte had
    /// to be dropped. The previous inline version only flagged a chunk that
    /// arrived at an already-full buffer, so the one chunk that straddles
    /// the cap was silently truncated and then parsed as if complete.
    static func appendBounded(_ chunk: Data, into data: inout Data, maxBytes: Int) -> Bool {
        let remaining = max(0, maxBytes - data.count)
        guard chunk.count > remaining else {
            data.append(chunk)
            return false
        }
        data.append(chunk.prefix(remaining))
        return true
    }

    func run(timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps", "-xml"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Installed BEFORE `run()` — setting it after risks missing the
        // termination signal if the child exits before the next line runs.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let collected = Box(Data())
        let overflowed = Box(false)
        let outputDone = DispatchSemaphore(value: 0)
        // Drained and discarded — never blocks the child if it writes
        // anything to stderr.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        defer { errorPipe.fileHandleForReading.readabilityHandler = nil }

        // Launch FIRST. A reader started before `run()` would block forever
        // on a launch failure: this function returns `nil` while the pipe's
        // write end is still open in the retained `Pipe`, so the reader
        // never sees EOF. Starting it here is safe — the kernel buffers the
        // child's first output until the loop below picks it up.
        do { try process.run() } catch { return nil }

        // Consumed on a DEDICATED background queue — not the queue that
        // waits for termination below — which is what avoids the classic
        // `Process`/`Pipe` deadlock (an unread full pipe buffer stalls the
        // child forever). Looping `availableData` until an EMPTY read (EOF)
        // gives a clean, KNOWN end-of-output signal distinct from process
        // termination — the two can be observed in either order.
        DispatchQueue.global(qos: .utility).async {
            let handle = outputPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.mutate { data in
                    if Self.appendBounded(chunk, into: &data, maxBytes: Self.maxBytes) {
                        overflowed.mutate { $0 = true }
                    }
                }
            }
            outputDone.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate() // SIGTERM first
            // SIGTERM alone cannot guarantee the child actually exits —
            // escalate to SIGKILL after a bounded grace period so it can
            // never be left orphaned.
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return nil
        }
        // The process object can report "terminated" slightly before its
        // pipe finishes delivering already-buffered data — wait for the
        // reader loop's own EOF too, so parsing only ever sees the FULL,
        // known-complete output. If that EOF never arrives, what was
        // collected may be partial: unknown, not a result.
        guard outputDone.wait(timeout: .now() + 1) == .success else { return nil }

        guard process.terminationStatus == 0 else { return nil }
        guard !(overflowed.read { $0 }) else { return nil } // truncated output must never be parsed as if complete
        return collected.read { $0 }
    }
}

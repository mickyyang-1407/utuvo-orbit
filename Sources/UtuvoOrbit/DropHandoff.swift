import Foundation

/// Legacy UTUVO Drop adoption marker.
///
/// UTUVO Drop 1.2.0 wrote a small record into the shared app group container.
/// Orbit is now completely free, so the record is read for one reason only:
/// did this Mac already use UTUVO Drop? If it did, the optional file shelf is
/// switched on once and then stays as the user leaves it.
///
/// The receipt, its value, any revocation and the purchase history are
/// ignored on purpose — they decide nothing here, and Orbit no longer sells
/// anything, so there is no entitlement left to verify. The original file is
/// only read, never modified.
///
/// Foundation only: no AppKit, no Security framework, no network.
enum DropHandoff {
    /// Unchanged, so the existing record keeps being found.
    static let appGroup = "RPNT54P79S.app.utuvo.handoff"
    static let fileName = "drop-handoff.json"
    /// The marker is tiny. Anything larger is not the record we wrote.
    static let maxRecordBytes = 64 * 1024
    /// The only marker version this build understands.
    static let supportedVersion = 1

    /// What Drop 1.2.0 wrote. Unknown fields (for example the old receipt)
    /// are ignored by the decoder.
    struct Record: Codable, Equatable {
        var version: Int
        var writtenAt: Date
    }

    struct Result: Equatable {
        /// UTUVO Drop ran on this Mac, so the file shelf is switched on once.
        var dropWasUsed: Bool
    }

    static var containerFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Reads the marker. A missing, oversized, corrupt or unsupported record
    /// simply means "no".
    static func read(from url: URL? = containerFile) -> Result {
        guard let url else { return Result(dropWasUsed: false) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= maxRecordBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maxRecordBytes,
              let record = try? decoder.decode(Record.self, from: data),
              record.version == supportedVersion else {
            return Result(dropWasUsed: false)
        }
        return Result(dropWasUsed: true)
    }
}

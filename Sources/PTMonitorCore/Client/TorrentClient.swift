import Foundation

/// The two server kinds are normalised behind this protocol; nothing above the
/// client layer knows which API a server speaks (design §3–4).
///
/// `Sendable` so a client can be handed to one of `MonitorStore`'s per-server
/// polling tasks. Implementations are actors, which own the per-server auth
/// state (qBittorrent `SID`, Transmission session id).
public protocol TorrentClient: Sendable {
    /// One full, read-only snapshot of the server's transfer state.
    func fetchSnapshot() async throws -> TransferSnapshot
    /// Validates the configuration end to end (including credentials) and
    /// returns the remote version string, e.g. "qBittorrent 4.5.2".
    func testConnection() async throws -> String
}

/// Clients throw `ServerFailure` directly, so `MonitorStore` can place the
/// cause straight into `ServerStatus.failed` (R6). Conforming here keeps the
/// domain type free of a testing/protocol dependency.
extension ServerFailure: Error {}

// MARK: - Shared JSON helpers

/// Small, explicit accessors over `JSONSerialization` output. Both remote APIs
/// use loose typing (`NSNumber` for every number, occasional numeric strings),
/// so normalisation belongs here rather than at each call site.
enum JSON {
    static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerFailure.protocolViolation("expected a JSON object")
            }
            return object
        } catch let failure as ServerFailure {
            throw failure
        } catch {
            throw ServerFailure.protocolViolation("malformed JSON: \(error.localizedDescription)")
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        if let string = value as? String { return Int64(string) }
        return nil
    }

}

import Foundation

/// Additive session metadata; collecting and restoring routing precede cancellable packaging.
nonisolated struct CaptureSaveProgress: Codable, Sendable {
    var stage: String
    var indexed_bytes: Int64? = nil
    var pending_bytes: Int64? = nil
    var cancel_allowed: Bool = false
    var operation_id: String? = nil
}

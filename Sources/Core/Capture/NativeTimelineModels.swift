import Foundation

/// Chronological key, independent of the list's display direction. A rebuild invalidates old cursors.
struct NativeTimelineCursor: Codable, Hashable, Sendable {
    let timestamp: String
    let sourceRank: Int
    let line: Int64
    let id: String
    let generation: Int64
}

struct NativeTimelineRow: Identifiable, Sendable {
    let id: String
    let timestamp: String
    let source: String
    let kind: String
    /// A small preview only; event(id:) and exports retain the complete summary and details.
    let summary: String
    let rawRef: String
    let sequence: Int64
    let cursor: NativeTimelineCursor
}

struct NativeTimelineQuery: Sendable {
    var source = "all"
    var search = ""
    var newestFirst = false
    var limit = 400
    /// Bounds are chronological, regardless of newestFirst. Without bounds, return the latest page.
    var before: NativeTimelineCursor?
    var after: NativeTimelineCursor?
    /// Clear-view excludes this sequence; pause-display includes this sequence.
    var minSequence: Int64?
    var maxSequence: Int64?
}

struct NativeTimelineSnapshot: Sendable {
    let counts: [String: Int]
    let totalCount: Int
    let latestSequence: Int64
    let generation: Int64
    let networkDiagnostics: [String: Int]
}

struct NativeTimelinePage: Sendable {
    let rows: [NativeTimelineRow]
    let matchingCount: Int
    let totalCount: Int
    /// Earliest/latest chronological row, independent of display order.
    let firstCursor: NativeTimelineCursor?
    let lastCursor: NativeTimelineCursor?
    let hasBefore: Bool
    let hasAfter: Bool
    let latestSequence: Int64
    let generation: Int64
}

enum NativeTimelineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}

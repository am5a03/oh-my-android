import AppKit
import SwiftUI
import Testing
@testable import CaptureTimelineListKit

@Suite(.serialized)
@MainActor
struct CaptureTimelineListTests {
    @Test func pendingFilterDisablesNativeInputAndPreservesTheSameTableAnchor() throws {
        let harness = Harness(rows: makeRows(0..<80))
        defer { harness.close() }
        harness.state.selectedID = "event-30"
        harness.update()
        harness.scroll(toRow: 25, offset: 11)
        let anchor = try harness.anchor()
        let window = NSWindow(contentRect: harness.scrollView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = harness.scrollView
        defer { window.close() }
        #expect(window.makeFirstResponder(harness.table))

        // SwiftUI keeps the old rows behind an opaque loading overlay and disables its representable.
        harness.update(isEnabled: false)
        #expect(!harness.table.isEnabled)
        #expect(harness.scrollView.isAccessibilityHidden())
        #expect(window.firstResponder !== harness.table)
        harness.table.selectRowIndexes(IndexSet(integer: 31), byExtendingSelection: false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        harness.table.keyDown(with: event)
        #expect(harness.table.selectedRow == 31)
        #expect(harness.state.selectedID == "event-30")
        #expect(harness.state.interactions == 0)

        harness.update()
        #expect(harness.table.isEnabled)
        #expect(!harness.scrollView.isAccessibilityHidden())
        #expect(harness.selectedID == "event-30")
        try harness.expectAnchor(anchor)
    }

    @Test func preservesSelectionAndViewportAcrossAppendPrependAndReload() throws {
        let harness = Harness(rows: makeRows(0..<80))
        defer { harness.close() }
        harness.state.selectedID = "event-30"
        harness.update()
        harness.scroll(toRow: 25, offset: 11)
        let anchor = try harness.anchor()

        harness.state.rows += makeRows(80..<120)
        harness.update()
        #expect(harness.selectedID == "event-30")
        try harness.expectAnchor(anchor)

        harness.state.rows = makeRows(-20..<0) + harness.state.rows
        harness.update()
        #expect(harness.selectedID == "event-30")
        try harness.expectAnchor(anchor)

        harness.state.wrapLines = true
        harness.update()
        #expect(harness.selectedID == "event-30")
        try harness.expectAnchor(anchor)
        #expect(harness.state.interactions == 0)
    }

    @Test func retainsParentSelectionOutsideTheLoadedPage() {
        let harness = Harness(rows: makeRows(0..<80))
        defer { harness.close() }
        harness.state.selectedID = "event-50"
        harness.update()
        #expect(harness.selectedID == "event-50")
        harness.state.rows = makeRows(0..<20)
        harness.update()
        #expect(harness.table.selectedRow == -1)
        #expect(harness.state.selectedID == "event-50")
        harness.state.rows = makeRows(40..<80)
        harness.update()
        #expect(harness.selectedID == "event-50")
        #expect(harness.state.interactions == 0)
    }

    @Test func followsTheLatestEdgeInBothDisplayOrders() {
        let harness = Harness(rows: makeRows(0..<80), followLatest: true)
        defer { harness.close() }
        #expect(harness.isAtBottom)
        harness.state.rows += makeRows(80..<120)
        harness.update()
        #expect(harness.isAtBottom)
        harness.state.rows.reverse()
        harness.state.newestFirst = true
        harness.update()
        #expect(harness.isAtTop)
        harness.state.rows = Array(makeRows(120..<140).reversed()) + harness.state.rows
        harness.update()
        #expect(harness.isAtTop)
        #expect(harness.state.interactions == 0)
    }

    @Test func nativeSelectionDisablesFollowingAndSurvivesLaterEvents() throws {
        let harness = Harness(rows: makeRows(0..<80), followLatest: true)
        defer { harness.close() }
        // This is the native table's selection path, outside an apply/update operation.
        harness.table.selectRowIndexes(IndexSet(integer: 25), byExtendingSelection: false)
        #expect(harness.state.interactions > 0)
        #expect(!harness.state.followLatest)
        #expect(harness.state.selectedID == "event-25")
        harness.update()
        harness.scroll(toRow: 25, offset: 9)
        let anchor = try harness.anchor()
        harness.state.rows += makeRows(80..<120)
        harness.update()
        #expect(harness.selectedID == "event-25")
        try harness.expectAnchor(anchor)
    }

    @Test func jumpIsOneTimeAndDoesNotEnableFollowing() throws {
        let harness = Harness(rows: makeRows(0..<80))
        defer { harness.close() }
        harness.scroll(toRow: 20)
        harness.state.jumpToken += 1
        harness.update()
        #expect(harness.isAtBottom)
        #expect(!harness.state.followLatest)

        harness.scroll(toRow: 20, offset: 6)
        let anchor = try harness.anchor()
        harness.state.rows += makeRows(80..<100)
        harness.update()
        try harness.expectAnchor(anchor)

        harness.state.rows.reverse()
        harness.state.newestFirst = true
        harness.state.jumpToken += 1
        harness.update()
        #expect(harness.isAtTop)
        #expect(!harness.state.followLatest)
    }

    @Test func headerResizesPreserveHeldReadingPositionAndSelection() throws {
        let harness = Harness(rows: makeRows(0..<160))
        defer { harness.close() }
        harness.state.selectedID = "event-80"
        harness.update()
        harness.scroll(toRow: 75, offset: 11)
        let anchor = try harness.anchor()

        for height: CGFloat in [180, 280, 450, 220, 520, 320] {
            harness.resize(width: 640, height: height)
            try harness.expectAnchor(anchor)
            #expect(harness.selectedID == "event-80")
            #expect(!harness.state.followLatest)
        }
        #expect(harness.state.interactions == 0)
    }

    @Test func headerResizesKeepFollowingAtTheLatestEdgeInBothOrders() {
        let harness = Harness(rows: makeRows(0..<160), followLatest: true)
        defer { harness.close() }
        for height: CGFloat in [180, 280, 450, 220, 520, 320] {
            harness.resize(width: 640, height: height)
            #expect(harness.isAtBottom)
        }
        harness.state.rows.reverse()
        harness.state.newestFirst = true
        harness.update()
        for height: CGFloat in [180, 280, 450, 220, 520, 320] {
            harness.resize(width: 640, height: height)
            #expect(harness.isAtTop)
        }
        #expect(harness.state.interactions == 0)
    }

    @Test func wrappedRowsResizeWithThePaneAndReturnToCompactHeight() throws {
        let text = String(repeating: "A request detail that should wrap across several lines. ", count: 12)
        let harness = Harness(rows: makeRows(0..<40, summary: text))
        defer { harness.close() }
        harness.state.wrapLines = true
        harness.update()
        let wideHeight = harness.table.rect(ofRow: 0).height
        harness.scroll(toRow: 10, offset: 11)
        let anchor = try harness.anchor()
        harness.resize(width: 320)
        try harness.expectAnchor(anchor)
        let narrowHeight = harness.table.rect(ofRow: 0).height
        #expect(narrowHeight > wideHeight)
        #expect(abs(harness.table.bounds.width - harness.scrollView.contentView.bounds.width) < 1)
        #expect(harness.table.rect(ofColumn: 0).maxX <= harness.scrollView.contentView.bounds.width + 1)

        let cell = try #require(harness.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let summary = try #require(cell.subviews.compactMap { $0 as? NSTextField }.last)
        #expect(summary.maximumNumberOfLines == 0)
        #expect(summary.preferredMaxLayoutWidth <= harness.table.bounds.width)
        #expect(summary.frame.height > 20)

        harness.state.wrapLines = false
        harness.update()
        #expect(harness.table.rect(ofRow: 0).height == 52 + harness.table.intercellSpacing.height)
        harness.resize(width: 700)
        #expect(abs(harness.table.bounds.width - harness.scrollView.contentView.bounds.width) < 1)
    }

    @Test func olderEdgeCallbackIsDeduplicatedAndStopsAfterDetach() async throws {
        let harness = Harness(rows: makeRows(0..<80))
        harness.update()
        try await Task.sleep(for: .milliseconds(10))
        let initialCount = harness.state.olderEdgeCalls
        #expect(initialCount == 1)
        harness.state.rows += makeRows(80..<100)
        harness.update()
        try await Task.sleep(for: .milliseconds(10))
        #expect(harness.state.olderEdgeCalls == initialCount)
        harness.close()
        harness.state.rows += makeRows(100..<120)
        harness.update()
        try await Task.sleep(for: .milliseconds(10))
        #expect(harness.state.olderEdgeCalls == initialCount)
    }

    private func makeRows(_ range: Range<Int>, summary: String? = nil) -> [NativeTimelineRow] {
        range.map { number in
            let id = "event-\(number)"
            let timestamp = String(format: "2026-10-15T04:%02d:%02d.000000Z", (number + 60) / 60, (number + 60) % 60)
            return NativeTimelineRow(id: id, timestamp: timestamp, source: "logs", kind: "log",
                summary: summary ?? "Fixture event \(number)", rawRef: "logs/device.log#L\(number + 100)",
                sequence: Int64(number + 100), cursor: NativeTimelineCursor(timestamp: timestamp,
                    sourceRank: 0, line: Int64(number + 100), id: id, generation: 1))
        }
    }
}

@MainActor
private final class State {
    var rows: [NativeTimelineRow]
    var selectedID: String?
    var followLatest = false
    var newestFirst = false
    var wrapLines = false
    var jumpToken: UInt64 = 0
    var interactions = 0
    var olderEdgeCalls = 0

    init(rows: [NativeTimelineRow], followLatest: Bool) {
        self.rows = rows
        self.followLatest = followLatest
    }

    var view: CaptureTimelineList {
        CaptureTimelineList(rows: rows, selectedEventID: Binding(get: { self.selectedID }, set: { self.selectedID = $0 }),
            followLatest: followLatest, newestFirst: newestFirst, wrapLines: wrapLines, jumpToLatestToken: jumpToken,
            onInteraction: { self.interactions += 1; self.followLatest = false },
            onReachedOlderEdge: { self.olderEdgeCalls += 1 })
    }
}

@MainActor
private final class Harness {
    let state: State
    let coordinator: CaptureTimelineList.Coordinator
    let scrollView: NSScrollView
    let table: NSTableView

    init(rows: [NativeTimelineRow], followLatest: Bool = false) {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        state = State(rows: rows, followLatest: followLatest)
        coordinator = state.view.makeCoordinator()
        scrollView = CaptureTimelineList.makeScrollView(coordinator: coordinator)
        table = scrollView.documentView as! NSTableView
        scrollView.setFrameSize(NSSize(width: 640, height: 320))
        update()
    }

    func update(isEnabled: Bool = true) {
        coordinator.update(state.view, isEnabled: isEnabled)
        scrollView.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    func resize(width: CGFloat, height: CGFloat = 320) {
        scrollView.setFrameSize(NSSize(width: width, height: height))
        scrollView.layoutSubtreeIfNeeded()
        update()
    }

    func scroll(toRow row: Int, offset: CGFloat = 0) {
        let y = table.rect(ofRow: row).minY + offset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func close() { coordinator.detach() }

    var selectedID: String? {
        state.rows.indices.contains(table.selectedRow) ? state.rows[table.selectedRow].id : nil
    }
    var isAtTop: Bool { abs(scrollView.contentView.bounds.minY) < 1 }
    var isAtBottom: Bool { abs(scrollView.contentView.bounds.maxY - table.bounds.height) < 1 }

    struct Anchor {
        let id: String
        let offset: CGFloat
    }

    func anchor() throws -> Anchor {
        let bounds = scrollView.contentView.bounds
        let index = table.rows(in: bounds).location
        let row = try #require(state.rows.indices.contains(index) ? state.rows[index] : nil)
        return Anchor(id: row.id, offset: bounds.minY - table.rect(ofRow: index).minY)
    }

    func expectAnchor(_ expected: Anchor, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actual = try anchor()
        #expect(actual.id == expected.id, sourceLocation: sourceLocation)
        #expect(abs(actual.offset - expected.offset) < 1, sourceLocation: sourceLocation)
    }
}

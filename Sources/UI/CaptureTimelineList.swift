import AppKit
import SwiftUI

/// A virtualized page of timeline previews. Full event details are loaded by the parent on selection.
struct CaptureTimelineList: NSViewRepresentable {
    let rows: [NativeTimelineRow]
    @Binding var selectedEventID: String?
    var followLatest: Bool
    var newestFirst: Bool
    var wrapLines: Bool
    var jumpToLatestToken: UInt64
    var onInteraction: () -> Void
    var onReachedOlderEdge: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    /// Kept separate from SwiftUI's Context so native table behavior can be exercised without opening an app window.
    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = TimelineScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.autohidesScrollers = true

        let table = TimelineTableView()
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = TimelineCell.minimumHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .textBackgroundColor
        table.setAccessibilityLabel("Shared timeline events")
        table.setAccessibilityHelp("Select an event to inspect its details. Scrolling or selecting turns off Follow Latest.")
        table.delegate = coordinator
        table.dataSource = coordinator
        scrollView.documentView = table

        let scroller = TimelineScroller()
        scrollView.verticalScroller = scroller
        coordinator.attach(scrollView: scrollView, table: table, scroller: scroller)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self, isEnabled: context.environment.isEnabled)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("timeline")
        private static let cellID = NSUserInterfaceItemIdentifier("timeline-event")
        private var parent: CaptureTimelineList
        private var rows: [NativeTimelineRow] = []
        private var indexByID: [String: Int] = [:]
        private weak var scrollView: TimelineScrollView?
        private weak var table: TimelineTableView?
        private var isApplyingUpdate = false
        private var lastJumpToken: UInt64?
        private var previousFollowLatest = false
        private var previousNewestFirst = false
        private var previousWrapLines = false
        private var previousWidth: CGFloat = 0
        private var previousHeight: CGFloat = 0
        private var lastOlderEdgeID: String?
        private var edgeCheckScheduled = false
        private var isAttached = false
        private var isInteractionEnabled = true

        init(_ parent: CaptureTimelineList) { self.parent = parent }

        fileprivate func attach(scrollView: TimelineScrollView, table: TimelineTableView, scroller: TimelineScroller) {
            self.scrollView = scrollView
            self.table = table
            isAttached = true
            scrollView.onUserScroll = { [weak self] in self?.userInteracted() }
            table.onUserNavigation = { [weak self] in self?.userInteracted() }
            scroller.onUserScroll = { [weak self] in self?.userInteracted() }
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        func detach() {
            isAttached = false
            NotificationCenter.default.removeObserver(self)
            scrollView?.onUserScroll = nil
            table?.onUserNavigation = nil
        }

        func update(_ parent: CaptureTimelineList, isEnabled: Bool = true) {
            guard let table, let scrollView else { return }
            let anchor = viewportAnchor()
            let dataChanged = rows.map(\.id) != parent.rows.map(\.id)
            let wrapChanged = previousWrapLines != parent.wrapLines
            let orderChanged = previousNewestFirst != parent.newestFirst
            let widthChanged = abs(scrollView.contentView.bounds.width - previousWidth) > 0.5
            let heightChanged = abs(scrollView.contentView.bounds.height - previousHeight) > 0.5
            let followEnabled = !previousFollowLatest && parent.followLatest
            let jumpRequested = lastJumpToken.map { $0 != parent.jumpToLatestToken } ?? false
            self.parent = parent
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }
            isInteractionEnabled = isEnabled
            table.isEnabled = isEnabled
            scrollView.isTimelineInteractionEnabled = isEnabled
            scrollView.verticalScroller?.isEnabled = isEnabled
            scrollView.setAccessibilityHidden(!isEnabled)
            if !isEnabled, let window = table.window, let responder = window.firstResponder as? NSView,
               responder === table || responder.isDescendant(of: table) {
                window.makeFirstResponder(nil)
            }

            rows = parent.rows
            indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            fitColumnToViewport()
            if dataChanged || wrapChanged {
                table.reloadData()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
            } else if widthChanged && parent.wrapLines {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
            }
            restoreSelection()
            table.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            // A legacy scroller may appear after row count changes and reduce the clip width.
            // Fit again after tiling so wrapping is measured against the final viewport width.
            let fittedWidth = table.bounds.width
            scrollView.tile()
            fitColumnToViewport()
            if parent.wrapLines && abs(fittedWidth - table.bounds.width) > 0.5 {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                table.layoutSubtreeIfNeeded()
            }

            if jumpRequested || followEnabled || parent.followLatest && (dataChanged || wrapChanged || orderChanged || widthChanged || heightChanged) {
                scrollToLatest()
            } else if dataChanged || wrapChanged || orderChanged || widthChanged || heightChanged {
                restoreViewport(anchor)
            }

            previousFollowLatest = parent.followLatest
            previousNewestFirst = parent.newestFirst
            previousWrapLines = parent.wrapLines
            previousWidth = scrollView.contentView.bounds.width
            previousHeight = scrollView.contentView.bounds.height
            lastJumpToken = parent.jumpToLatestToken
            scheduleOlderEdgeCheck()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? TimelineCell) ?? TimelineCell()
            cell.identifier = Self.cellID
            cell.configure(rows[row], wrapLines: parent.wrapLines)
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row), parent.wrapLines else { return TimelineCell.minimumHeight }
            let width = max(80, (tableView.tableColumns.first?.width ?? tableView.bounds.width) - TimelineCell.horizontalInset * 2)
            let bounds = (rows[row].summary as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: TimelineCell.summaryFont])
            return max(TimelineCell.minimumHeight, ceil(bounds.height) + TimelineCell.summaryVerticalSpace)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, isInteractionEnabled, let table else { return }
            userInteracted()
            let index = table.selectedRow
            parent.selectedEventID = rows.indices.contains(index) ? rows[index].id : nil
        }

        private func restoreSelection() {
            guard let table else { return }
            if let id = parent.selectedEventID, let index = indexByID[id] {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                // Keep the parent's selected detail when its row is outside this bounded page.
                table.deselectAll(nil)
            }
        }

        private struct Anchor {
            let candidates: [(id: String, offset: CGFloat)]
            let originY: CGFloat
        }

        private func viewportAnchor() -> Anchor {
            guard let table, let scrollView else { return Anchor(candidates: [], originY: 0) }
            let visible = scrollView.contentView.bounds
            let range = table.rows(in: visible)
            guard range.location != NSNotFound else { return Anchor(candidates: [], originY: visible.minY) }
            let indices = range.location..<min(rows.count, NSMaxRange(range))
            let candidates = indices.map { (rows[$0].id, visible.minY - table.rect(ofRow: $0).minY) }
            return Anchor(candidates: candidates, originY: visible.minY)
        }

        private func restoreViewport(_ anchor: Anchor) {
            guard let table else { return }
            for candidate in anchor.candidates {
                if let index = indexByID[candidate.id] {
                    scroll(toY: table.rect(ofRow: index).minY + candidate.offset)
                    return
                }
            }
            scroll(toY: anchor.originY)
        }

        private func scrollToLatest() {
            guard let table, let scrollView, !rows.isEmpty else { return }
            let originY = parent.newestFirst ? 0 : table.bounds.height - scrollView.contentView.bounds.height
            scroll(toY: originY)
        }

        private func scroll(toY originY: CGFloat) {
            guard let table, let scrollView else { return }
            let maximum = max(0, table.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, originY))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func fitColumnToViewport() {
            guard let table, let scrollView, !table.tableColumns.isEmpty else { return }
            let width = max(1, scrollView.contentView.bounds.width)
            if abs(table.frame.width - width) > 0.5 {
                table.setFrameSize(NSSize(width: width, height: table.frame.height))
            }
            // AppKit includes style-specific outer column padding. Let it account for those insets;
            // forcing column.width to the viewport width makes the document horizontally overflow.
            table.sizeLastColumnToFit()
        }

        fileprivate func userInteracted() {
            guard !isApplyingUpdate, isInteractionEnabled else { return }
            parent.onInteraction()
            scheduleOlderEdgeCheck()
        }

        @objc private func boundsChanged(_ notification: Notification) {
            guard !isApplyingUpdate, let scrollView, let table else { return }
            let width = scrollView.contentView.bounds.width
            let height = scrollView.contentView.bounds.height
            let widthChanged = abs(width - previousWidth) > 0.5
            if widthChanged || abs(height - previousHeight) > 0.5 {
                let anchor = viewportAnchor()
                isApplyingUpdate = true
                previousWidth = width
                previousHeight = height
                fitColumnToViewport()
                if widthChanged && parent.wrapLines {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                    table.layoutSubtreeIfNeeded()
                }
                if parent.followLatest { scrollToLatest() } else { restoreViewport(anchor) }
                isApplyingUpdate = false
            }
            scheduleOlderEdgeCheck()
        }

        private func scheduleOlderEdgeCheck() {
            guard isAttached, !edgeCheckScheduled else { return }
            edgeCheckScheduled = true
            // Bounds notifications also arrive during SwiftUI updates; defer callbacks to the next turn.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.edgeCheckScheduled = false
                self.checkOlderEdge()
            }
        }

        private func checkOlderEdge() {
            guard isAttached, isInteractionEnabled, !isApplyingUpdate, !parent.followLatest, let scrollView, let table, !rows.isEmpty,
                  let callback = parent.onReachedOlderEdge else { return }
            let visible = scrollView.contentView.bounds
            let nearOlderEdge = parent.newestFirst
                ? visible.maxY >= table.bounds.height - TimelineCell.minimumHeight
                : visible.minY <= TimelineCell.minimumHeight
            let boundaryID = parent.newestFirst ? rows.last?.id : rows.first?.id
            guard nearOlderEdge, boundaryID != lastOlderEdgeID else { return }
            lastOlderEdgeID = boundaryID
            callback()
        }
    }
}

@MainActor
private final class TimelineScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var isTimelineInteractionEnabled = true

    override func scrollWheel(with event: NSEvent) {
        guard isTimelineInteractionEnabled else { return }
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

@MainActor
private final class TimelineScroller: NSScroller {
    var onUserScroll: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onUserScroll?()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class TimelineTableView: NSTableView {
    var onUserNavigation: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if row(at: convert(event.locationInWindow, from: nil)) >= 0 { onUserNavigation?() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if [115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) { onUserNavigation?() }
        super.keyDown(with: event)
    }
}

@MainActor
private final class TimelineCell: NSTableCellView {
    static let horizontalInset: CGFloat = 10
    static let minimumHeight: CGFloat = 52
    static let summaryVerticalSpace: CGFloat = 35
    static let summaryFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let metadata = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        metadata.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        metadata.maximumNumberOfLines = 1
        summary.font = Self.summaryFont
        summary.textColor = .labelColor
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for field in [metadata, summary] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isSelectable = false
            field.setAccessibilityElement(false)
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            metadata.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            metadata.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            metadata.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            summary.leadingAnchor.constraint(equalTo: metadata.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: metadata.trailingAnchor),
            summary.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 4),
            summary.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: NativeTimelineRow, wrapLines: Bool) {
        let source = switch row.source {
        case "logs": "DEVICE LOG"
        case "network": "NETWORK"
        case "marker": "MARKER"
        default: row.source.uppercased()
        }
        metadata.stringValue = "\(row.timestamp)  \(source) · \(row.kind)"
        summary.stringValue = row.summary
        summary.maximumNumberOfLines = wrapLines ? 0 : 1
        summary.lineBreakMode = wrapLines ? .byWordWrapping : .byTruncatingTail
        summary.cell?.wraps = wrapLines
        summary.cell?.isScrollable = !wrapLines
        summary.cell?.usesSingleLineMode = !wrapLines
        setAccessibilityLabel("\(row.timestamp), \(source), \(row.kind), \(row.summary)")
        toolTip = "\(row.summary)\n\(row.rawRef)"
    }

    override func layout() {
        let width = max(80, bounds.width - Self.horizontalInset * 2)
        if abs(summary.preferredMaxLayoutWidth - width) > 0.5 { summary.preferredMaxLayoutWidth = width }
        super.layout()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            metadata.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            summary.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}

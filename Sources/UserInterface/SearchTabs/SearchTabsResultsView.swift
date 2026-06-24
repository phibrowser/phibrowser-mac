// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit

protocol SearchTabsResultsViewDelegate: AnyObject {
    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didSelect item: SearchTabsItem)
    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didRequestClose item: SearchTabsItem)
    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didToggleSection section: SearchTabsSectionKind)
    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didHoverBookmarkRoot item: SearchTabsItem, anchorView: NSView)
}

final class SearchTabsResultsView: NSView {
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 8
    static let rowHeight: CGFloat = 50
    static let headerHeight: CGFloat = 28
    private static let horizontalInset: CGFloat = 18
    private static let rowVerticalInset: CGFloat = 1

    weak var delegate: SearchTabsResultsViewDelegate?

    private enum Row {
        case sectionHeader(SearchTabsSectionSnapshot)
        case item(SearchTabsItem, itemIndex: Int)
    }

    private var sections: [SearchTabsSectionSnapshot] = []
    private var rows: [Row] = []
    private var query = ""
    private var profileId: String?
    private var selectedIndex: Int = -1
    private var isProgrammaticSelection = false

    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        return scrollView
    }()

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.headerView = nil
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .custom
        table.style = .fullWidth
        table.floatsGroupRows = false
        table.translatesAutoresizingMaskIntoConstraints = false
        table.autoresizingMask = []
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(handleRowClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchTabsResult"))
        column.width = 100
        table.addTableColumn(column)
        return table
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSections(
        _ sections: [SearchTabsSectionSnapshot],
        profileId: String,
        selectedIndex: Int,
        query: String,
        dataSourceChanged: Bool
    ) {
        self.sections = sections
        self.rows = Self.makeRows(from: sections)
        self.query = query
        self.profileId = profileId
        updateSelection(selectedIndex, dataSourceChanged: dataSourceChanged)
    }

    func anchorView(for itemID: String) -> NSView? {
        guard let row = rows.firstIndex(where: { row in
            guard case let .item(item, _) = row else {
                return false
            }
            return item.id == itemID
        }) else {
            return nil
        }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            ?? tableView.rowView(atRow: row, makeIfNecessary: false)
    }

    func measuredContentHeight() -> CGFloat {
        guard !rows.isEmpty else {
            return 0
        }

        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let tableHeight = tableView.rect(ofRow: rows.count - 1).maxY
        return Self.topPadding + tableHeight + Self.bottomPadding
    }

    private func setupViews() {
        wantsLayer = true
        addSubview(scrollView)
        scrollView.documentView = tableView
        scrollView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(Self.topPadding)
            make.bottom.equalToSuperview().offset(-Self.bottomPadding)
        }
    }

    private func updateSelection(_ index: Int, dataSourceChanged: Bool) {
        let oldSelectedRow = tableView.selectedRow
        selectedIndex = index

        if dataSourceChanged {
            tableView.reloadData()
        }

        guard let selectedRow = rows.firstIndex(where: { row in
            guard case let .item(_, itemIndex) = row else {
                return false
            }
            return itemIndex == selectedIndex
        }) else {
            tableView.deselectAll(nil)
            return
        }

        isProgrammaticSelection = true
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        scrollRowToVisibleIfNeeded(selectedRow)
        isProgrammaticSelection = false

        guard !dataSourceChanged, oldSelectedRow != selectedRow else {
            return
        }

        var rowsToReload = IndexSet(integer: selectedRow)
        if oldSelectedRow >= 0, oldSelectedRow < rows.count {
            rowsToReload.insert(oldSelectedRow)
        }
        tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
    }

    private func scrollRowToVisibleIfNeeded(_ row: Int) {
        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let visibleRect = tableView.visibleRect
        guard visibleRect.height > 0 else {
            return
        }

        let rowRect = tableView.rect(ofRow: row)
        guard !visibleRect.intersects(rowRect) else {
            return
        }

        tableView.scrollRowToVisible(row)
    }

    func normalizeScrollPositionIfNeeded() {
        let clipView = scrollView.contentView
        let contentHeight = measuredContentHeight()
        let visibleHeight = bounds.height

        if contentHeight <= visibleHeight {
            clipView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clipView)
            return
        }

        let maxY = max(contentHeight - visibleHeight, 0)
        let currentOrigin = clipView.bounds.origin
        let clampedOrigin = NSPoint(
            x: max(currentOrigin.x, 0),
            y: min(max(currentOrigin.y, 0), maxY)
        )
        guard clampedOrigin != currentOrigin else {
            return
        }
        clipView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    @objc private func handleRowClick(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count,
              case let .item(item, _) = rows[row] else {
            return
        }
        delegate?.searchTabsResultsView(self, didSelect: item)
    }

    private static func makeRows(from sections: [SearchTabsSectionSnapshot]) -> [Row] {
        var rows: [Row] = []
        var itemIndex = 0

        for section in sections {
            rows.append(.sectionHeader(section))
            for item in section.visibleItems {
                rows.append(.item(item, itemIndex: itemIndex))
                itemIndex += 1
            }
        }
        return rows
    }

}

extension SearchTabsResultsView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension SearchTabsResultsView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else {
            return nil
        }
        switch rows[row] {
        case let .sectionHeader(section):
            let view = SearchTabsSectionHeaderView()
            view.configure(kind: section.kind, isCollapsed: section.isCollapsed)
            view.onToggle = { [weak self] in
                guard let self else { return }
                self.delegate?.searchTabsResultsView(self, didToggleSection: section.kind)
            }
            return view

        case let .item(item, itemIndex):
            let cell = SearchTabsResultCellView()
            cell.delegate = self
            cell.configure(with: item, profileId: profileId, selected: itemIndex == selectedIndex, query: query)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row >= 0, row < rows.count else {
            return nil
        }
        switch rows[row] {
        case .sectionHeader:
            return SearchTabsInsetRowView(insets: .init(
                top: 0,
                left: Self.horizontalInset,
                bottom: 0,
                right: Self.horizontalInset
            ), backgroundColor: .contentOverlayBackground)
        case .item:
            return SearchTabsInsetRowView(insets: .init(
                top: Self.rowVerticalInset,
                left: Self.horizontalInset,
                bottom: Self.rowVerticalInset,
                right: Self.horizontalInset
            ))
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else {
            return Self.rowHeight
        }
        switch rows[row] {
        case .sectionHeader:
            return Self.headerHeight
        case .item:
            return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < rows.count,
              case .item = rows[row] else {
            return false
        }
        return true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row >= 0, row < rows.count,
              case .sectionHeader = rows[row] else {
            return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else {
            return
        }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count,
              case let .item(_, itemIndex) = rows[row] else {
            return
        }
        selectedIndex = itemIndex
    }
}

extension SearchTabsResultsView: SearchTabsResultCellViewDelegate {
    func searchTabsResultCellViewDidHoverBookmarkRoot(_ cellView: SearchTabsResultCellView, item: SearchTabsItem) {
        delegate?.searchTabsResultsView(self, didHoverBookmarkRoot: item, anchorView: cellView)
    }

    func searchTabsResultCellViewDidRequestClose(_ cellView: SearchTabsResultCellView, item: SearchTabsItem) {
        delegate?.searchTabsResultsView(self, didRequestClose: item)
    }
}

private final class SearchTabsSectionHeaderView: NSTableCellView {
    var onToggle: (() -> Void)?

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField()
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        return label
    }()

    private lazy var toggleButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggleSection)
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(kind: SearchTabsSectionKind, isCollapsed: Bool) {
        titleLabel.stringValue = Self.title(for: kind)
        let symbolName = isCollapsed ? "chevron.right" : "chevron.down"
        toggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: titleLabel.stringValue)
        toggleButton.toolTip = titleLabel.stringValue
    }

    private func setupViews() {
        addSubview(titleLabel)
//        addSubview(toggleButton)

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview().offset(1)
//            make.trailing.lessThanOrEqualTo(toggleButton.snp.leading).offset(-8)
            make.trailing.lessThanOrEqualToSuperview().offset(-8)
        }
//        toggleButton.snp.makeConstraints { make in
//            make.trailing.equalToSuperview()
//            make.centerY.equalTo(titleLabel)
//            make.width.height.equalTo(16)
//        }
    }

    @objc private func toggleSection() {
        onToggle?()
    }

    private static func title(for kind: SearchTabsSectionKind) -> String {
        switch kind {
        case .openTabs:
            return NSLocalizedString("Open Tabs", comment: "Search Tabs - Open tabs section title")
        case .pinnedTabs:
            return NSLocalizedString("Pinned Tabs", comment: "Search Tabs - Pinned tabs section title")
        case .bookmarks:
            return NSLocalizedString("Bookmarks", comment: "Search Tabs - Bookmarks section title")
        case .recentlyClosed:
            return NSLocalizedString("Recently Closed", comment: "Search Tabs - Recently closed section title")
        }
    }
}

private final class SearchTabsInsetRowView: NSTableRowView {
    private let insets: NSEdgeInsets

    init(insets: NSEdgeInsets, backgroundColor: ThemedColor? = nil) {
        self.insets = insets
        super.init(frame: .zero)
        wantsLayer = true
        if let backgroundColor {
            phiLayer?.setBackgroundColor(backgroundColor)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview is NSTableCellView else {
            return
        }
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

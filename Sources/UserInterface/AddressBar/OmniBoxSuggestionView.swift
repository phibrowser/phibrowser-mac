// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Kingfisher
protocol OmniBoxSuggestionViewDelegate: AnyObject {
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didClickSuggestion suggestion: OmniBoxSuggestion, at index: Int)
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didDeleteSuggestion suggestion: OmniBoxSuggestion, at index: Int)
}

class OmniBoxSuggestionView: NSView {
    weak var delegate: OmniBoxSuggestionViewDelegate?
    static let topPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 4
    private var suggestions: [OmniBoxSuggestion] = []
    private var selectedIndex: Int = -1
    private var isProgrammaticSelection = false
    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.backgroundColor = NSColor.clear
        scrollView.drawsBackground = false
        return scrollView
    }()
    
    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.intercellSpacing = NSSize.zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = NSColor.clear
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .custom
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(handleRowClick(_:))
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = 100
        table.addTableColumn(column)
        
        return table
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        wantsLayer = true
        
        addSubview(scrollView)
        scrollView.documentView = tableView
        
        scrollView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(Self.topPadding)
            make.bottom.equalToSuperview().offset(-Self.bottomPadding)
        }
    }
    
    func updateSuggestions(_ suggestions: [OmniBoxSuggestion], selectedIndex: Int = -1, dataSourceChanged: Bool) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        
        func applySelection(_ index: Int) {
            if selectedIndex >= 0 && selectedIndex < self.suggestions.count {
                let oldSelection = tableView.selectedRow
                self.isProgrammaticSelection = true
                self.tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(selectedIndex)
                self.isProgrammaticSelection = false
                if oldSelection != selectedIndex {
                    var rowsToReload = IndexSet()
                    if oldSelection >= 0 { rowsToReload.insert(oldSelection) }
                    if selectedIndex >= 0 { rowsToReload.insert(selectedIndex) }
                    if !rowsToReload.isEmpty {
                        tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
                    }
                }
            } else {
                self.tableView.deselectAll(nil)
            }
        }
        if dataSourceChanged {
            tableView.reloadData()
            applySelection(selectedIndex)
        } else {
            applySelection(selectedIndex)
        }
    }
    
    @objc private func handleRowClick(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < suggestions.count else { return }
        let suggestion = suggestions[row]
        delegate?.suggestionView(self, didClickSuggestion: suggestion, at: row)
    }
}

// MARK: - NSTableViewDataSource

extension OmniBoxSuggestionView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return suggestions.count
    }
}

// MARK: - NSTableViewDelegate
extension OmniBoxSuggestionView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < suggestions.count else { return nil }
        let cellView = OmniBoxSuggestionCellView(suggestion: suggestions[row], index: row)
        cellView.configure(with: suggestions[row], index: row)
        cellView.delegate = self
        
        return cellView
    }
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return InsetTableRowView(insets: .init(top: 2, left: 6, bottom: 2, right: 6))
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }
}

// MARK: - OmniBoxSuggestionCellViewDelegate

extension OmniBoxSuggestionView: OmniBoxSuggestionCellViewDelegate {
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didClick suggestion: OmniBoxSuggestion, at index: Int) {
        delegate?.suggestionView(self, didClickSuggestion: suggestion, at: index)
    }
    
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didRequestDelete suggestion: OmniBoxSuggestion, at index: Int) {
        delegate?.suggestionView(self, didDeleteSuggestion: suggestion, at: index)
    }
}

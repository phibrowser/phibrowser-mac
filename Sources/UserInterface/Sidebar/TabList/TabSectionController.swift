// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// Describes an incremental change in the tab section.
struct TabSectionChange {
    /// Inserted tab indices relative to `tabItems`, including `newTabButton`.
    let insertedIndices: IndexSet
    /// Removed tab indices relative to the previous `tabItems`.
    let removedIndices: IndexSet
    /// A single-tab move operation relative to `tabItems`, including `newTabButton`.
    let moveOperation: (from: Int, to: Int)?
    /// Whether a full reload is required.
    let needsFullReload: Bool
}

class TabSectionController: NSObject {
    private var cancellables = Set<AnyCancellable>()
    
    private(set) var tabItems: [SidebarItem] = []
    private let newTabButton = NewTabButtonItem()
    
    /// Previous tab GUIDs used to compute diffs.
    private var previousTabGuids: [Int] = []
    
    weak var delegate: TabSectionDelegate?
    var browserState: BrowserState? {
        didSet {
            setupBindings()
        }
    }
    
    init(state: BrowserState? = nil) {
        self.browserState = state
        super.init()
        refreshTabItems([], isInitial: true)
    }
    
    private func setupBindings() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        guard let browserState else {
            tabItems = []
            previousTabGuids = []
            return
        }

        // Sync tabItems and previousTabGuids with current state immediately, without
        // notifying the delegate. This prevents a spurious tabSectionDidUpdate call
        // (from @Published's synchronous initial delivery) that races with the
        // refreshAllItems() call in viewWillAppear and causes duplicate cell creation.
        let currentTabs = browserState.normalTabs
        var items: [SidebarItem] = [newTabButton]
        items.append(contentsOf: currentTabs)
        tabItems = items
        previousTabGuids = currentTabs.map { $0.guid }

        // dropFirst() skips the initial synchronous delivery we already handled above.
        browserState.$normalTabs
            .dropFirst()
            .sink { [weak self] tabs in
                self?.refreshTabItems(tabs, isInitial: false)
            }
            .store(in: &cancellables)
        
        browserState.$focusingTab
            .dropFirst()
            .sink { [weak self] focusingTab in
                self?.delegate?.focusingTabChanged(focusingTab)
            }
            .store(in: &cancellables)
    }
    
    private func refreshTabItems(_ tabs: [Tab], isInitial: Bool) {
        let newGuids = tabs.map { $0.guid }
        
        let change = computeChange(oldGuids: previousTabGuids, newGuids: newGuids, isInitial: isInitial)
        
        var items: [SidebarItem] = []
        items.append(newTabButton)
        for tab in tabs {
            items.append(tab)
        }
        self.tabItems = items
        self.previousTabGuids = newGuids
        
        delegate?.tabSectionDidUpdate(with: change)
    }
    
    private func computeChange(oldGuids: [Int], newGuids: [Int], isInitial: Bool) -> TabSectionChange {
        if isInitial || delegate == nil {
            return TabSectionChange(insertedIndices: [], removedIndices: [], moveOperation: nil, needsFullReload: true)
        }
        
        let oldSet = Set(oldGuids)
        let newSet = Set(newGuids)
        
        let insertedGuids = newSet.subtracting(oldSet)
        let removedGuids = oldSet.subtracting(newSet)
        
        let commonGuids = oldSet.intersection(newSet)
        let oldCommonOrder = oldGuids.filter { commonGuids.contains($0) }
        let newCommonOrder = newGuids.filter { commonGuids.contains($0) }
        
        if oldCommonOrder != newCommonOrder {
            if insertedGuids.isEmpty && removedGuids.isEmpty {
                if let moveOp = detectSingleMove(oldGuids: oldGuids, newGuids: newGuids) {
                    return TabSectionChange(
                        insertedIndices: [],
                        removedIndices: [],
                        moveOperation: (from: moveOp.from + 1, to: moveOp.to + 1), // +1 for newTabButton
                        needsFullReload: false
                    )
                }
            }
            return TabSectionChange(insertedIndices: [], removedIndices: [], moveOperation: nil, needsFullReload: true)
        }
        
        var insertedIndices = IndexSet()
        for (index, guid) in newGuids.enumerated() {
            if insertedGuids.contains(guid) {
                insertedIndices.insert(index + 1) // +1 for newTabButton
            }
        }
        
        var removedIndices = IndexSet()
        for (index, guid) in oldGuids.enumerated() {
            if removedGuids.contains(guid) {
                removedIndices.insert(index + 1) // +1 for newTabButton
            }
        }
        
        return TabSectionChange(
            insertedIndices: insertedIndices,
            removedIndices: removedIndices,
            moveOperation: nil,
            needsFullReload: false
        )
    }
    
    /// Detect whether the change can be represented as a single tab move.
    /// - Parameters:
    ///   - oldGuids: GUIDs before the move.
    ///   - newGuids: GUIDs after the move.
    /// - Returns: The `(from, to)` indices when a single move is detected.
    private func detectSingleMove(oldGuids: [Int], newGuids: [Int]) -> (from: Int, to: Int)? {
        guard oldGuids.count == newGuids.count else { return nil }
        
        for from in 0..<oldGuids.count {
            for to in 0..<oldGuids.count where from != to {
                var simulated = oldGuids
                let item = simulated.remove(at: from)
                simulated.insert(item, at: to)
                if simulated == newGuids {
                    return (from: from, to: to)
                }
            }
        }
        
        return nil
    }
    
    func activateTab(_ tab: Tab) {
        tab.makeSelfActive()
    }
    
    func closeTab(_ tab: Tab) {
        tab.close()
    }
    
    func moveTab(_ tab: Tab, to newIndex: Int) {
        ensureBrowsersState()?.move(tab: tab, to: newIndex, selectAfterMove: tab.isActive)
    }
    
    private func ensureBrowsersState() -> BrowserState? {
        guard let browserState else {
            AppLogWarn("browser state is nil!")
            return nil
        }
        return browserState
    }
    
    // MARK: - Drag and Drop Support
    
    func canReorderTabs() -> Bool {
        return true
    }
    
    func handleTabDrop(draggedTab: Tab, destinationIndex: Int) -> Bool {
        guard let currentIndex = browserState?.normalTabs.firstIndex(of: draggedTab) else {
            return false
        }
        
        // Don't move if dropping at the same position
        if currentIndex == destinationIndex {
            return false
        }
        
        browserState?.moveNormalTabLocally(from: currentIndex, to: destinationIndex)
        return true
    }
    
    func canAcceptTabForBookmarkCreation(_ tab: Tab) -> Bool {
        return tab.url != nil
    }
}

protocol TabSectionDelegate: AnyObject {
    func tabSectionDidUpdate(with change: TabSectionChange)
    func focusingTabChanged(_ tab: Tab?)
}

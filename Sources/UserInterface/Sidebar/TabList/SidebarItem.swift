// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

protocol ContextMenuRepresentable {
    func makeContextMenu(on menu: NSMenu)
}

/// Provides an optional indentation level override for rendering in `SideBarOutlineView`.
/// This is useful for "virtual" items that are inserted at a different tree position
/// but should visually indicate their logical nesting.
protocol SidebarIndentationLevelProviding {
    /// If non-nil, `SideBarOutlineView` should use this level (instead of `level(forRow:)`) to compute indentation.
    var indentationLevelOverride: Int? { get }
}

protocol SidebarItem: AnyObject {
    var id: AnyHashable { get }
    var title: String { get }
    var url: String? { get }
    var iconName: String? { get }
    var faviconUrl: String? { get }
    var isExpandable: Bool { get }
    var hasChildren: Bool { get }
    var childrenItems: [SidebarItem] { get }
    var depth: Int { get }
    var itemType: SidebarItemType { get }
    var isActive: Bool { get }
    var isSelectable: Bool { get }
    func performAction(with owner: SidebarTabListItemOwner?)
    var isBookmark: Bool { get }
}

enum SidebarItemType {
    case tab
    case bookmark
    case bookmarkFolder
    case newTabButton
    case separator
    /// Header row for a Chromium tab group, materialized by
    /// `TabGroupSidebarItem`. Selectable=false; expand/collapse routes
    /// through the bridge via `requestTabGroupCollapseChange`.
    case tabGroup
    /// A non-pinned split rendered as a single merged row with two
    /// favicons side-by-side. Materialized by `SplitPairSidebarItem`.
    /// The two panes of a split are merged into one row so the pair
    /// reads as one item; clicking the left half focuses the left
    /// pane, clicking the right half focuses the right pane.
    case splitPair
}

/// Sidebar row that represents a non-pinned split as a single merged
/// item carrying both panes. Stable across rebuilds via the underlying
/// `SplitGroup.id` so the outline-view diff keeps the row in place when
/// either pane's title / favicon / focus changes.
final class SplitPairSidebarItem: SidebarItem, ContextMenuRepresentable {
    let groupId: String
    // Mutable so a cell observing the strip can swap left/right in place
    // after Chromium's reverse — the item's `id` is keyed on `groupId`
    // alone, so the outline-view diff treats a swap as no-op; the cell
    // re-resolves order and updates these fields directly.
    var leftTab: Tab
    var rightTab: Tab
    weak var browserState: BrowserState?

    init(groupId: String, leftTab: Tab, rightTab: Tab, browserState: BrowserState?) {
        self.groupId = groupId
        self.leftTab = leftTab
        self.rightTab = rightTab
        self.browserState = browserState
    }

    var id: AnyHashable { "split:\(groupId)" }
    var title: String { "\(leftTab.title) | \(rightTab.title)" }
    var url: String? { leftTab.url }
    var iconName: String? { nil }
    var faviconUrl: String? { leftTab.faviconUrl }
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }
    var childrenItems: [SidebarItem] { [] }
    var depth: Int { 0 }
    var itemType: SidebarItemType { .splitPair }
    var isActive: Bool { leftTab.isActive || rightTab.isActive }
    var isSelectable: Bool { true }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        // Default click target is the active pane; left as fallback.
        let target = rightTab.isActive ? rightTab : leftTab
        target.performAction(with: owner)
    }

    func boundBookmarkGuid(in state: BrowserState?) -> String? {
        guard let state = state ?? browserState else { return nil }
        return state.splitBookmarkBindings.first { entry in
            entry.value == groupId && state.bookmarkManager.bookmark(withGuid: entry.key) != nil
        }?.key
    }

    /// Drives the merged cell's context menu off the left pane so the
    /// user gets split-aware items (Remove from Split, etc.) after the
    /// shared multi-selection menu gets first chance to take over.
    @MainActor func makeContextMenu(on menu: NSMenu) {
        if let browserState,
           TabMultiSelectionMenu.populateIfNeeded(menu, browserState: browserState) {
            return
        }
        leftTab.makeContextMenu(on: menu)
    }
}

// Helper classes for UI elements
class SeparatorItem: SidebarItem {
    let id: AnyHashable = UUID()
    var title: String = ""
    var url: String? = nil
    var iconName: String? = nil
    var faviconUrl: String? = nil
    var isExpandable: Bool = false
    var hasChildren: Bool = false
    var childrenItems: [SidebarItem] = []
    var depth: Int = 0
    var itemType: SidebarItemType = .separator
    var isActive: Bool = false
    
    func performAction(with owner: SidebarTabListItemOwner?) {
        // No action for separator
    }
    
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }
}

class NewTabButtonItem: SidebarItem {
    var isBookmark: Bool { false }
    
    let id: AnyHashable = "new-tab-button"
    var title: String = NSLocalizedString("New Tab", comment: "Sidebar tab list - Button title to create a new browser tab")
    var url: String? = nil
    var iconName: String? = "plus"
    var faviconUrl: String? = nil
    var isExpandable: Bool = false
    var hasChildren: Bool = false
    var childrenItems: [SidebarItem] = []
    var depth: Int = 0
    var itemType: SidebarItemType = .newTabButton
    var isActive: Bool = false
    var isSelectable: Bool { false }
    
    func performAction(with owner: SidebarTabListItemOwner?) {
        owner?.newTabClicked(self)
    }
}

// Notification names
extension Notification.Name {
    static let moveTabToBookmarks = Notification.Name("moveTabToBookmarks")
    /// Notification posted when a bookmark enters inline edit mode. `object` is the bookmark.
    static let bookmarkStartEditing = Notification.Name("bookmarkStartEditing")
}

// MARK: - Pasteboard Types
/// App-specific pasteboard types used for drag and drop.
/// Custom types keep other apps from accidentally accepting our drags.
extension NSPasteboard.PasteboardType {
    /// Pinned-tab pasteboard type storing `guidInLocalDB`.
    static let pinnedTab = NSPasteboard.PasteboardType("com.phibrowser.pinnedTab")
    /// Normal-tab pasteboard type storing `guid`.
    static let normalTab = NSPasteboard.PasteboardType("com.phibrowser.normalTab")
    /// Multi-selection normal-tab pasteboard type storing comma-separated guids.
    static let normalTabs = NSPasteboard.PasteboardType("com.phibrowser.normalTabs")
    /// Bookmark pasteboard type storing the bookmark GUID.
    static let phiBookmark = NSPasteboard.PasteboardType("com.phibrowser.bookmark")
    /// Multi-selection bookmark pasteboard type storing comma-separated GUIDs.
    static let bookmarks = NSPasteboard.PasteboardType("com.phibrowser.bookmarks")
    /// Source window identifier used for cross-window drags.
    static let sourceWindowId = NSPasteboard.PasteboardType("com.phibrowser.sourceWindowId")
    /// Tab-group pasteboard type storing the group's hex token. Used
    /// when the user drags a `TabGroupSidebarItem`'s header — the
    /// payload identifies the entire contiguous group block.
    static let tabGroup = NSPasteboard.PasteboardType("com.phibrowser.tabGroup")
}

extension NSPasteboard {
    func phiNormalTabIds() -> [Int] {
        guard let payload = string(forType: .normalTabs) else { return [] }
        var seen = Set<Int>()
        return payload
            .split(separator: ",")
            .compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { seen.insert($0).inserted }
    }

    func phiBookmarkGuids() -> [String] {
        guard let payload = string(forType: .bookmarks) else { return [] }
        var seen = Set<String>()
        return payload
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

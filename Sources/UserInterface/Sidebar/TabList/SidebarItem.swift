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

/// Presentation-only root: bookmark ownership and persisted parent GUIDs stay unchanged.
final class SpaceRootSidebarItem: SidebarItem {
    weak var browserState: BrowserState?
    var childrenItems: [SidebarItem] = []

    init(browserState: BrowserState) { self.browserState = browserState }

    var id: AnyHashable { "space-bookmarks:\(browserState?.spaceId ?? "")" }
    var title: String {
        SpaceManager.shared.spaces.first { $0.spaceId == browserState?.spaceId }?.name
            ?? browserState?.bookmarkManager.rootFolder.title ?? ""
    }
    var url: String? { nil }
    var iconName: String? { "chevron.right" }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { true }
    var hasChildren: Bool { !childrenItems.isEmpty }
    var depth: Int { 0 }
    var itemType: SidebarItemType { .spaceRoot }
    var isActive: Bool { false }
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        owner?.toggleItemExpanded(self)
    }
}

enum SidebarItemType {
    case spaceRoot
    case tab
    case bookmark
    case bookmarkFolder
    case newTabButton
    case separator
    /// Header row for a Chromium tab group, materialized by
    /// `TabGroupSidebarItem`. Selectable=false; expand/collapse routes
    /// through the bridge via `requestTabGroupCollapseChange`.
    case tabGroup
    /// A non-pinned split rendered as a single merged row with one
    /// favicon segment per pane. Materialized by `SplitSidebarItem`.
    /// The panes of a split (two to `SplitGroup.maxPaneCount`) are merged
    /// into one row so the split reads as one item; clicking a segment
    /// focuses that pane.
    case split
}

/// Sidebar row that represents a non-pinned split as a single merged
/// item carrying every pane. Stable across rebuilds via the underlying
/// `SplitGroup.id` so the outline-view diff keeps the row in place when
/// any pane's title / favicon / focus changes.
final class SplitSidebarItem: SidebarItem, ContextMenuRepresentable {
    let groupId: String
    /// Pane tabs in on-screen order (slot order of the live `SplitGroup`,
    /// two to `SplitGroup.maxPaneCount` entries). Mutable so a cell
    /// observing the strip can re-sequence the panes in place after
    /// Chromium reorders or replaces one — the item's `id` is keyed on
    /// `groupId` alone, so the outline-view diff treats such a change as
    /// no-op; the cell re-resolves the order and updates this field directly.
    var panes: [Tab]
    weak var browserState: BrowserState?

    init(groupId: String, panes: [Tab], browserState: BrowserState?) {
        self.groupId = groupId
        self.panes = panes
        self.browserState = browserState
    }

    var firstPane: Tab { panes[0] }
    var lastPane: Tab { panes[panes.count - 1] }
    var paneCount: Int { panes.count }

    func contains(tabId: Int) -> Bool {
        panes.contains { $0.guid == tabId }
    }

    var id: AnyHashable { "split:\(groupId)" }
    var title: String { panes.map(\.title).joined(separator: " | ") }
    var url: String? { firstPane.url }
    var iconName: String? { nil }
    var faviconUrl: String? { firstPane.faviconUrl }
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }
    var childrenItems: [SidebarItem] { [] }
    var depth: Int { 0 }
    var itemType: SidebarItemType { .split }
    var isActive: Bool { panes.contains { $0.isActive } }
    var isSelectable: Bool { true }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        // Default click target is the active pane; the first pane as fallback.
        let target = panes.first { $0.isActive } ?? firstPane
        target.performAction(with: owner)
    }

    func boundBookmarkGuid(in state: BrowserState?) -> String? {
        guard let state = state ?? browserState else { return nil }
        return state.splitBookmarkBindings.first { entry in
            entry.value == groupId && state.bookmarkManager.bookmark(withGuid: entry.key) != nil
        }?.key
    }

    /// Drives the merged cell's context menu off the first pane so the
    /// user gets split-aware items (Remove from Split, etc.) after the
    /// shared multi-selection menu gets first chance to take over.
    @MainActor func makeContextMenu(on menu: NSMenu) {
        if let browserState,
           TabMultiSelectionMenu.populateIfNeeded(menu, browserState: browserState) {
            return
        }
        firstPane.makeContextMenu(on: menu)
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
    var title: String = NSLocalizedString("sidebar.tabList.newTabButton", value: "New Tab", comment: "Sidebar tab list - Button title to create a new browser tab")
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
    /// Notification posted when a sidebar folder requests its icon picker. `object` is the bookmark.
    static let bookmarkFolderIconPickerRequested = Notification.Name("bookmarkFolderIconPickerRequested")
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

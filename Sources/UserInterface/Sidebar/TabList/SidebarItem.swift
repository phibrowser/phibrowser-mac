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
    /// Bookmark pasteboard type storing the bookmark GUID.
    static let phiBookmark = NSPasteboard.PasteboardType("com.phibrowser.bookmark")
    /// Source window identifier used for cross-window drags.
    static let sourceWindowId = NSPasteboard.PasteboardType("com.phibrowser.sourceWindowId")
}

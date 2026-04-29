// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

/// Sidebar wrapper for a Chromium tab group. Built per refresh by
/// `TabSectionController` from `BrowserState.groups[token]`. Membership is
/// derived live from `state.normalTabs.filter { $0.groupToken == token }`
/// (single source of truth on `Tab.groupToken`); the wrapper holds no
/// cached child set, so closing/reordering grouped tabs reflects after a
/// `reloadItem(_:reloadChildren:)` call without rebuilding the wrapper.
final class TabGroupSidebarItem: SidebarItem {
    let group: WebContentGroupInfo
    private weak var browserState: BrowserState?
    /// Snapshot at init: the wrapper's owning window. Bridge calls require
    /// a windowId; the weak browserState may be deallocated during
    /// menu-action dispatch but the windowId stays valid because window
    /// teardown also tears down the sidebar/menu.
    let windowId: Int

    init(group: WebContentGroupInfo, browserState: BrowserState) {
        self.group = group
        self.browserState = browserState
        self.windowId = browserState.windowId
    }

    var id: AnyHashable { group.token }
    var title: String { group.displayTitle(memberCount: members.count) }
    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { true }
    var hasChildren: Bool {
        guard let state = browserState else { return false }
        return state.normalTabs.contains { $0.groupToken == group.token }
    }

    /// Live member resolution: filters `normalTabs` by `groupToken`.
    /// `normalTabs` is already in tab-strip order, so the result naturally
    /// follows Chromium's intra-group ordering, including after
    /// `reorderTabs(_:)`. No parallel index to keep in sync.
    var childrenItems: [SidebarItem] { members }

    private var members: [Tab] {
        guard let state = browserState else { return [] }
        return state.normalTabs.filter { $0.groupToken == group.token }
    }

    var depth: Int { 0 }
    var itemType: SidebarItemType { .tabGroup }
    var isActive: Bool { false }
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        // Click on the header row itself is a no-op. Disclosure click
        // triggers expand/collapse via NSOutlineView's native chevron,
        // routed through `shouldExpandItem`/`shouldCollapseItem` to
        // `bridge.updateTabGroupCollapsed`.
    }
}

// MARK: - Right-click menu

extension TabGroupSidebarItem: ContextMenuRepresentable {
    @MainActor
    func makeContextMenu(on menu: NSMenu) {
        menu.removeAllItems()

        let newTabItem = NSMenuItem(
            title: NSLocalizedString(
                "New Tab in Group",
                comment: "Tab group context menu - Open a new tab inside this group"),
            action: #selector(newTabInGroup),
            keyEquivalent: "")
        newTabItem.target = self
        menu.addItem(newTabItem)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(
            title: NSLocalizedString(
                "Rename Group",
                comment: "Tab group context menu - Rename the group"),
            action: #selector(renameGroup),
            keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let colorParent = NSMenuItem(
            title: NSLocalizedString(
                "Change Color",
                comment: "Tab group context menu - Submenu to change the group color"),
            action: nil,
            keyEquivalent: "")
        let colorSubmenu = NSMenu()
        for color in GroupColor.allCases {
            let entry = NSMenuItem(
                title: color.localizedName,
                action: #selector(setGroupColor(_:)),
                keyEquivalent: "")
            entry.target = self
            entry.image = NSImage.tabGroupColorSwatch(for: color)
            entry.representedObject = color.rawValue
            if color == group.color {
                entry.state = .on
            }
            colorSubmenu.addItem(entry)
        }
        colorParent.submenu = colorSubmenu
        menu.addItem(colorParent)

        let collapseItem = NSMenuItem(
            title: group.isCollapsed
                ? NSLocalizedString(
                    "Expand Group",
                    comment: "Tab group context menu - Expand a collapsed group")
                : NSLocalizedString(
                    "Collapse Group",
                    comment: "Tab group context menu - Collapse an expanded group"),
            action: #selector(toggleCollapsed),
            keyEquivalent: "")
        collapseItem.target = self
        menu.addItem(collapseItem)

        menu.addItem(.separator())

        let ungroupItem = NSMenuItem(
            title: NSLocalizedString(
                "Ungroup",
                comment: "Tab group context menu - Dissolve the group, keeping the tabs"),
            action: #selector(ungroupTabs),
            keyEquivalent: "")
        ungroupItem.target = self
        menu.addItem(ungroupItem)

        let closeItem = NSMenuItem(
            title: NSLocalizedString(
                "Close Group",
                comment: "Tab group context menu - Close the group and all its tabs"),
            action: #selector(closeGroup),
            keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
    }

    private var bridge: PhiChromiumBridgeProtocol? {
        ChromiumLauncher.sharedInstance().bridge
    }

    /// True iff this group still exists in BrowserState. Used after
    /// `alert.runModal()` returns to short-circuit bridge calls when a
    /// kClosed event landed during the nested run loop.
    private var groupStillExists: Bool {
        browserState?.groups[group.token] != nil
    }

    @MainActor
    @objc private func renameGroup() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Rename Group",
            comment: "Tab group rename alert - Title")
        alert.informativeText = NSLocalizedString(
            "Leave empty to use the auto-generated name.",
            comment: "Tab group rename alert - Hint that empty title clears to auto-name")
        alert.addButton(withTitle: NSLocalizedString(
            "Save",
            comment: "Tab group rename alert - Confirm button"))
        alert.addButton(withTitle: NSLocalizedString(
            "Cancel",
            comment: "Tab group rename alert - Cancel button"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = group.title
        field.placeholderString = group.displayTitle(memberCount: members.count)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The nested run loop in runModal() can outlast the group: a
        // Chromium kClosed event for this token can land while the alert
        // is on screen. Skip the bridge call rather than dispatching a
        // command against a defunct token.
        guard groupStillExists else {
            AppLogDebug(
                "[TAB_GROUPS] renameGroup: group closed during modal; " +
                "windowId=\(windowId) token=\(group.token); skipping"
            )
            return
        }
        let newTitle = field.stringValue
        AppLogDebug(
            "[TAB_GROUPS] renameGroup windowId=\(windowId) " +
            "token=\(group.token) title='\(newTitle)'"
        )
        bridge?.updateTabGroupTitle(withWindowId: Int64(windowId),
                                    tokenHex: group.token,
                                    title: newTitle)
    }

    @MainActor
    @objc private func setGroupColor(_ sender: NSMenuItem) {
        guard let wire = sender.representedObject as? String else { return }
        AppLogDebug(
            "[TAB_GROUPS] setGroupColor windowId=\(windowId) " +
            "token=\(group.token) color=\(wire)"
        )
        bridge?.updateTabGroupColor(withWindowId: Int64(windowId),
                                    tokenHex: group.token,
                                    color: wire)
    }

    @MainActor
    @objc private func toggleCollapsed() {
        let next = !group.isCollapsed
        AppLogDebug(
            "[TAB_GROUPS] toggleCollapsed windowId=\(windowId) " +
            "token=\(group.token) → \(next)"
        )
        bridge?.updateTabGroupCollapsed(withWindowId: Int64(windowId),
                                       tokenHex: group.token,
                                       isCollapsed: next)
    }

    @MainActor
    @objc private func ungroupTabs() {
        let memberIds = members.map { $0.guid }
        guard !memberIds.isEmpty else { return }
        let ids: [NSNumber] = memberIds.map { NSNumber(value: Int64($0)) }
        AppLogDebug(
            "[TAB_GROUPS] ungroupTabs windowId=\(windowId) " +
            "token=\(group.token) tabIds=\(memberIds)"
        )
        bridge?.removeTabsFromGroup(withWindowId: Int64(windowId),
                                    tabIds: ids)
    }

    @MainActor
    @objc private func closeGroup() {
        AppLogDebug(
            "[TAB_GROUPS] closeGroup windowId=\(windowId) " +
            "token=\(group.token)"
        )
        bridge?.closeGroup(withWindowId: Int64(windowId),
                           tokenHex: group.token)
    }

    @MainActor
    @objc private func newTabInGroup() {
        AppLogDebug(
            "[TAB_GROUPS] newTabInGroup windowId=\(windowId) " +
            "token=\(group.token)"
        )
        bridge?.createTabInGroup(withWindowId: Int64(windowId),
                                  tokenHex: group.token)
    }
}

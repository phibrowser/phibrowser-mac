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
final class TabGroupSidebarItem: NSObject, SidebarItem {
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
        super.init()
    }

    var id: AnyHashable { group.token }
    var title: String { group.displayTitle(memberCount: members.count) }
    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    /// `false` because the group renders as a self-contained
    /// `TabGroupCellView` leaf in the outer outline view: the cell
    /// hosts its own inner table for member rows. The outer outline
    /// no longer descends into a separate child branch per member.
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }

    /// Live member resolution: filters `normalTabs` by `groupToken`.
    /// Used by `TabGroupCellView.applyMembers` callers and other
    /// non-outline consumers (context menu, etc.).
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

extension TabGroupSidebarItem: ContextMenuRepresentable, NSMenuItemValidation {
    @MainActor
    func makeContextMenu(on menu: NSMenu) {
        menu.removeAllItems()

        let newTabItem = NSMenuItem(
            title: NSLocalizedString("sidebar.tabGroupContextMenu.newTabAction", value: "New Tab in Group",
                comment: "Tab group context menu - Open a new tab inside this group"),
            action: #selector(newTabInGroup),
            keyEquivalent: "c")
        newTabItem.keyEquivalentModifierMask = [.command, .control]
        newTabItem.target = self
        menu.addItem(newTabItem)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(
            title: NSLocalizedString("sidebar.tabGroupContextMenu.renameAction", value: "Rename Group",
                comment: "Tab group context menu - Rename the group"),
            action: #selector(renameGroup),
            keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let colorParent = NSMenuItem(
            title: NSLocalizedString("sidebar.tabGroupContextMenu.changeColorSubmenu", value: "Change Color",
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
                ? NSLocalizedString("sidebar.tabGroupContextMenu.expandAction", value: "Expand Group",
                    comment: "Tab group context menu - Expand a collapsed group")
                : NSLocalizedString("sidebar.tabGroupContextMenu.collapseAction", value: "Collapse Group",
                    comment: "Tab group context menu - Collapse an expanded group"),
            action: #selector(toggleCollapsed),
            keyEquivalent: "")
        collapseItem.target = self
        menu.addItem(collapseItem)

        menu.addItem(.separator())

        let ungroupItem = NSMenuItem(
            title: NSLocalizedString("sidebar.tabGroupContextMenu.ungroupAction", value: "Ungroup",
                comment: "Tab group context menu - Dissolve the group, keeping the tabs"),
            action: #selector(ungroupTabs),
            keyEquivalent: "")
        ungroupItem.target = self
        menu.addItem(ungroupItem)

        let closeItem = NSMenuItem(
            title: NSLocalizedString("sidebar.tabGroupContextMenu.closeGroupAction", value: "Close Group",
                comment: "Tab group context menu - Close the group and all its tabs"),
            action: #selector(closeGroup),
            keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command, .control]
        closeItem.target = self
        menu.addItem(closeItem)

        if let state = browserState,
           PhiPreferences.GeneralSettings.directionalTabClosingEnabled.loadValue() {
            for direction in BrowserState.TabCloseDirection.allCases {
                let item = NSMenuItem(
                    title: direction.menuTitle(isHorizontal: state.layoutMode.isTraditional, relativeToGroup: true),
                    action: #selector(closeTabsInDirection(_:)),
                    keyEquivalent: "")
                item.tag = direction.rawValue
                item.target = self
                menu.addItem(item)
            }
        }
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let state = browserState, groupStillExists,
              !SpaceSessionControllersManager.shared.isGuestTransitionInteractionBlocked,
              !AgentSpaceManager.shared.isAgentOwned(state.spaceId) else { return false }
        guard menuItem.action == #selector(closeTabsInDirection(_:)) else { return true }
        guard let direction = BrowserState.TabCloseDirection(rawValue: menuItem.tag) else { return false }
        return !state.directionalTabCloseCandidates(
            anchoredAt: Set(members.map(\.guid)), direction: direction).isEmpty
    }

    @MainActor
    @objc private func closeTabsInDirection(_ item: NSMenuItem) {
        guard let state = browserState, groupStillExists,
              let direction = BrowserState.TabCloseDirection(rawValue: item.tag) else { return }
        state.closeTabs(state.directionalTabCloseCandidates(
            anchoredAt: Set(members.map(\.guid)), direction: direction))
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
        alert.messageText = NSLocalizedString("sidebar.tabGroupRenameDialog.title", value: "Rename Group",
            comment: "Tab group rename alert - Title")
        alert.informativeText = NSLocalizedString("sidebar.tabGroupRenameDialog.autoNameHint", value: "Leave empty to use the auto-generated name.",
            comment: "Tab group rename alert - Hint that empty title clears to auto-name")
        alert.addButton(withTitle: NSLocalizedString("sidebar.tabGroupRenameDialog.saveButton", value: "Save",
            comment: "Tab group rename alert - Confirm button"))
        alert.addButton(withTitle: NSLocalizedString("sidebar.tabGroupRenameDialog.cancelButton", value: "Cancel",
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

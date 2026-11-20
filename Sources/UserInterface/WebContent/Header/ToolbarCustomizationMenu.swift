// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// The "Customize Toolbar…" entry shared by the toolbar's right-click menu,
/// the Site Menu and the tab strip's Toolbar Buttons submenu, and the menu
/// of a button in the address bar while the toolbar is being customized.
enum ToolbarCustomizationMenu {
    static let customizeItemIdentifier = NSUserInterfaceItemIdentifier("phi.toolbar.customize")

    static var customizeTitle: String {
        NSLocalizedString("browser.toolbarCustomization.customizeAction", value: "Customize Toolbar…", comment: "Toolbar, Site Menu and tab strip context menus - Opens Customize Toolbar to add, remove and rearrange the toolbar's buttons")
    }

    static func customizeItem(action: @escaping () -> Void) -> NSMenuItem {
        actionItem(title: customizeTitle, identifier: customizeItemIdentifier, action: action)
    }

    /// The toolbar's right-click menu outside the address bar.
    static func toolbarMenu(onCustomize: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(customizeItem(action: onCustomize))
        return menu
    }

    // MARK: - While customizing

    static let visibilityAlwaysItemIdentifier = NSUserInterfaceItemIdentifier("phi.toolbar.customize.visibility.always")
    static let visibilityOnHoverItemIdentifier = NSUserInterfaceItemIdentifier("phi.toolbar.customize.visibility.onHover")

    /// The right-click menu of a button in the address bar while customizing:
    /// whether it always shows or only while the pointer is over the address bar.
    static func visibilityMenu(current: ToolbarItemVisibility, onSelect: @escaping (ToolbarItemVisibility) -> Void) -> NSMenu {
        let menu = NSMenu()
        let always = actionItem(
            title: NSLocalizedString("browser.toolbarCustomization.visibilityAlways", value: "Always", comment: "Context menu of a button in the address bar while customizing the toolbar - Shows the button at all times"),
            identifier: visibilityAlwaysItemIdentifier,
            action: { onSelect(.always) }
        )
        let onHover = actionItem(
            title: NSLocalizedString("browser.toolbarCustomization.visibilityOnHover", value: "On Hover", comment: "Context menu of a button in the address bar while customizing the toolbar - Shows the button only while the pointer is over the address bar"),
            identifier: visibilityOnHoverItemIdentifier,
            action: { onSelect(.onHover) }
        )
        always.state = current == .always ? .on : .off
        onHover.state = current == .onHover ? .on : .off
        menu.addItem(always)
        menu.addItem(onHover)
        return menu
    }

    /// The item keeps its action alive through `representedObject`, so it
    /// fires for as long as the menu holding it exists.
    private static func actionItem(title: String, identifier: NSUserInterfaceItemIdentifier, action: @escaping () -> Void) -> NSMenuItem {
        typealias Target = WebContentAddressBarMenuPresenter.MenuActionTarget
        let target = Target(action: action)
        let item = NSMenuItem(title: title, action: #selector(Target.performAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.identifier = identifier
        return item
    }
}

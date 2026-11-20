// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import Security
import SecurityInterface

final class WebContentAddressBarMenuPresenter {
    /// Runs a closure for a menu item; the toolbar's other menus
    /// (`ToolbarCustomizationMenu`) use it too.
    final class MenuActionTarget: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSMenuItem) {
            action()
        }
    }

    static let siteMemoriesItemIdentifier = NSUserInterfaceItemIdentifier("phi.siteMenu.siteMemories")

    /// Pops the Site Menu under `anchorView`, or at the pointer when
    /// `contextMenuEvent` is a right-click on the toolbar. Site Memories
    /// opens its menu at the same spot (`memoryMenuLocation`).
    static func present(
        browserState: BrowserState?,
        currentTab: Tab?,
        anchorView: NSView?,
        contextMenuEvent: NSEvent? = nil,
        showsSiteMemoriesEntry: Bool,
        onCustomize: @escaping () -> Void,
        onPresentationChanged: (Bool) -> Void
    ) {
        guard let anchorView = anchorView ?? browserState?.windowController?.window?.contentView else {
            return
        }

        let menu = makeMenu(
            browserState: browserState,
            currentTab: currentTab,
            anchorView: anchorView,
            memoryMenuLocation: memoryMenuLocation(for: contextMenuEvent, in: anchorView),
            showsSiteMemoriesEntry: showsSiteMemoriesEntry,
            onCustomize: onCustomize
        )

        onPresentationChanged(true)
        anchorView.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let contextMenuEvent {
                NSMenu.popUpContextMenu(menu, with: contextMenuEvent, for: anchorView)
            } else {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: anchorView)
            }
        }
        onPresentationChanged(false)
    }

    /// Where Site Memories opens its menu from a Site Menu that `event`
    /// opened: at the right-click, in `anchorView`'s coordinates. The anchor
    /// can be far from it (Minimal's slot, the strip of a removed bar). Nil,
    /// under the anchor, for a Site Menu opened by its button.
    static func memoryMenuLocation(for event: NSEvent?, in anchorView: NSView) -> NSPoint? {
        event.map { anchorView.convert($0.locationInWindow, from: nil) }
    }

    /// Whether the Site Menu offers Site Memories: the button is not drawn
    /// (see `ToolbarArrangement.showsSiteMemoriesButton`) and the page is one
    /// the button would show for.
    @MainActor
    static func showsSiteMemoriesEntry(arrangement: ToolbarArrangement, browserState: BrowserState?, currentTab: Tab?) -> Bool {
        guard !arrangement.showsSiteMemoriesButton, let browserState else { return false }
        return SiteMemoryMenuActions(
            urlString: (currentTab ?? browserState.focusingTab)?.url ?? "",
            profileID: browserState.profileId,
            isIncognito: browserState.isIncognito,
            isPhiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
            service: nil
        ) != nil
    }

    /// The Site Menu. Each item keeps its action target alive through its
    /// `representedObject`, so the menu works for as long as it exists.
    /// `anchorView` is where Site Memories opens its menu: under it, or at
    /// `memoryMenuLocation` in it when given.
    static func makeMenu(
        browserState: BrowserState?,
        currentTab: Tab?,
        anchorView: NSView? = nil,
        memoryMenuLocation: NSPoint? = nil,
        showsSiteMemoriesEntry: Bool,
        onCustomize: @escaping () -> Void
    ) -> NSMenu {
        let resolvedTab = currentTab ?? browserState?.focusingTab
        let extensionManager = browserState?.extensionManager
        extensionManager?.refreshExtensions()
        let rawURLString = resolvedTab?.url ?? ""

        let menu = NSMenu()
        menu.autoenablesItems = false

        func addMenuItem(
            title: String,
            keyEquivalent: String = "",
            state: NSControl.StateValue = .off,
            isEnabled: Bool = true,
            image: NSImage? = nil,
            action: (() -> Void)? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
            item.state = state
            item.isEnabled = isEnabled
            item.image = image
            if let action {
                let target = MenuActionTarget(action: action)
                item.representedObject = target
                item.target = target
                item.action = #selector(MenuActionTarget.performAction(_:))
            }
            menu.addItem(item)
            return item
        }

        @MainActor
        func buildExtensionsSubmenu() -> NSMenu {
            let submenu = NSMenu(title: NSLocalizedString("browser.addressBarMenu.extensionsSubmenu.title", value: "Extensions", comment: "Address bar menu - Extensions submenu title"))
            let extensions = extensionManager?.extensions ?? []

            if extensions.isEmpty {
                let emptyItem = NSMenuItem(
                    title: NSLocalizedString("browser.addressBarMenu.extensionsSubmenu.emptyPlaceholder", value: "No extensions found", comment: "Address bar menu - Empty extension submenu item"),
                    action: nil,
                    keyEquivalent: ""
                )
                emptyItem.isEnabled = false
                submenu.addItem(emptyItem)
            } else {
                for ext in extensions {
                    let item = NSMenuItem(title: ext.name, action: nil, keyEquivalent: "")
                    item.image = normalizedExtensionMenuIcon(from: ext.icon)
                    let target = MenuActionTarget {
                        let windowId = browserState?.windowId.int64Value ?? 0
                        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
                            withId: ext.id,
                            anchorRect: anchorView.flatMap(ExtensionPopupAnchor.rectOfView),
                            windowId: windowId
                        )
                    }
                    item.representedObject = target
                    item.target = target
                    item.action = #selector(MenuActionTarget.performAction(_:))
                    submenu.addItem(item)
                }
            }

            submenu.addItem(.separator())
            let manageItem = NSMenuItem(
                title: NSLocalizedString("browser.addressBarMenu.manageExtensionsAction", value: "Manage Extensions", comment: "Address bar menu - Extensions submenu item to open extension management"),
                action: nil,
                keyEquivalent: ""
            )
            let manageTarget = MenuActionTarget {
                let url = URLProcessor.processUserInput("phi://extensions")
                browserState?.createTab(url)
            }
            manageItem.representedObject = manageTarget
            manageItem.target = manageTarget
            manageItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(manageItem)

            return submenu
        }

        func buildSettingsSubmenu(_ url: String?) -> NSMenu {
            let submenu = NSMenu(title: NSLocalizedString("browser.addressBarMenu.siteSettingsSubmenu.title", value: "Site Settings", comment: "Address bar menu - Settings submenu title"))

            let windowId = browserState?.windowId ?? 0
            let clearCacheItem = NSMenuItem(
                title: NSLocalizedString("browser.addressBarMenu.clearCacheAction", value: "Clear Cache", comment: "Address bar menu - Settings submenu item to clear cache"),
                action: nil,
                keyEquivalent: ""
            )
            let clearCacheTarget = MenuActionTarget {
                ChromiumLauncher.sharedInstance()
                    .bridge?
                    .clearWebsiteCache(url ?? "", windowId: windowId.int64Value)
                
            }
            clearCacheItem.representedObject = clearCacheTarget
            clearCacheItem.target = clearCacheTarget
            clearCacheItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(clearCacheItem)

            let clearCookieItem = NSMenuItem(
                title: NSLocalizedString("browser.addressBarMenu.clearCookiesAction", value: "Clear Cookie", comment: "Address bar menu - Settings submenu item to clear cookie"),
                action: nil,
                keyEquivalent: ""
            )
            
            let clearCookieTarget = MenuActionTarget {
                ChromiumLauncher.sharedInstance()
                    .bridge?
                    .clearWebsiteCookies(url ?? "", windowId: windowId.int64Value)
            }
            clearCookieItem.representedObject = clearCookieTarget
            clearCookieItem.target = clearCookieTarget
            clearCookieItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(clearCookieItem)
            
            submenu.addItem(.separator())
            
            let moreSettingsItem = NSMenuItem(
                title: NSLocalizedString("browser.addressBarMenu.openBrowserSettingsAction", value: "More Settings", comment: "Address bar menu - Settings submenu item to open settings page"),
                action: nil,
                keyEquivalent: ""
            )
            let moreSettingsTarget = MenuActionTarget {
                let url = URLProcessor.processUserInput("chrome://settings/content/siteDetails?site=\(rawURLString)")
                browserState?.createTab(url)
            }
            moreSettingsItem.representedObject = moreSettingsTarget
            moreSettingsItem.target = moreSettingsTarget
            moreSettingsItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(moreSettingsItem)

            return submenu
        }

        // Share lives in this menu rather than as a standalone address bar
        // action; the File menu item and shortcut offer the same services.
        let shareItem = addMenuItem(
            title: NSLocalizedString("browser.addressBarMenu.shareSubmenu.title", value: "Share", comment: "Address bar menu - Share submenu title"),
            image: menuSymbol(named: "square.and.arrow.up")
        )
        MainActor.assumeIsolated {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                shareItem.preferredImageVisibility = .visible
            }
            #endif
            shareItem.submenu = PageSharingPresenter.shareSubmenu(for: resolvedTab)
        }

        menu.addItem(.separator())

        let settingsItem = addMenuItem(
            title: NSLocalizedString("browser.addressBarMenu.siteSettingsAction", value: "Site Settings", comment: "Address bar menu - Settings menu item"),
            image: menuSymbol(named: "gearshape")
        )
        settingsItem.submenu = buildSettingsSubmenu(rawURLString)

        // The page picks up the new rule set on its next load.
        if let contentBlocking = MainActor.assumeIsolated({
            SiteContentBlockingToggle.current(browserState: browserState, urlString: rawURLString)
        }) {
            let item = MainActor.assumeIsolated {
                contentBlocking.makeMenuItem { resolvedTab?.reload() }
            }
            item.image = menuSymbol(named: "shield.lefthalf.filled")
            menu.addItem(item)
        }

        // Stands in for the Site Memories button while it is not drawn.
        if showsSiteMemoriesEntry {
            let item = addMenuItem(
                title: NSLocalizedString("browser.webContentAddressBar.siteMemoriesAction", value: "Site Memories", comment: "Site Menu - Opens the memory controls for the current website; shown when the Site Memories button is not in the toolbar"),
                image: siteMemoriesMenuIcon()
            ) { [weak anchorView] in
                // Opens once the Site Menu has finished closing.
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated {
                        presentMemoryMenu(
                            browserState: browserState,
                            currentTab: resolvedTab,
                            anchorView: anchorView,
                            location: memoryMenuLocation
                        ) { _ in }
                    }
                }
            }
            item.identifier = siteMemoriesItemIdentifier
        }

        menu.addItem(.separator())

        let alwaysShowURLPath = PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
        addMenuItem(
            title: NSLocalizedString("browser.addressBarMenu.showFullURLToggle", value: "Always Show URL Path", comment: "Address bar menu - Toggle URL path visibility"),
            state: alwaysShowURLPath ? .on : .off
        ) {
            UserDefaults.standard.set(
                !alwaysShowURLPath,
                forKey: PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue
            )
        }

        if shouldShowSecuritySection(for: rawURLString) {
            menu.addItem(.separator())

            let securityInfo = resolvedTab?.securityInfo
            let isConnectionUnsafe = !(securityInfo?.isSecure ?? false)
            let isCertValid = certificateIsValid(from: securityInfo)
            let hasCertificates = !(securityInfo?.certificates.isEmpty ?? true)
            let securityItem = addMenuItem(
                title: securityStatusText(from: securityInfo),
                isEnabled: true,
                image: statusSymbol(
                    named: (securityInfo?.isSecure ?? false) ? "lock.fill" : "xmark.circle.fill",
                    isCritical: isConnectionUnsafe
                ),
                action:  hasCertificates ? {
                    showCertificatePanel(certificates: securityInfo?.certificates ?? [])
                } : nil
            )
            securityItem.indentationLevel = 0
            applyStatusColor(to: securityItem, isCritical: isConnectionUnsafe)

        }

        menu.addItem(.separator())
        menu.addItem(ToolbarCustomizationMenu.customizeItem(action: onCustomize))
        return menu
    }

    /// Pops the Site Memories menu under `anchorView`, or at `location` in
    /// it when given.
    @MainActor
    static func presentMemoryMenu(
        browserState: BrowserState?,
        currentTab: Tab?,
        anchorView: NSView?,
        location: NSPoint? = nil,
        onPresentationChanged: (Bool) -> Void
    ) {
        guard let anchorView = anchorView ?? browserState?.windowController?.window?.contentView,
              let actions = SiteMemoryMenuActions.current(
                browserState: browserState,
                urlString: (currentTab ?? browserState?.focusingTab)?.url ?? ""
              ) else { return }

        let menu = makeMemoryMenu(actions: actions, window: anchorView.window)
        onPresentationChanged(true)
        defer { onPresentationChanged(false) }
        anchorView.effectiveAppearance.performAsCurrentDrawingAppearance {
            menu.popUp(positioning: nil, at: location ?? NSPoint(x: 0, y: -6), in: anchorView)
        }
    }

    @MainActor
    static func makeMemoryMenu(actions: SiteMemoryMenuActions, window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addItem(title: String, state: NSControl.StateValue = .off,
                     isEnabled: Bool, image: NSImage? = nil, action: SiteMemoryMenuActions.Action) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.state = state
            item.isEnabled = isEnabled
            item.image = image
            let target = MenuActionTarget { actions.perform(action, window: window) }
            item.representedObject = target
            item.target = target
            item.action = #selector(MenuActionTarget.performAction(_:))
            menu.addItem(item)
        }

        addItem(title: SiteMemoryMenuActions.collectionTitle, state: actions.collectionState,
                isEnabled: actions.collectionEnabled != nil, action: .toggleCollection)
        addItem(title: SiteMemoryMenuActions.removalTitle, isEnabled: actions.canRemoveMemories,
                action: .removeMemories)
        return menu
    }

    private static func securityStatusText(from info: TabSecurityInfo?) -> String {
        guard let info else {
            return NSLocalizedString("browser.addressBarMenu.security.unknownStatus", value: "Unknown", comment: "Address bar menu - Website security unknown")
        }
        guard let isSecure = info.isSecure else {
            return NSLocalizedString("browser.addressBarMenu.security.partiallySecureStatus", value: "Connection is not fully secure", comment: "Address bar menu - Website security not fully secure")
        }
        return isSecure
            ? NSLocalizedString("browser.addressBarMenu.security.secureStatus", value: "Connection is secure", comment: "Address bar menu - Website security secure")
            : NSLocalizedString("browser.addressBarMenu.security.notSecureStatus", value: "Connection is not secure", comment: "Address bar menu - Website security not secure")
    }

    private static func certificateStatusText(from info: TabSecurityInfo?) -> String {
        return certificateIsValid(from: info)
            ? NSLocalizedString("browser.addressBarMenu.security.validCertificateStatus", value: "Certificate is valid", comment: "Address bar menu - Certificate validity status")
            : NSLocalizedString("browser.addressBarMenu.security.invalidCertificateStatus", value: "Certificate is invalid", comment: "Address bar menu - Certificate validity status")
    }

    private static func certificateIsValid(from info: TabSecurityInfo?) -> Bool {
        guard let info else {
            return false
        }

        let certStatus: UInt64 = {
            if let value = info.raw["certStatus"] as? UInt64 {
                return value
            }
            if let value = info.raw["certStatus"] as? Int {
                return UInt64(max(0, value))
            }
            if let value = info.raw["certStatus"] as? NSNumber {
                return value.uint64Value
            }
            return 1
        }()

        return certStatus == 0 && !info.certificates.isEmpty
    }

    private static func showCertificatePanel(certificates: [SecCertificate]) {
        guard !certificates.isEmpty else {
            return
        }
        guard let docWindow =
                SpaceSessionControllersManager.shared.activeWindowController?.window
                ?? NSApp.keyWindow else {
            return
        }

        let panel = SFCertificatePanel()
        panel.beginSheet(
            for: docWindow,
            modalDelegate: CertificatePanelSheetDelegate.shared,
            didEnd: #selector(CertificatePanelSheetDelegate.certificateSheetDidEnd(_:returnCode:contextInfo:)),
            contextInfo: nil,
            certificates: certificates,
            showGroup: certificates.count > 1
        )
    }

    private static func normalizedExtensionMenuIcon(from image: NSImage?) -> NSImage? {
        let targetSize = NSSize(width: 16, height: 16)
        guard let source = image else {
            return NSImage(
                systemSymbolName: "puzzlepiece.extension",
                accessibilityDescription: nil
            )
        }

        let normalized = NSImage(size: targetSize)
        normalized.lockFocus()

        let sourceSize = source.size
        let safeWidth = max(sourceSize.width, 1)
        let safeHeight = max(sourceSize.height, 1)
        let scale = min(targetSize.width / safeWidth, targetSize.height / safeHeight)
        let drawSize = NSSize(width: safeWidth * scale, height: safeHeight * scale)
        let drawOrigin = NSPoint(
            x: (targetSize.width - drawSize.width) * 0.5,
            y: (targetSize.height - drawSize.height) * 0.5
        )

        source.draw(
            in: NSRect(origin: drawOrigin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        normalized.unlockFocus()
        normalized.size = targetSize
        return normalized
    }

    private static func applyStatusColor(to item: NSMenuItem, isCritical: Bool) {
        guard isCritical else { return }
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
    }

    private static func statusSymbol(named systemName: String, isCritical: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        guard isCritical else {
            return base
        }
        if #available(macOS 11.0, *) {
            return base.withSymbolConfiguration(.init(hierarchicalColor: .systemRed)) ?? base
        }
        return base
    }

    private static func menuSymbol(named systemName: String) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    /// The Site Memories button's icon at menu size.
    private static func siteMemoriesMenuIcon() -> NSImage? {
        guard let icon = NSImage(named: "memory-manage-icon")?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = true
        return icon
    }

    private static func shouldShowSecuritySection(for rawURLString: String) -> Bool {
        let lowercased = rawURLString.lowercased()
        return !lowercased.hasPrefix("chrome://") && !lowercased.hasPrefix("phi://")
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import Security
import SecurityInterface

final class WebContentAddressBarMenuPresenter {
    private final class MenuActionTarget: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSMenuItem) {
            action()
        }
    }

    private static let excludedSharingServiceNames: Set<String> = [
        "com.apple.share.System.add-to-safari-reading-list"
    ]

    static func present(
        browserState: BrowserState?,
        currentTab: Tab?,
        anchorView: NSView?,
        onPresentationChanged: (Bool) -> Void
    ) {
        guard let anchorView = anchorView ?? browserState?.windowController?.window?.contentView else {
            return
        }

        let resolvedTab = currentTab ?? browserState?.focusingTab
        let extensionManager = browserState?.extensionManager
        extensionManager?.refreshExtensions()
        let rawURLString = resolvedTab?.url ?? ""
        let brandedURLString = URLProcessor.phiBrandEnsuredUrlString(rawURLString)

        var actionTargets: [MenuActionTarget] = []
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
                actionTargets.append(target)
                item.target = target
                item.action = #selector(MenuActionTarget.performAction(_:))
            }
            menu.addItem(item)
            return item
        }

        func buildShareSubmenu(urlString: String?) -> NSMenu {
            let submenu = NSMenu(title: NSLocalizedString("Share", comment: "Address bar menu - Share submenu title"))
            guard
                let urlString,
                let url = URL(string: urlString)
            else {
                let unavailableItem = NSMenuItem(
                    title: NSLocalizedString("No share actions available", comment: "Address bar menu - Empty share submenu item"),
                    action: nil,
                    keyEquivalent: ""
                )
                unavailableItem.isEnabled = false
                submenu.addItem(unavailableItem)
                return submenu
            }

            let services = NSSharingService.sharingServices(forItems: [url])
                .filter { !isReadingListSharingService($0) }
            if services.isEmpty {
                let unavailableItem = NSMenuItem(
                    title: NSLocalizedString("No share actions available", comment: "Address bar menu - Empty share submenu item"),
                    action: nil,
                    keyEquivalent: ""
                )
                unavailableItem.isEnabled = false
                submenu.addItem(unavailableItem)
                return submenu
            }

            for service in services {
                let item = NSMenuItem(title: service.title, action: nil, keyEquivalent: "")
                item.image = service.image
                let target = MenuActionTarget {
                    service.perform(withItems: [url])
                }
                actionTargets.append(target)
                item.target = target
                item.action = #selector(MenuActionTarget.performAction(_:))
                submenu.addItem(item)
            }

            return submenu
        }

        func buildExtensionsSubmenu() -> NSMenu {
            let submenu = NSMenu(title: NSLocalizedString("Extensions", comment: "Address bar menu - Extensions submenu title"))
            let extensions = extensionManager?.extensions ?? []

            if extensions.isEmpty {
                let emptyItem = NSMenuItem(
                    title: NSLocalizedString("No extensions found", comment: "Address bar menu - Empty extension submenu item"),
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
                        let mouseLocation = NSEvent.mouseLocation
                        guard let screen = NSScreen.main else { return }
                        let convertedLocation = NSPoint(
                            x: mouseLocation.x,
                            y: screen.frame.height - mouseLocation.y
                        )
                        let windowId = browserState?.windowId.int64Value ?? 0
                        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
                            withId: ext.id,
                            pointInScreen: convertedLocation,
                            windowId: windowId
                        )
                    }
                    actionTargets.append(target)
                    item.target = target
                    item.action = #selector(MenuActionTarget.performAction(_:))
                    submenu.addItem(item)
                }
            }

            submenu.addItem(.separator())
            let manageItem = NSMenuItem(
                title: NSLocalizedString("Manage Extensions", comment: "Address bar menu - Extensions submenu item to open extension management"),
                action: nil,
                keyEquivalent: ""
            )
            let manageTarget = MenuActionTarget {
                let url = URLProcessor.processUserInput("phi://extensions")
                browserState?.createTab(url)
            }
            actionTargets.append(manageTarget)
            manageItem.target = manageTarget
            manageItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(manageItem)

            return submenu
        }

        func buildSettingsSubmenu(_ url: String?) -> NSMenu {
            let submenu = NSMenu(title: NSLocalizedString("Site Settings", comment: "Address bar menu - Settings submenu title"))

            let windowId = browserState?.windowId ?? 0
            let clearCacheItem = NSMenuItem(
                title: NSLocalizedString("Clear Cache", comment: "Address bar menu - Settings submenu item to clear cache"),
                action: nil,
                keyEquivalent: ""
            )
            let clearCacheTarget = MenuActionTarget {
                ChromiumLauncher.sharedInstance()
                    .bridge?
                    .clearWebsiteCache(url ?? "", windowId: windowId.int64Value)
                
            }
            actionTargets.append(clearCacheTarget)
            clearCacheItem.target = clearCacheTarget
            clearCacheItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(clearCacheItem)

            let clearCookieItem = NSMenuItem(
                title: NSLocalizedString("Clear Cookie", comment: "Address bar menu - Settings submenu item to clear cookie"),
                action: nil,
                keyEquivalent: ""
            )
            
            let clearCookieTarget = MenuActionTarget {
                ChromiumLauncher.sharedInstance()
                    .bridge?
                    .clearWebsiteCookies(url ?? "", windowId: windowId.int64Value)
            }
            actionTargets.append(clearCookieTarget)
            clearCookieItem.target = clearCookieTarget
            clearCookieItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(clearCookieItem)
            
            submenu.addItem(.separator())
            
            let moreSettingsItem = NSMenuItem(
                title: NSLocalizedString("More Settings", comment: "Address bar menu - Settings submenu item to open settings page"),
                action: nil,
                keyEquivalent: ""
            )
            let moreSettingsTarget = MenuActionTarget {
                let url = URLProcessor.processUserInput("chrome://settings/content/siteDetails?site=\(rawURLString)")
                browserState?.createTab(url)
            }
            actionTargets.append(moreSettingsTarget)
            moreSettingsItem.target = moreSettingsTarget
            moreSettingsItem.action = #selector(MenuActionTarget.performAction(_:))
            submenu.addItem(moreSettingsItem)

            return submenu
        }

        addMenuItem(
            title: NSLocalizedString("Copy Link", comment: "Address bar menu - Copy link menu item"),
            isEnabled: !brandedURLString.isEmpty,
            image: menuSymbol(named: "link")
        ) {
            guard !brandedURLString.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brandedURLString, forType: .string)
        }
        menu.addItem(.separator())

        let settingsItem = addMenuItem(
            title: NSLocalizedString("Site Settings", comment: "Address bar menu - Settings menu item"),
            image: menuSymbol(named: "gearshape")
        )
        settingsItem.submenu = buildSettingsSubmenu(rawURLString)

        menu.addItem(.separator())

        let alwaysShowURLPath = PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
        addMenuItem(
            title: NSLocalizedString("Always Show URL Path", comment: "Address bar menu - Toggle URL path visibility"),
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

        onPresentationChanged(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: anchorView)
        onPresentationChanged(false)

        _ = actionTargets
    }

    private static func securityStatusText(from info: TabSecurityInfo?) -> String {
        guard let info else {
            return NSLocalizedString("Unknown", comment: "Address bar menu - Website security unknown")
        }
        guard let isSecure = info.isSecure else {
            return NSLocalizedString("Connection is not fully secure", comment: "Address bar menu - Website security not fully secure")
        }
        return isSecure
            ? NSLocalizedString("Connection is secure", comment: "Address bar menu - Website security secure")
            : NSLocalizedString("Connection is not secure", comment: "Address bar menu - Website security not secure")
    }

    private static func certificateStatusText(from info: TabSecurityInfo?) -> String {
        return certificateIsValid(from: info)
            ? NSLocalizedString("Certificate is valid", comment: "Address bar menu - Certificate validity status")
            : NSLocalizedString("Certificate is invalid", comment: "Address bar menu - Certificate validity status")
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
                MainBrowserWindowControllersManager.shared.activeWindowController?.window
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

    private static func isReadingListSharingService(_ service: NSSharingService) -> Bool {
        let nameSelector = NSSelectorFromString("name")
        if service.responds(to: nameSelector),
           let unmanaged = service.perform(nameSelector),
           let name = unmanaged.takeUnretainedValue() as? String,
           excludedSharingServiceNames.contains(name) {
            return true
        }

        let loweredTitle = service.title.lowercased()
        if loweredTitle.contains("reading list") {
            return true
        }

        return false
    }

    private static func shouldShowSecuritySection(for rawURLString: String) -> Bool {
        let lowercased = rawURLString.lowercased()
        return !lowercased.hasPrefix("chrome://") && !lowercased.hasPrefix("phi://")
    }
}

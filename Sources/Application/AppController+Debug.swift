// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftUI
import AppKit
import WebKit
private final class DebugWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private enum DebugWindowStore {
    static var sentryWindow: NSWindow?
    static var sentryDelegate: DebugWindowDelegate?

    // Associated object keys for extension message debug panel
    nonisolated(unsafe) static var typeFieldKey: UInt8 = 0
    nonisolated(unsafe) static var requestIdFieldKey: UInt8 = 0
    nonisolated(unsafe) static var payloadTextViewKey: UInt8 = 0
    nonisolated(unsafe) static var panelKey: UInt8 = 0
}

#if DEBUG
private enum ImagePreviewDebugSamples {
    private static let repoRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func demoItems() -> [ImagePreviewItem] {
        localItems() + remoteItems()
    }

    private static func localItems() -> [ImagePreviewItem] {
        let localFiles: [(path: String, title: String)] = [
            ("build-scripts/background@2x.png", "Local Debug Background"),
            ("Resources/Assets.xcassets/AppIconCanary.appiconset/512@2x.png", "Local App Icon 512@2x"),
            ("Resources/Assets.xcassets/oobe-pre-animation-frames/oobe-pre-1.imageset/oobe-pre-1.jpg", "Local OOBE Frame")
        ]

        return localFiles.compactMap { sample in
            let fileURL = repoRootURL.appendingPathComponent(sample.path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }

            return ImagePreviewItem(
                id: "debug-local-\(sample.title)",
                source: .localFile(fileURL),
                title: sample.title,
                mimeType: nil,
                suggestedFilename: fileURL.lastPathComponent
            )
        }
    }

    private static func remoteItems() -> [ImagePreviewItem] {
        let remoteFiles: [(url: String, title: String, mimeType: String?)] = [
            ("https://httpbin.org/image/png", "Remote PNG", "image/png"),
            ("https://httpbin.org/image/jpeg", "Remote JPEG", "image/jpeg"),
            ("https://www.gstatic.com/webp/gallery/1.webp", "Remote WebP", "image/webp")
        ]

        return remoteFiles.compactMap { sample in
            guard let url = URL(string: sample.url) else { return nil }
            return ImagePreviewItem(
                id: "debug-remote-\(sample.title)",
                source: .remoteURL(url),
                title: sample.title,
                mimeType: sample.mimeType,
                suggestedFilename: url.lastPathComponent
            )
        }
    }
}
#endif

extension AppController {
    func buildDebugMenuItem() -> NSMenuItem {
        let debugMenu = NSMenu(title: "*DEBUG*")
        let debugMenuItem = NSMenuItem(title: "*DEBUG*", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu

        let debugSentryItem = NSMenuItem(title: "Debug Sentry",
                                         action: #selector(showSentryDebugWindow(_:)),
                                         keyEquivalent: "")
        debugSentryItem.target = self
        debugMenu.addItem(debugSentryItem)
        
        let deeplinkItem = NSMenuItem(title: "Trigger Deeplink...",
                                      action: #selector(triggerDeeplink(_:)),
                                      keyEquivalent: "")
        deeplinkItem.target = self
        debugMenu.addItem(deeplinkItem)
        
        let clearDataMenuItem = NSMenuItem(title: "Clear Data", action: nil, keyEquivalent: "")
        let clearDataSubmenu = NSMenu(title: "ClearData")
        
        let clearUserDataItem = NSMenuItem(title: "User Data", action: #selector(clearUserData(_:)), keyEquivalent: "")
        clearUserDataItem.target = self
        clearDataSubmenu.addItem(clearUserDataItem)
        
        let clearLoginStatusItem = NSMenuItem(title: "Login Status", action: #selector(clearLoginStatus(_:)), keyEquivalent: "")
        clearLoginStatusItem.target = self
        clearDataSubmenu.addItem(clearLoginStatusItem)
        
        let allItem = NSMenuItem(title: "All User Data", action: #selector(clearAllUserData(_:)), keyEquivalent: "")
        allItem.target = self
        clearDataSubmenu.addItem(allItem)
        
        clearDataMenuItem.submenu = clearDataSubmenu
        debugMenu.addItem(clearDataMenuItem)
        
        let sendCardItem = NSMenuItem(
            title: "Send Test Notification Card",
            action: #selector(sendTestNotificationCard(_:)),
            keyEquivalent: ""
        )
        sendCardItem.target = self
        debugMenu.addItem(sendCardItem)

        let sendExtMsgItem = NSMenuItem(
            title: "Send Extension Message...",
            action: #selector(showExtensionMessageDialog(_:)),
            keyEquivalent: ""
        )
        sendExtMsgItem.target = self
        debugMenu.addItem(sendExtMsgItem)

#if DEBUG
        let imagePreviewDemoItem = NSMenuItem(
            title: "Open Image Preview Demo",
            action: #selector(openImagePreviewDemo(_:)),
            keyEquivalent: ""
        )
        imagePreviewDemoItem.target = self
        debugMenu.addItem(imagePreviewDemoItem)
#endif
        
        let themeMenuItem = NSMenuItem(title: "Debug Theme", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu(title: "Debug Theme")
        themeSubmenu.delegate = self
        
        let themsTitle = NSMenuItem(title: "Themes", action: nil, keyEquivalent: "")
        themsTitle.isEnabled = false
        themeSubmenu.addItem(themsTitle)
        
        let defaultItem = NSMenuItem(title: "Default", action: #selector(switchToTheme(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = Theme.default.id
        themeSubmenu.addItem(defaultItem)
        
        let oceanItem = NSMenuItem(title: "Ocean", action: #selector(switchToTheme(_:)), keyEquivalent: "")
        oceanItem.target = self
        oceanItem.representedObject = "ocean"
        themeSubmenu.addItem(oceanItem)
        
        let forestItem = NSMenuItem(title: "Forest", action: #selector(switchToTheme(_:)), keyEquivalent: "")
        forestItem.target = self
        forestItem.representedObject = "forest"
        themeSubmenu.addItem(forestItem)
        
        let sunsetItem = NSMenuItem(title: "Sunset", action: #selector(switchToTheme(_:)), keyEquivalent: "")
        sunsetItem.target = self
        sunsetItem.representedObject = "sunset"
        themeSubmenu.addItem(sunsetItem)
        
        let violetItem = NSMenuItem(title: "Violet", action: #selector(switchToTheme(_:)), keyEquivalent: "")
        violetItem.target = self
        violetItem.representedObject = "violet"
        themeSubmenu.addItem(violetItem)
        
        themeSubmenu.addItem(NSMenuItem.separator())
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.isEnabled = false
        themeSubmenu.addItem(appearance)
        
        let system = NSMenuItem(title: "System", action: #selector(switchAppearance(_:)), keyEquivalent: "")
        system.representedObject = "system"
        system.target = self
        themeSubmenu.addItem(system)
        
        let light = NSMenuItem(title: "Light", action: #selector(switchAppearance(_:)), keyEquivalent: "")
        light.representedObject = "light"
        light.target = self
        themeSubmenu.addItem(light)
        
        let dark = NSMenuItem(title: "Dark", action: #selector(switchAppearance(_:)), keyEquivalent: "")
        dark.representedObject = "dark"
        dark.target = self
        themeSubmenu.addItem(dark)
        
        themeMenuItem.submenu = themeSubmenu
        debugMenu.addItem(themeMenuItem)
        
        debugMenu.addItem(NSMenuItem.separator())
        
        let openUserDirItem = NSMenuItem(
            title: NSLocalizedString("Open User Data Directory", comment: "Debug menu item to reveal the current user's data storage directory in Finder"),
            action: #selector(openUserDataDirectory(_:)),
            keyEquivalent: ""
        )
        openUserDirItem.target = self
        debugMenu.addItem(openUserDirItem)
        
        return debugMenuItem
    }
    
    // MARK: - Theme Switching Actions
    
    private static let debugThemes: [String: Theme] = [
        "ocean": .ocean,
        "forest": .forest,
        "sunset": .sunset,
        "violet": .violet
    ]
    
    private var activeBrowserThemeContext: BrowserThemeContext? {
        NSApp.keyWindow?.browserThemeContext
    }
    
    private var activeBrowserState: BrowserState? {
        (NSApp.keyWindow?.windowController as? MainBrowserWindowController)?.browserState
    }
    
    private var activeBrowserIsIncognito: Bool {
        activeBrowserState?.isIncognito == true
    }
    
    private func resolvedDebugTheme(for themeId: String) -> Theme {
        if themeId == Theme.default.id {
            return .default
        }
        return Self.debugThemes[themeId] ?? .default
    }
    
    @objc func switchToTheme(_ sender: NSMenuItem) {
        guard let themeId = sender.representedObject as? String else { return }
        let theme = resolvedDebugTheme(for: themeId)
        
        ThemeManager.shared.registerTheme(theme)
        
        if let context = activeBrowserThemeContext {
            context.setTheme(theme)
            return
        }
        
        ThemeManager.shared.switchTheme(to: themeId)
    }
    
    
    @objc func switchAppearance(_ sender: NSMenuItem) {
        guard let appearance = sender.representedObject as? String else { return }
        let choice: UserAppearanceChoice
        switch appearance {
        case "dark":
            choice = .dark
        case "light":
            choice = .light
        default:
            choice = .system
        }
        
        if let context = activeBrowserThemeContext {
            if activeBrowserIsIncognito {
                context.setUserAppearanceChoice(.dark)
            } else {
                context.setUserAppearanceChoice(choice)
            }
            return
        }
        
        ThemeManager.shared.setUserAppearanceChoice(choice)
    }
    
    @objc func sendTestNotificationCard(_ sender: Any?) {
        func sendTestMessage(title: String, buttonTitle: String, description: String) {
            let messageId = "debug-\(UUID().uuidString)"
            
            let innerPayload: [String: Any] = [
                "type": "agent_task_request",
                "task_id": messageId,
                "task_type": "research",
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "title": title,
                "description": description,
                "expires_at": Int64((Date().timeIntervalSince1970 + 60) * 1000),
                "button_title": buttonTitle
            ]
            
            let envelope: [String: Any] = [
                "action": "notification.card.request",
                "messageId": messageId,
                "payload": innerPayload
            ]
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }
            
            let requestId = "debug-request-\(messageId)"
            _ = PhiChromiumCoordinator.shared.handleExtensionMessage(
                "notification",
                payload: jsonString,
                requestId: requestId,
                senderId: "debug-extension"
            )
        }
        
        sendTestMessage(
            title: "Debug Notification 1",
            buttonTitle: "Run",
            description: "This is a test notification card for debugging purposes 1."
        )
        
        sendTestMessage(
            title: "Debug Notification 2",
            buttonTitle: "Search XXXXXXXXXXXXXXXXXXXXX",
            description: "This is a test notification card for debugging purposes. Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text Long Text"
        )
        
        sendTestMessage(
            title: "Debug Notification 3",
            buttonTitle: "Go",
            description: "This is a test notification card for debugging purposes."
        )
    }

#if DEBUG
    @MainActor
    @objc func openImagePreviewDemo(_ sender: Any?) {
        guard let controller = MainBrowserWindowControllersManager.shared.activeWindowController else {
            let alert = NSAlert()
            alert.messageText = "No Active Browser Window"
            alert.informativeText = "Open a browser window first, then try the image preview demo again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        controller.browserState.imagePreviewState.open(
            items: ImagePreviewDebugSamples.demoItems(),
            currentIndex: 0
        )
    }
#endif
    
    @MainActor
    @objc func triggerDeeplink(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Trigger Deeplink"
        alert.informativeText = "Enter the full deeplink URL to handle."
        alert.addButton(withTitle: "Handle")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = "phi://native/openpage?page=settings"
        textField.placeholderString = "Input deeplink to trigger"
        alert.accessoryView = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let urlString = textField.stringValue
            guard !urlString.isEmpty, let url = URL(string: urlString) else {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Invalid URL"
                errorAlert.informativeText = "The entered text could not be parsed as a valid URL."
                errorAlert.alertStyle = .critical
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
                return
            }

            let _ = DeeplinkHandler.handle(url)
        }
    }
    
    @MainActor @objc func showSentryDebugWindow(_ sender: Any?) {
        if let window = DebugWindowStore.sentryWindow {
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let hostingController = NSHostingController(rootView: CrashSampleView())
        let windowSize = NSSize(width: 560, height: 680)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sentry Crash Samples"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setContentSize(windowSize)
        window.minSize = NSSize(width: 400, height: 480)

        let delegate = DebugWindowDelegate()
        delegate.onClose = {
            DebugWindowStore.sentryWindow = nil
            DebugWindowStore.sentryDelegate = nil
        }
        window.delegate = delegate

        DebugWindowStore.sentryWindow = window
        DebugWindowStore.sentryDelegate = delegate

        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    @MainActor
    @objc func showExtensionMessageDialog(_ sender: Any?) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Send Extension Message"
        panel.isFloatingPanel = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        let margin: CGFloat = 16
        let labelWidth: CGFloat = 70
        let fieldX = margin + labelWidth + 8
        let fieldWidth = 520 - fieldX - margin
        var y: CGFloat = 380

        func addLabel(_ text: String, at yPos: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: margin, y: yPos, width: labelWidth, height: 20)
            label.alignment = .right
            container.addSubview(label)
        }

        func addTextField(placeholder: String, value: String, at yPos: CGFloat) -> NSTextField {
            let field = NSTextField(frame: NSRect(x: fieldX, y: yPos, width: fieldWidth, height: 24))
            field.placeholderString = placeholder
            field.stringValue = value
            container.addSubview(field)
            return field
        }

        addLabel("Type:", at: y)
        let typeField = addTextField(placeholder: "showDialog / notification / imagePreview", value: "showDialog", at: y)

        y -= 36
        addLabel("Request ID:", at: y)
        let requestIdField = addTextField(placeholder: "auto-generated if empty", value: "", at: y)

        y -= 30
        addLabel("Payload:", at: y)

        let scrollView = NSScrollView(frame: NSRect(x: fieldX, y: 60, width: fieldWidth, height: y - 50))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let windowId = MainBrowserWindowControllersManager.shared.activeWindowController?.windowId ?? 0
        let samplePayload = """
        {
          "sessionId": "debug-\(UUID().uuidString.prefix(8))",
          "windowId": \(windowId),
          "content": {
            "html": "<!DOCTYPE html><html><head><meta charset=\\"utf-8\\"><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,sans-serif;padding:20px}h2{font-size:16px;margin-bottom:16px}input{width:100%;padding:8px 12px;border:1px solid #ccc;border-radius:6px;font-size:14px;margin-bottom:20px}.actions{display:flex;justify-content:flex-end;gap:8px}button{padding:6px 16px;border-radius:6px;font-size:14px;cursor:pointer;border:none}.cancel{background:#E5E5EA;color:#333}.confirm{background:#007AFF;color:#fff}</style></head><body><h2>Enter your name</h2><input id=\\"nameInput\\" type=\\"text\\" placeholder=\\"Your name...\\"><div class=\\"actions\\"><button class=\\"cancel\\" onclick=\\"phiMacClient.close()\\">Cancel</button><button class=\\"confirm\\" onclick=\\"phiMacClient.postMessage({name:document.getElementById('nameInput').value});phiMacClient.close()\\">OK</button></div></body></html>",
            "title": "Debug Dialog",
            "width": 400,
            "height": 200
          }
        }
        """
        textView.string = samplePayload

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        container.addSubview(scrollView)

        let sendButton = NSButton(title: "Send", target: nil, action: nil)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.frame = NSRect(x: 520 - margin - 80, y: 16, width: 80, height: 28)
        container.addSubview(sendButton)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 520 - margin - 80 - 88, y: 16, width: 80, height: 28)
        container.addSubview(cancelButton)

        panel.contentView = container

        sendButton.target = self
        sendButton.action = #selector(debugSendExtensionMessage(_:))
        sendButton.tag = 1

        cancelButton.target = self
        cancelButton.action = #selector(debugSendExtensionMessage(_:))
        cancelButton.tag = 0

        panel.center()
        panel.makeKeyAndOrderFront(nil)

        objc_setAssociatedObject(panel, &DebugWindowStore.typeFieldKey, typeField, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, &DebugWindowStore.requestIdFieldKey, requestIdField, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, &DebugWindowStore.payloadTextViewKey, textView, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(sendButton, &DebugWindowStore.panelKey, panel, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(cancelButton, &DebugWindowStore.panelKey, panel, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func debugSendExtensionMessage(_ sender: NSButton) {
        guard let panel = objc_getAssociatedObject(sender, &DebugWindowStore.panelKey) as? NSPanel else { return }

        defer { panel.close() }
        guard sender.tag == 1 else { return }

        guard let typeField = objc_getAssociatedObject(panel, &DebugWindowStore.typeFieldKey) as? NSTextField,
              let requestIdField = objc_getAssociatedObject(panel, &DebugWindowStore.requestIdFieldKey) as? NSTextField,
              let textView = objc_getAssociatedObject(panel, &DebugWindowStore.payloadTextViewKey) as? NSTextView else { return }

        let type = typeField.stringValue
        let payload = textView.string
        let requestId = requestIdField.stringValue.isEmpty
            ? "debug-request-\(UUID().uuidString)"
            : requestIdField.stringValue

        guard !type.isEmpty else { return }

        AppLogInfo("[Debug] Sending extension message - type: \(type), requestId: \(requestId)")
        _ = PhiChromiumCoordinator.shared.handleExtensionMessage(
            type,
            payload: payload,
            requestId: requestId,
            senderId: "debug-extension"
        )
    }

    @objc func openUserDataDirectory(_ sender: Any?) {
        guard let url = AccountController.shared.account?.userDataStorage else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
    
    @MainActor
    @objc func clearLoginStatus(_ sender: Any?) {
        guard showQuitAlert() else {
            return
        }
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

       
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, for: records) {
                print("✅ All WKWebView cookies, cache, and website data cleared.")
            }
            AuthManager.shared.clearLocalCredentials()
            NSApp.terminate(nil)
        }
        
        LoginController.shared.phase = .login
    }
    
    @MainActor
    @objc func clearAllUserData(_ sender: Any?) {
        guard showQuitAlert() else {
            return
        }
        _clearUserData()
        AuthManager.shared.clearLocalCredentials()
        LoginController.shared.phase = .login
        NSApp.terminate(nil)
    }
    
    @MainActor
    @objc func clearUserData(_ sender: Any?) {
        guard showQuitAlert() else {
            return
        }
        _clearUserData()
        NSApp.terminate(nil)
    }
    
    private func _clearUserData() {
        let appDir = FileSystemUtils.applicationSupportDirctory()
        let cachDir = FileSystemUtils.cacheDirctory()
        let plistPath = FileSystemUtils.plistPath()
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: appDir) {
                try fm.removeItem(atPath: appDir)
            }
            if fm.fileExists(atPath: cachDir) {
                try fm.removeItem(atPath: cachDir)
            }
            
            if fm.fileExists(atPath: plistPath) {
                try fm.removeItem(atPath: plistPath)
            }
        } catch {
            let nsError = error as NSError
            // Ignore "no such file" errors; log others for debugging
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                NSLog("[Debug] Failed to remove appDir at \(appDir): \(nsError)")
            }
        }
    }
    
    @MainActor
    func showQuitAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Please confirm this operation"
        alert.informativeText = " The app will quit immediately after the operation"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Confirm")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - NSMenuDelegate for Theme Menu

extension AppController {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Debug Theme" else { return }
        
        let context = NSApp.keyWindow?.browserThemeContext
        let isIncognito = activeBrowserIsIncognito
        let currentThemeId = context?.currentTheme.id ?? ThemeManager.shared.currentTheme.id
        let appearance = context?.userAppearanceChoice ?? ThemeManager.shared.userAppearanceChoice
        for item in menu.items {
            guard let themeId = item.representedObject as? String else { continue }
            item.state = (themeId == currentThemeId) ? .on : .off
            if ["system", "light", "dark"].contains(themeId) {
                item.state = (themeId == appearance.identifier) ? .on : .off
                if isIncognito {
                    item.isEnabled = (themeId == UserAppearanceChoice.dark.identifier)
                } else {
                    item.isEnabled = true
                }
            } else {
                item.isEnabled = true
            }
        }
    }
}
extension UserAppearanceChoice {
    var identifier: String {
        switch self {
        case .system:
            return "system"
        case .light:
            return "light"
        case .dark:
            return "dark"
        }
    }
}

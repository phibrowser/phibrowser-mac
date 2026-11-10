// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

final class TabAreaContextMenuHelper: NSObject {

    private weak var browserState: BrowserState?
    private let isHorizontalLayout: Bool

    init(browserState: BrowserState, isHorizontalLayout: Bool = false) {
        self.browserState = browserState
        self.isHorizontalLayout = isHorizontalLayout
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Disable New Tab while the agent controls this Space: the user must not
        // add tabs to the agent's workspace until they take control. Nil action
        // greys it out via AppKit's automatic menu enabling.
        let agentLocked = MainActor.assumeIsolated {
            AgentSpaceManager.shared.isAgentOwned(browserState?.spaceId ?? "")
        }
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("common.tabAreaContextMenu.newTabAction", value: "New Tab", comment: "Tab area context menu - Open a new browser tab"),
            action: agentLocked ? nil : #selector(newTab),
            keyEquivalent: "t"
        ).configured { $0.keyEquivalentModifierMask = .command; $0.target = agentLocked ? nil : self })

        menu.addItem(NSMenuItem(
            title: NSLocalizedString("common.tabAreaContextMenu.reopenClosedTabAction", value: "Reopen Closed Tab", comment: "Tab area context menu - Reopen the last closed tab"),
            action: #selector(reopenClosedTab),
            keyEquivalent: "t"
        ).configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        // Bookmark writes are unavailable off-the-record, so incognito
        // windows skip the folder/bookmark block entirely.
        if browserState?.isIncognito != true {
            menu.addItem(.separator())

            menu.addItem(NSMenuItem(
                title: NSLocalizedString("common.tabAreaContextMenu.newBookmarkFolderAction", value: "New Folder", comment: "Tab area context menu - Create a new bookmark folder"),
                action: #selector(newFolder),
                keyEquivalent: ""
            ).configured { $0.target = self })

            let hasBookmarkableTabs = browserState?.normalTabs.contains { !$0.isLocalPage } ?? false
            menu.addItem(NSMenuItem(
                title: NSLocalizedString("common.tabAreaContextMenu.bookmarkAllTabsAction", value: "Bookmark All Tabs", comment: "Tab area context menu - Bookmark all open tabs"),
                action: hasBookmarkableTabs ? #selector(bookmarkAllTabs) : nil,
                keyEquivalent: "d"
            ).configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })
        }

        menu.addItem(.separator())

        let layoutItem = NSMenuItem(
            title: NSLocalizedString("common.tabAreaContextMenu.layoutModeSubmenu", value: "Layout Mode", comment: "Tab area context menu - Switch layout mode"),
            action: nil,
            keyEquivalent: ""
        )
        layoutItem.submenu = buildLayoutSubmenu()
        menu.addItem(layoutItem)

        // Active-Space controls, mirroring the Spaces menu / Space right-click.
        // Only surface them while the Spaces feature is enabled and the window
        // participates in Spaces — standalone incognito windows expose none;
        // the Incognito Space's window does.
        if PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue(),
           let browserState,
           browserState.participatesInSpaces == true {
            menu.addItem(.separator())
            AppController.shared?.appendActiveSpaceMenuItems(
                to: menu,
                browserState: browserState,
                triggerScreenPoint: NSEvent.mouseLocation
            )
        }

        if !isHorizontalLayout {
            menu.addItem(.separator())
            let bottomButtonsItem = NSMenuItem(
                title: NSLocalizedString("common.tabAreaContextMenu.bottomButtonsSubmenu", value: "Bottom Buttons", comment: "Tab area context menu - Submenu to choose which buttons the sidebar bottom bar shows"),
                action: nil,
                keyEquivalent: ""
            )
            bottomButtonsItem.submenu = buildBottomButtonsSubmenu()
            menu.addItem(bottomButtonsItem)
        }
    }

    @objc private func newTab() {
        browserState?.windowController?.newBrowserTab(nil)
    }

    @objc private func reopenClosedTab() {
        guard let state = browserState else { return }
        ChromiumLauncher.sharedInstance().bridge?.executeCommand(
            Int32(CommandWrapper.IDC_RESTORE_TAB.rawValue),
            windowId: Int64(state.windowId)
        )
    }

    @MainActor @objc private func newFolder() {
        guard let state = browserState else { return }
        if isHorizontalLayout {
            EditPinnedTabPresenter.presentModal(
                mode: .newFolder,
                from: state.windowController?.window
            ) { result in
                guard let folderName = result.title, !folderName.isEmpty else { return }
                state.bookmarkManager.addFolder(title: folderName)
            }
        } else {
            let untitledName = NSLocalizedString("common.bookmarkFolder.defaultName", value: "Untitled", comment: "Default name for new bookmark folder in root")
            state.bookmarkManager.addFolderWithEditing(title: untitledName, to: nil)
        }
    }

    @objc private func bookmarkAllTabs() {
        guard let state = browserState else { return }
        let tabs = state.normalTabs
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            if tab.isLocalPage { continue }
            let title = tab.title.isEmpty ? (tab.url ?? "") : tab.title
            let url = tab.url ?? ""
            guard !url.isEmpty else { continue }
            state.bookmarkManager.addBookmark(title: title,
                                              url: url,
                                              faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
        }
    }

    @objc private func switchLayoutMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: rawValue) else { return }
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
    }

    @objc private func toggleBottomButton(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let setting = PhiPreferences.GeneralSettings(rawValue: rawValue) else { return }
        UserDefaults.standard.set(!setting.loadValue(), forKey: setting.rawValue)
    }

    // MARK: - Private

    private func buildBottomButtonsSubmenu() -> NSMenu {
        var entries: [(PhiPreferences.GeneralSettings, String)] = [
            (.sidebarBottomBarShowsProfile,
             NSLocalizedString("common.tabAreaContextMenu.bottomButtons.profile", value: "Profile", comment: "Tab area context menu - Bottom Buttons submenu item that shows or hides the profile button")),
            (.sidebarBottomBarShowsDownloads,
             NSLocalizedString("common.tabAreaContextMenu.bottomButtons.downloads", value: "Downloads", comment: "Tab area context menu - Bottom Buttons submenu item that shows or hides the downloads button")),
        ]
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        if phiAIEnabled, browserState?.isIncognito != true {
            entries.append((.sidebarBottomBarShowsMemory,
                            NSLocalizedString("common.tabAreaContextMenu.bottomButtons.memory", value: "Memory", comment: "Tab area context menu - Bottom Buttons submenu item that shows or hides the AI memory button")))
        }
        if !ApplicationState.shared.isGuest {
            entries.append((.sidebarBottomBarShowsFeedback,
                            NSLocalizedString("common.tabAreaContextMenu.bottomButtons.feedback", value: "Feedback", comment: "Tab area context menu - Bottom Buttons submenu item that shows or hides the feedback button")))
        }

        let submenu = NSMenu()
        for (setting, title) in entries {
            let item = NSMenuItem(
                title: title,
                action: #selector(toggleBottomButton(_:)),
                keyEquivalent: ""
            )
            item.representedObject = setting.rawValue
            item.target = self
            item.state = setting.loadValue() ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildLayoutSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentMode = browserState?.layoutMode
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(switchLayoutMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            item.target = self
            item.state = (mode == currentMode) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }
}

private extension NSMenuItem {
    func configured(_ block: (NSMenuItem) -> Void) -> NSMenuItem {
        block(self)
        return self
    }
}

extension Tab {
    var isLocalPage: Bool {
        guard let url = url else { return false }
        return url.hasPrefix("chrome://") ||
        url.hasPrefix("phi://") ||
        url.hasPrefix("chrome-extension")
    }
}

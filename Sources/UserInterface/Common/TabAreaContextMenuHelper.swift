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

        menu.addItem(NSMenuItem(
            title: NSLocalizedString("New Tab", comment: "Tab area context menu - Open a new browser tab"),
            action: #selector(newTab),
            keyEquivalent: "t"
        ).configured { $0.keyEquivalentModifierMask = .command; $0.target = self })

        menu.addItem(NSMenuItem(
            title: NSLocalizedString("Reopen Closed Tab", comment: "Tab area context menu - Reopen the last closed tab"),
            action: #selector(reopenClosedTab),
            keyEquivalent: "t"
        ).configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: NSLocalizedString("New Folder", comment: "Tab area context menu - Create a new bookmark folder"),
            action: #selector(newFolder),
            keyEquivalent: ""
        ).configured { $0.target = self })

        let hasBookmarkableTabs = browserState?.normalTabs.contains { !$0.isLocalPage } ?? false
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("Bookmark All Tabs", comment: "Tab area context menu - Bookmark all open tabs"),
            action: hasBookmarkableTabs ? #selector(bookmarkAllTabs) : nil,
            keyEquivalent: "d"
        ).configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(.separator())

        let layoutItem = NSMenuItem(
            title: NSLocalizedString("Layout Mode", comment: "Tab area context menu - Switch layout mode"),
            action: nil,
            keyEquivalent: ""
        )
        layoutItem.submenu = buildLayoutSubmenu()
        menu.addItem(layoutItem)
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
            let untitledName = NSLocalizedString("Untitled", comment: "Default name for new bookmark folder in root")
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
            state.bookmarkManager.addBookmark(title: title, url: url)
        }
    }

    @objc private func switchLayoutMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: rawValue) else { return }
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
    }

    // MARK: - Private

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

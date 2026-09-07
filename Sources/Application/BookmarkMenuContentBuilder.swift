// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import Kingfisher

struct BookmarkMenuContentBuilder {
    static func makeMenu(bookmarks: [Bookmark],
                         canBookmarkCurrentTab: Bool,
                         canBookmarkAllTabs: Bool,
                         canExportBookmarks: Bool,
                         target: AnyObject,
                         bookmarkThisTabAction: Selector,
                         bookmarkAllTabsAction: Selector,
                         bookmarkManagerAction: Selector,
                         exportBookmarksAction: Selector,
                         openBookmarkAction: Selector) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("app.bookmarksMenu.title", value: "Bookmarks", comment: "Bookmarks menu - Menu title"))
        populate(menu: menu,
                 bookmarks: bookmarks,
                 canBookmarkCurrentTab: canBookmarkCurrentTab,
                 canBookmarkAllTabs: canBookmarkAllTabs,
                 canExportBookmarks: canExportBookmarks,
                 target: target,
                 bookmarkThisTabAction: bookmarkThisTabAction,
                 bookmarkAllTabsAction: bookmarkAllTabsAction,
                 bookmarkManagerAction: bookmarkManagerAction,
                 exportBookmarksAction: exportBookmarksAction,
                 openBookmarkAction: openBookmarkAction)
        return menu
    }

    static func populate(menu: NSMenu,
                         bookmarks: [Bookmark],
                         canBookmarkCurrentTab: Bool,
                         canBookmarkAllTabs: Bool,
                         canExportBookmarks: Bool,
                         target: AnyObject,
                         bookmarkThisTabAction: Selector,
                         bookmarkAllTabsAction: Selector,
                         bookmarkManagerAction: Selector,
                         exportBookmarksAction: Selector,
                         openBookmarkAction: Selector) {
        menu.removeAllItems()

        let bookmarkThisTabItem = NSMenuItem(
            title: NSLocalizedString("app.bookmarksMenu.addOrEditCurrentTab", value: "Bookmark This Tab...", comment: "Bookmarks menu - Menu item to add or edit a bookmark for the currently focused tab"),
            action: bookmarkThisTabAction,
            keyEquivalent: "d"
        )
        bookmarkThisTabItem.keyEquivalentModifierMask = .command
        bookmarkThisTabItem.tag = CommandWrapper.IDC_BOOKMARK_THIS_TAB.rawValue
        Shortcuts.updateShortcut(for: bookmarkThisTabItem)
        bookmarkThisTabItem.target = target
        bookmarkThisTabItem.isEnabled = canBookmarkCurrentTab
        menu.addItem(bookmarkThisTabItem)

        let bookmarkAllTabsItem = NSMenuItem(
            title: NSLocalizedString("app.bookmarksMenu.addAllOpenTabs", value: "Bookmark All Tabs...", comment: "Bookmarks menu - Menu item to add bookmarks for all currently open tabs in the active window"),
            action: bookmarkAllTabsAction,
            keyEquivalent: "d"
        )
        bookmarkAllTabsItem.keyEquivalentModifierMask = [.command, .shift]
        bookmarkAllTabsItem.tag = CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue
        Shortcuts.updateShortcut(for: bookmarkAllTabsItem)
        bookmarkAllTabsItem.target = target
        bookmarkAllTabsItem.isEnabled = canBookmarkAllTabs
        menu.addItem(bookmarkAllTabsItem)

        menu.addItem(.separator())
        let bookmarkManagerItem = NSMenuItem(
            title: NSLocalizedString(
                "app.bookmarksMenu.openManager",
                value: "Manage Bookmarks",
                comment: "Bookmarks menu - Menu item that opens the bookmark management page"
            ),
            action: bookmarkManagerAction,
            keyEquivalent: "b"
        )
        bookmarkManagerItem.keyEquivalentModifierMask = [.command, .option]
        bookmarkManagerItem.tag = CommandWrapper.IDC_SHOW_BOOKMARK_MANAGER.rawValue
        bookmarkManagerItem.target = target
        menu.addItem(bookmarkManagerItem)

        let exportBookmarksItem = NSMenuItem(
            title: NSLocalizedString("app.bookmarksMenu.exportCurrentSpace", value: "Export Bookmarks...", comment: "Bookmarks menu - Menu item to export the current Space's bookmarks to an HTML file"),
            action: exportBookmarksAction,
            keyEquivalent: ""
        )
        exportBookmarksItem.target = target
        exportBookmarksItem.isEnabled = canExportBookmarks
        menu.addItem(exportBookmarksItem)

        guard !bookmarks.isEmpty else {
            return
        }

        menu.addItem(.separator())
        for bookmark in bookmarks {
            menu.addItem(makeItem(for: bookmark, target: target, openBookmarkAction: openBookmarkAction))
        }
    }

    private static func makeItem(for bookmark: Bookmark,
                                 target: AnyObject,
                                 openBookmarkAction: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: bookmark.title,
            action: bookmark.isFolder ? nil : openBookmarkAction,
            keyEquivalent: ""
        )
        item.representedObject = bookmark

        if bookmark.isFolder {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = makeFolderMenu(for: bookmark, target: target, openBookmarkAction: openBookmarkAction)
        } else {
            item.target = target
            item.image = bookmarkMenuImage(for: bookmark, menuItem: item)
        }

        return item
    }

    private static func makeFolderMenu(for folder: Bookmark,
                                       target: AnyObject,
                                       openBookmarkAction: Selector) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        guard !folder.children.isEmpty else {
            let emptyItem = NSMenuItem(
                title: NSLocalizedString("app.bookmarksMenu.emptyFolderPlaceholder", value: "Empty", comment: "Bookmarks menu - Disabled placeholder item shown when a bookmark folder has no child bookmarks"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return menu
        }

        for child in folder.children {
            menu.addItem(makeItem(for: child, target: target, openBookmarkAction: openBookmarkAction))
        }
        return menu
    }

    private static func bookmarkMenuImage(for bookmark: Bookmark, menuItem: NSMenuItem) -> NSImage? {
        if let data = bookmark.liveFaviconData ?? bookmark.cachedFaviconData,
           let image = NSImage(data: data) {
            return sizedBookmarkMenuImage(from: image)
        }

        if let urlString = bookmark.url,
           let url = URL(string: urlString) {
            let provider = FaviconDataProvider(pageURL: url)
            let options: KingfisherOptionsInfo = [.cacheOriginalImage]

            KingfisherManager.shared.retrieveImage(with: .provider(provider), options: options) { result in
                guard case let .success(value) = result else { return }
                DispatchQueue.main.async {
                    menuItem.image = sizedBookmarkMenuImage(from: value.image)
                }
            }
        }

        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }

    private static func sizedBookmarkMenuImage(from image: NSImage) -> NSImage {
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

enum BookmarkMainMenuItemRouting: Equatable {
    case configureCustomItem
    case hideSystemItem
    case ignore

    static func action(tag: Int) -> Self {
        if tag == AppController.bookmarksMenuItemTag {
            return .configureCustomItem
        }

        if ChromiumMainMenuRole(tag: tag) == .bookmarks {
            return .hideSystemItem
        }

        return .ignore
    }
}

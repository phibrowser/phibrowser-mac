// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

@MainActor
final class SearchTabsBookmarkMenuPresenter: NSObject {
    private weak var browserState: BrowserState?
    private var isPresenting = false
    var didOpenBookmark: (() -> Void)?

    init(browserState: BrowserState) {
        self.browserState = browserState
    }

    func showBookmarkRootMenu(relativeTo anchorView: NSView) {
        guard !isPresenting,
              let state = browserState else {
            return
        }

        let menu = NSMenu(title: NSLocalizedString("Bookmarks", comment: "Search Tabs - Bookmark root menu title"))
        menu.autoenablesItems = true
        menu.delegate = self

        if state.bookmarkManager.rootFolder.children.isEmpty {
            let emptyItem = NSMenuItem(
                title: NSLocalizedString("Empty", comment: "Search Tabs - Empty bookmark menu placeholder"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            state.bookmarkManager.rootFolder.children.forEach { bookmark in
                menu.addItem(makeMenuItem(for: bookmark))
            }
        }

        isPresenting = true
        let origin = NSPoint(x: 8, y: anchorView.bounds.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: anchorView)
    }

    private func makeMenuItem(for bookmark: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(
            title: bookmark.title,
            action: bookmark.isFolder ? nil : #selector(openBookmarkFromMenu(_:)),
            keyEquivalent: ""
        )
        item.representedObject = bookmark

        if bookmark.isFolder {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = makeFolderMenu(for: bookmark)
        } else {
            item.target = self
            item.image = NSImage(systemSymbolName: bookmark.secondaryUrl?.isEmpty == false ? "rectangle.split.2x1" : "globe", accessibilityDescription: nil)
        }

        return item
    }

    private func makeFolderMenu(for folder: Bookmark) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        guard !folder.children.isEmpty else {
            let emptyItem = NSMenuItem(
                title: NSLocalizedString("Empty", comment: "Search Tabs - Empty bookmark folder placeholder"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return menu
        }

        folder.children.forEach { child in
            menu.addItem(makeMenuItem(for: child))
        }
        return menu
    }

    @objc private func openBookmarkFromMenu(_ sender: NSMenuItem) {
        guard let state = browserState,
              let bookmark = sender.representedObject as? Bookmark,
              !bookmark.isFolder else {
            return
        }
        state.openBookmark(bookmark)
        didOpenBookmark?()
    }
}

extension SearchTabsBookmarkMenuPresenter: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        isPresenting = false
    }
}

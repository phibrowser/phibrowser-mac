// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// The main menu while a picture-in-picture window is alone on the current
/// macOS desktop (`PictureInPictureOnlyDesktop`): every item except text
/// editing finds no target in `targetForAction:to:from:`, so AppKit greys it
/// out and neither a click nor its key equivalent runs it.
extension PhiApplication {
    /// The main-menu actions that stay available: Edit's text editing,
    /// including Phi's undo and redo (with no browser window key they fall
    /// back to the text field's), Emoji & Symbols, and dictation.
    static let pictureInPictureKeptMenuActions: Set<Selector> = Set([
        "cut:", "copy:", "paste:", "pasteAndMatchStyle:", "delete:", "selectAll:",
        "undo:", "redo:", "undoTabCleanupOrEdit:", "redoTabCleanupOrEdit:",
        "orderFrontCharacterPalette:", "startDictation:",
    ].map(NSSelectorFromString))

    /// Whether the main-menu item `sender` must find no target for `action`.
    /// Anything else, a context menu's item included, is left alone.
    @MainActor
    @objc(blocksMenuAction:from:)
    func blocksMenuAction(_ action: Selector, from sender: Any?) -> Bool {
        Self.blocksMenuAction(
            action, from: sender, mainMenu: mainMenu,
            pictureInPictureOnlyDesktop: PictureInPictureOnlyDesktop.isActive)
    }

    /// The rule behind the one above; `pictureInPictureOnlyDesktop` is only
    /// read for a main-menu item whose action is not kept.
    @MainActor
    static func blocksMenuAction(
        _ action: Selector,
        from sender: Any?,
        mainMenu: NSMenu?,
        pictureInPictureOnlyDesktop: @autoclosure () -> Bool
    ) -> Bool {
        guard let item = sender as? NSMenuItem,
              !pictureInPictureKeptMenuActions.contains(action),
              isInMainMenu(item, mainMenu: mainMenu) else { return false }
        return pictureInPictureOnlyDesktop()
    }

    /// Whether `item` sits in `mainMenu`'s tree rather than in a context menu
    /// or another menu of its own.
    @MainActor
    static func isInMainMenu(_ item: NSMenuItem, mainMenu: NSMenu?) -> Bool {
        guard let mainMenu else { return false }
        var menu = item.menu
        while let parent = menu?.supermenu { menu = parent }
        return menu === mainMenu
    }
}

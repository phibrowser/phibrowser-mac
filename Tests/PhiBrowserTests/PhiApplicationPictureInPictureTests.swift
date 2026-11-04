// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class PhiApplicationPictureInPictureTests: XCTestCase {
    func testKeepsOnlyTextEditingActions() {
        for name in ["cut:", "copy:", "paste:", "pasteAndMatchStyle:", "delete:", "selectAll:",
                     "undo:", "redo:", "undoTabCleanupOrEdit:", "redoTabCleanupOrEdit:",
                     "orderFrontCharacterPalette:", "startDictation:"] {
            XCTAssertTrue(PhiApplication.pictureInPictureKeptMenuActions.contains(NSSelectorFromString(name)), name)
        }
        for name in ["commandDispatch:", "terminate:", "hide:", "performClose:",
                     "showPreferences:", "performMiniaturize:"] {
            XCTAssertFalse(PhiApplication.pictureInPictureKeptMenuActions.contains(NSSelectorFromString(name)), name)
        }
    }

    func testBlocksOnlyMainMenuItemsThatAreNotKept() {
        let mainMenu = NSMenu()
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        mainMenu.addItem(fileItem)
        let quit = NSSelectorFromString("terminate:")
        let copy = NSSelectorFromString("copy:")
        let quitItem = file.addItem(withTitle: "Quit", action: quit, keyEquivalent: "q")
        let copyItem = file.addItem(withTitle: "Copy", action: copy, keyEquivalent: "c")
        let contextItem = NSMenu().addItem(withTitle: "Quit", action: quit, keyEquivalent: "")
        func blocks(_ action: Selector, _ sender: Any?, active: Bool = true) -> Bool {
            PhiApplication.blocksMenuAction(
                action, from: sender, mainMenu: mainMenu, pictureInPictureOnlyDesktop: active)
        }

        XCTAssertTrue(blocks(quit, quitItem))
        XCTAssertFalse(blocks(quit, quitItem, active: false))
        XCTAssertFalse(blocks(copy, copyItem))
        XCTAssertFalse(blocks(quit, contextItem))
        XCTAssertFalse(blocks(quit, NSButton()))
        XCTAssertFalse(blocks(quit, nil))
    }

    /// Working out the state walks every window, so only a main-menu item
    /// whose action is not kept may ask for it.
    func testAsksForTheStateOnlyForMainMenuItemsThatAreNotKept() {
        let mainMenu = NSMenu()
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        mainMenu.addItem(fileItem)
        let quit = NSSelectorFromString("terminate:")
        let copy = NSSelectorFromString("copy:")
        let quitItem = file.addItem(withTitle: "Quit", action: quit, keyEquivalent: "q")
        let copyItem = file.addItem(withTitle: "Copy", action: copy, keyEquivalent: "c")
        let contextMenu = NSMenu()
        let contextItem = contextMenu.addItem(withTitle: "Quit", action: quit, keyEquivalent: "")
        var asked = 0
        func state() -> Bool {
            asked += 1
            return true
        }
        func blocks(_ action: Selector, _ sender: Any?) -> Bool {
            PhiApplication.blocksMenuAction(
                action, from: sender, mainMenu: mainMenu, pictureInPictureOnlyDesktop: state())
        }

        _ = blocks(copy, copyItem)
        _ = blocks(quit, contextItem)
        _ = blocks(quit, NSButton())
        XCTAssertEqual(asked, 0)
        _ = blocks(quit, quitItem)
        XCTAssertEqual(asked, 1)
    }

    func testOnlyMainMenuItemsAreInTheMainMenu() {
        let mainMenu = NSMenu()
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        mainMenu.addItem(fileItem)
        let newTab = file.addItem(withTitle: "New Tab", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "t")
        let contextMenu = NSMenu()
        let copyLink = contextMenu.addItem(withTitle: "Copy Link", action: NSSelectorFromString("copyLink:"), keyEquivalent: "")
        let loose = NSMenuItem(title: "Loose", action: nil, keyEquivalent: "")

        XCTAssertTrue(PhiApplication.isInMainMenu(newTab, mainMenu: mainMenu))
        XCTAssertFalse(PhiApplication.isInMainMenu(copyLink, mainMenu: mainMenu))
        XCTAssertFalse(PhiApplication.isInMainMenu(loose, mainMenu: mainMenu))
        XCTAssertFalse(PhiApplication.isInMainMenu(newTab, mainMenu: nil))
    }
}

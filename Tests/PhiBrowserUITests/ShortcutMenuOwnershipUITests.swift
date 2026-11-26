// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit

/// Exercises native/Chromium shortcut ownership in an explicitly disposable
/// Guest session. File storage is isolated; authentication stores are shared.
/// Legacy conflicting bindings are seeded directly because the settings UI
/// deliberately removes conflicts; menu-rebuild acceptance uses that real UI.
final class ShortcutMenuOwnershipUITests: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL!
    private var locationShortcutIsOverridden = false
    private let firstTitle = "Shortcut Ownership First"
    private let secondTitle = "Shortcut Ownership Second"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try ShortcutUITestEnvironment.requireDisposableGuestSession()
        try ShortcutUITestEnvironment.requireDirectKeyboardLayout()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhiShortcutOwnershipUITest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testF12OpensDevToolsWithFocusInWebPage() throws {
        try launch(configuration: [])
        try navigateToFixture(title: firstTitle, bodyHTML: "<input aria-label='F12 test input'>")
        let field = app.webViews.textFields["F12 test input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey(.F12, modifierFlags: [])
        XCTAssertTrue(app.buttons["Customize and control DevTools"].firstMatch.waitForExistence(timeout: 15))
    }

    func testNativeSettingsOnControlPageDownWinsWithoutSwitchingTabs() throws {
        try launchWithControlPageDown(commandID: 40015) // IDC_OPTIONS
        try prepareTwoTabs()
        app.typeKey(.pageDown, modifierFlags: .control)
        XCTAssertTrue(app.toolbars.buttons["Shortcuts"].waitForExistence(timeout: 5))
        // The settings toolbar identifies this window independently of the
        // previously selected pane (Guest, General, Shortcuts, ...).
        let settingsWindow = app.windows.allElementsBoundByIndex.first {
            $0.toolbars.buttons["Shortcuts"].exists
        }
        let actualSettings = try XCTUnwrap(settingsWindow)
        XCTAssertTrue(actualSettings.exists)
        actualSettings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(selectedTabTitle(secondTitle).waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
    }

    func testCommandAddressBarOnControlPageDownStillWinsWithoutSwitchingTabs() throws {
        try launchWithControlPageDown(commandID: 39001) // IDC_FOCUS_LOCATION
        try prepareTwoTabs()
        app.typeKey(.pageDown, modifierFlags: .control)
        XCTAssertTrue(app.textFields["Search or Enter URL"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(selectedTabTitle(secondTitle).waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
    }

    func testTabSwitcherUsesReverseHoldKeyAndDoesNotReviveOldControlTab() throws {
        try launch(configuration: [
            ["commandId": 90002, "key": ["characters": "j", "modifiersRaw": 1 << 18]],
            ["commandId": 90003, "key": ["characters": "k", "modifiersRaw": 1 << 20]]
        ])
        assertConfiguredShortcuts(search: "Tab Switcher", labels: [90002: "⌃J", 90003: "⌘K"])
        try prepareTwoTabs()
        // typeKey supplies a complete modifier mask; an empty mask clears
        // the held context for that event instead of merging with it.
        XCUIElement.perform(withKeyModifiers: .command) {
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(switcher.waitForExistence(timeout: 5))
            XCTAssertTrue(selectedTabTitle(secondTitle).exists)
        }
        XCTAssertTrue(selectedTabTitle(firstTitle).waitForExistence(timeout: 5))
        XCTAssertFalse(switcher.exists)
        app.typeKey(.tab, modifierFlags: .control)
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(selectedTabTitle(firstTitle).exists)
        XCTAssertFalse(switcher.exists)
        XCUIElement.perform(withKeyModifiers: .control) {
            app.typeKey("j", modifierFlags: .control)
            XCTAssertTrue(switcher.waitForExistence(timeout: 5))
            XCTAssertTrue(selectedTabTitle(firstTitle).exists)
        }
        XCTAssertTrue(selectedTabTitle(secondTitle).waitForExistence(timeout: 5))
        XCTAssertFalse(switcher.exists)
    }

    func testTabSwitcherCommitsWhenControlReleasesWhileShiftRemainsDown() throws {
        try launch(configuration: [
            ["commandId": 90002, "key": ["characters": "j", "modifiersRaw": (1 << 18) | (1 << 17)]],
            ["commandId": 90003, "key": ["characters": "k", "modifiersRaw": (1 << 18) | (1 << 17)]]
        ])
        assertConfiguredShortcuts(search: "Tab Switcher", labels: [90002: "⇧⌃J", 90003: "⇧⌃K"])
        try prepareTwoTabs()
        XCUIElement.perform(withKeyModifiers: .shift) {
            XCUIElement.perform(withKeyModifiers: .control) {
                app.typeKey("j", modifierFlags: [.control, .shift])
                XCTAssertTrue(switcher.waitForExistence(timeout: 5))
                XCTAssertTrue(selectedTabTitle(secondTitle).exists)
            }
            XCTAssertTrue(selectedTabTitle(firstTitle).waitForExistence(timeout: 5))
            XCTAssertFalse(switcher.exists)
        }
        XCTAssertTrue(selectedTabTitle(firstTitle).exists)
    }

    func testSwappedCloseBindingsRetainTheirTargetsAcrossSettingsWindow() throws {
        try assertSwappedCloseBindings(checkSettingsFirst: true)
    }

    func testSwappedCloseBindingsWorkBeforeOpeningShortcutsPane() throws {
        try assertSwappedCloseBindings(checkSettingsFirst: false)
    }

    private func assertSwappedCloseBindings(checkSettingsFirst: Bool) throws {
        try launch(configuration: [
            ["commandId": 34015, "key": ["characters": "w", "modifiersRaw": (1 << 20) | (1 << 17)]],
            ["commandId": 34012, "key": ["characters": "w", "modifiersRaw": 1 << 20]]
        ])
        if checkSettingsFirst {
            assertConfiguredShortcuts(search: "Close", labels: [34015: "⌘⇧W", 34012: "⌘W"])
        }
        try prepareTwoTabs()
        let browser = app.windows.containing(.outline, identifier: "sidebarTabList").firstMatch
        XCTAssertTrue(browser.exists)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.button, identifier: "Shortcuts").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        // A configured Close Tab key must not become Close Window while a
        // non-browser window is key. The explicit Close Window key still works.
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(browser.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTabTitle(secondTitle).exists)
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(selectedTabTitle(firstTitle).waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines["sidebarTabList"].staticTexts[secondTitle].exists)
        XCTAssertTrue(browser.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(browser.waitForNonExistence(timeout: 5))
    }

    func testDisabledCloseTabDoesNotReviveCommandWAsCloseWindow() throws {
        try launch(configuration: [["commandId": 34015, "key": NSNull()]])
        try prepareTwoTabs()
        let browser = app.windows.containing(.outline, identifier: "sidebarTabList").firstMatch
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(browser.exists)
        XCTAssertTrue(selectedTabTitle(secondTitle).exists)
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(browser.waitForNonExistence(timeout: 5))
    }

    func testShortcutEditKeepsHistoryAndTabMenusLive() throws {
        try launch(configuration: [])
        try prepareTwoTabs()
        assertMenu("Tab", contains: [firstTitle, secondTitle])
        assertMenu("History", contains: [firstTitle, secondTitle])

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Shortcuts"].click()
        let settings = app.windows["Shortcuts"]
        let search = settings.textFields["shortcuts.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Reload Page")
        let binding = settings.buttons["shortcuts.record.33002"]
        XCTAssertTrue(binding.waitForExistence(timeout: 5))
        binding.click()
        app.typeKey("r", modifierFlags: [.control, .option])
        XCTAssertEqual(binding.label, "⌥⌃R")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

        assertMenu("Tab", contains: [firstTitle, secondTitle])
        assertMenu("History", contains: [firstTitle, secondTitle])
        let thirdTitle = "Shortcut Ownership After Rebuild"
        app.typeKey("t", modifierFlags: .command)
        try navigateToFixture(title: thirdTitle)
        assertMenu("Tab", contains: [firstTitle, secondTitle, thirdTitle])
        assertMenu("History", contains: [thirdTitle])

        let tabMenu = app.menuBars.menuBarItems["Tab"]
        tabMenu.click()
        tabMenu.menuItems[firstTitle].click()
        XCTAssertTrue(selectedTabTitle(firstTitle).waitForExistence(timeout: 5))
    }

    func testRecordedNavigationAndFunctionKeysOpenSettingsFromWebContent() throws {
        try launch(configuration: [])
        try prepareTwoTabs()
        app.typeKey(",", modifierFlags: .command)
        let pane = app.toolbars.buttons["Shortcuts"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        for (key, label): (XCUIKeyboardKey, String) in [(.pageUp, "⌥⌃⇞"), (.F8, "⌥⌃F8")] {
            let settings = app.windows["Shortcuts"]
            let search = settings.textFields["shortcuts.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.click()
            search.typeKey("a", modifierFlags: .command)
            search.typeText("Settings")
            let binding = settings.buttons["shortcuts.record.40015"]
            XCTAssertTrue(binding.waitForExistence(timeout: 5))
            binding.click()
            app.typeKey(key, modifierFlags: [.control, .option])
            XCTAssertEqual(binding.label, label)
            settings.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
            app.webViews.firstMatch.click()
            app.typeKey(key, modifierFlags: [.control, .option])
            // showPreferences opens the account pane, independently of the
            // previously selected pane. Identify Settings by its toolbar.
            let reopenedPane = app.toolbars.buttons["Shortcuts"]
            XCTAssertTrue(reopenedPane.waitForExistence(timeout: 5))
            reopenedPane.click()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        app.windows["Shortcuts"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(selectedTabTitle(secondTitle).waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
    }

    func testRejectedShiftOnlyShortcutPreservesNativeAndWebTextInput() throws {
        try launch(configuration: [])
        try navigateToFixture(title: firstTitle,
                              bodyHTML: "<input aria-label='Shortcut Typing Input'>")
        app.typeKey(",", modifierFlags: .command)
        let pane = app.toolbars.buttons["Shortcuts"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let settings = app.windows["Shortcuts"]
        let search = settings.textFields["shortcuts.search"]
        search.click()
        search.typeText("Copy URL")
        let binding = settings.buttons["shortcuts.record.90020"]
        XCTAssertTrue(binding.waitForExistence(timeout: 5))
        XCTAssertEqual(binding.label, "⌘⇧C")
        binding.click()
        app.typeKey("a", modifierFlags: .shift)
        XCTAssertEqual(binding.label, "Press shortcut…", "Unsupported input must not commit a binding")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(binding.label, "⌘⇧C")
        XCTAssertFalse(settings.buttons["shortcuts.restore.90020"].exists)

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey("a", modifierFlags: .shift)
        XCTAssertEqual(search.value as? String, "A", "Native text editing must retain uppercase typing")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let input = app.webViews.textFields["Shortcut Typing Input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        app.typeKey("a", modifierFlags: .shift)
        XCTAssertEqual(input.value as? String, "A", "Web text editing must retain uppercase typing")
        XCTAssertTrue(selectedTabTitle(firstTitle).exists)
    }

    func testPeekReboundClosePreservesItsOriginWithPageInputFocused() throws {
        try launch(configuration: [[
            "commandId": 34015,
            "key": ["characters": "k", "modifiersRaw": 1 << 18]
        ]])
        let input = try openPeekFixture()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(input.exists, "The old Close Tab key must not dismiss Peek")
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
        app.typeKey("k", modifierFlags: .control)
        assertPeekClosed(input)
    }

    func testPeekLegacyShiftPunctuationAndDisabledClosePreserveOrigin() throws {
        try launch(configuration: [
            ["commandId": 34015, "key": NSNull()],
            ["commandId": 33000, "key": ["characters": "+", "modifiersRaw": 1 << 20]]
        ])
        let input = try openPeekFixture()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(input.exists, "Disabled Close Tab must not dismiss Peek")
        app.typeKey("=", modifierFlags: [.command, .shift, .option])
        XCTAssertTrue(input.exists, "Additional modifiers must not match the legacy binding")
        app.typeKey("=", modifierFlags: [.command, .shift])
        assertPeekClosed(input)
    }

    func testReaderReboundClosePreservesItsOrigin() throws {
        let url = try readerFixtureURL()
        try launch(configuration: [[
            "commandId": 34015,
            "key": ["characters": "k", "modifiersRaw": 1 << 18]
        ]])
        let close = try openReaderFixture(url)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(close.exists, "The old Close Tab key must not dismiss Reader")
        app.typeKey("k", modifierFlags: [.control, .shift])
        XCTAssertTrue(close.exists, "Additional modifiers must not dismiss Reader")
        app.typeKey("k", modifierFlags: .control)
        assertReaderClosed(close)
    }

    func testReaderLegacyShiftPunctuationAndDisabledClosePreserveOrigin() throws {
        let url = try readerFixtureURL()
        try launch(configuration: [
            ["commandId": 34015, "key": NSNull()],
            ["commandId": 33000, "key": ["characters": "+", "modifiersRaw": 1 << 20]]
        ])
        let close = try openReaderFixture(url)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(close.exists, "Disabled Close Tab must not dismiss Reader")
        app.typeKey("=", modifierFlags: [.command, .shift])
        assertReaderClosed(close)
    }

    func testGlobalKioskShortcutActivatesFromFinderAndReleasesWhenDisabled() throws {
        try launch(configuration: [[
            "commandId": 90022,
            "key": ["characters": "y", "modifiersRaw": (1 << 18) | (1 << 19) | (1 << 17)]
        ]], additionalArguments: ["-openKioskWithGlobalShortcut", "YES"])
        try navigateToFixture(title: firstTitle)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        finder.typeKey("y", modifierFlags: [.control, .option, .shift])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                      "The global hotkey must bring Phi forward from another app")
        // Kiosk's toolbar address is static text; its initial editable address
        // field belongs to a separate omnibox Dialog rather than this Window.
        let kiosk = app.windows.containing(.button, identifier: "Choose Space").firstMatch
        XCTAssertTrue(kiosk.waitForExistence(timeout: 5))
        XCTAssertTrue(app.dialogs.textFields["Search or Enter URL"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(kiosk.outlines["sidebarTabList"].exists)
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
        kiosk.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(kiosk.waitForNonExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        let pane = app.toolbars.buttons["Shortcuts"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let settings = app.windows["Shortcuts"]
        let search = settings.textFields["shortcuts.search"]
        search.click()
        search.typeText("New Kiosk Window")
        let binding = settings.buttons["shortcuts.record.90022"]
        XCTAssertTrue(binding.waitForExistence(timeout: 5))
        binding.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(binding.label, "Add New")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let browserWindowCount = app.windows.count
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        finder.typeKey("y", modifierFlags: [.control, .option, .shift])
        XCTAssertFalse(app.wait(for: .runningForeground, timeout: 2),
                       "A disabled shortcut must release its global registration")
        XCTAssertEqual(app.windows.count, browserWindowCount)
    }

    private func readerFixtureURL() throws -> URL {
        // Start a loopback HTTP server rooted at Tests/Shortcuts/fixtures and
        // pass TEST_RUNNER_PHI_SHORTCUT_READER_FIXTURE_URL to xcodebuild.
        // Reader's actual content script requires HTTP(S), so a file URL is
        // not equivalent coverage of the installed extension.
        guard let value = ProcessInfo.processInfo.environment["PHI_SHORTCUT_READER_FIXTURE_URL"],
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Set PHI_SHORTCUT_READER_FIXTURE_URL to the local reader-article.html fixture")
        }
        return url
    }

    private func openReaderFixture(_ url: URL) throws -> XCUIElement {
        navigate(to: url, title: "Shortcut Reader Article")
        app.webViews.firstMatch.click()
        app.typeKey("r", modifierFlags: [.command, .option])
        let close = app.webViews.buttons["Close Reader View"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "The installed Reader extension must open its real surface")
        // Give Chromium's hosted Reader page focus without activating a HUD action.
        let heading = app.webViews.staticTexts["Shortcut Reader Article"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.click()
        return close
    }

    private func assertReaderClosed(_ close: XCUIElement) {
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTabTitle("Shortcut Reader Article").exists)
        XCTAssertTrue(app.webViews.links["Reader origin marker"].exists,
                      "Closing Reader must retain the original article")
    }

    private func openPeekFixture() throws -> XCUIElement {
        let destination = directory.appendingPathComponent("Shortcut Peek Destination.html")
        try "<!doctype html><title>Shortcut Peek Destination</title><h1>Shortcut Peek Destination</h1><input aria-label='Shortcut Peek Input'>"
            .write(to: destination, atomically: true, encoding: .utf8)
        try navigateToFixture(title: firstTitle,
                              bodyHTML: "<a href='\(destination.absoluteString)'>Open Shortcut Peek</a>")
        let link = app.webViews.links["Open Shortcut Peek"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.rightClick()
        let openPeek = app.menuItems["Open Link in Peek View"]
        XCTAssertTrue(openPeek.waitForExistence(timeout: 5))
        openPeek.click()
        let input = app.webViews.textFields["Shortcut Peek Input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        return input
    }

    private func assertPeekClosed(_ input: XCUIElement) {
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTabTitle(firstTitle).waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.links["Open Shortcut Peek"].exists,
                      "Closing Peek must leave its origin page open")
    }

    private func assertMenu(_ title: String, contains titles: [String]) {
        let menu = app.menuBars.menuBarItems[title]
        menu.click()
        for itemTitle in titles {
            XCTAssertTrue(menu.menuItems[itemTitle].waitForExistence(timeout: 5),
                          "\(title) must contain live item \(itemTitle)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertConfiguredShortcuts(search text: String, labels: [Int: String]) {
        app.typeKey(",", modifierFlags: .command)
        let pane = app.toolbars.buttons["Shortcuts"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let settings = app.windows["Shortcuts"]
        let search = settings.textFields["shortcuts.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(text)
        for commandID in labels.keys.sorted() {
            let binding = settings.buttons["shortcuts.record.\(commandID)"]
            XCTAssertTrue(binding.waitForExistence(timeout: 5))
            XCTAssertEqual(binding.label, labels[commandID], "Seeded binding must be active before testing dispatch")
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
    }

    private var switcher: XCUIElement {
        // AppKit exposes the nonactivating NSPanel as an accessibility dialog.
        app.dialogs.containing(.staticText, identifier: firstTitle).firstMatch
    }

    private func launchWithControlPageDown(commandID: Int) throws {
        // Guest has no signed-in Account; Shortcuts uses Phi/CustomShortcuts.json.
        let configuration: [[String: Any]] = [[
            "commandId": commandID,
            "key": ["characters": "\u{F72D}", "modifiersRaw": 1 << 18]
        ]]
        try launch(configuration: configuration)
    }

    private func launch(configuration: [[String: Any]], additionalArguments: [String] = []) throws {
        locationShortcutIsOverridden = configuration.contains { $0["commandId"] as? Int == 39001 }
        let nativeDirectory = directory.appendingPathComponent("Phi")
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: configuration).write(
            to: nativeDirectory.appendingPathComponent("CustomShortcuts.json"), options: .atomic)
        app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1", "-skip-onboarding", "-AppleLanguages", "(en)",
            "-layoutMode", "balanced", "-peekViewEnabled", "YES",
            "--force-renderer-accessibility", "--user-data-dir=\(directory.path)"
        ]
        app.launchArguments += additionalArguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 120))
        app.activate()
        try ShortcutUITestEnvironment.requireDirectKeyboardLayout()
    }

    private func prepareTwoTabs() throws {
        try navigateToFixture(title: firstTitle)
        app.typeKey("t", modifierFlags: .command)
        try navigateToFixture(title: secondTitle)
        XCTAssertTrue(app.outlines["sidebarTabList"].staticTexts[firstTitle].exists)
    }

    private func navigateToFixture(title: String, bodyHTML: String = "") throws {
        let file = directory.appendingPathComponent(title + ".html")
        try "<!doctype html><html><title>\(title)</title><body><h1>\(title)</h1>\(bodyHTML)</body></html>"
            .write(to: file, atomically: true, encoding: .utf8)
        navigate(to: file, title: title)
    }

    private func navigate(to url: URL, title: String) {
        // Only the Focus Location ownership case replaces Cmd-L.
        if !app.textFields["Search or Enter URL"].exists {
            if locationShortcutIsOverridden {
                let fileMenu = app.menuBars.menuBarItems["File"]
                fileMenu.click()
                fileMenu.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Open Location")).firstMatch.click()
            } else {
                app.typeKey("l", modifierFlags: .command)
            }
        }
        XCTAssertTrue(app.textFields["Search or Enter URL"].waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        pasteFixtureURL(url.absoluteString)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(selectedTabTitle(title).waitForExistence(timeout: 15))
    }

    private func pasteFixtureURL(_ url: String) {
        // Preserve the clipboard and avoid key-by-key URL synthesis, which
        // can lose shifted punctuation or time out on this macOS test host.
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(url, forType: .string))
        let insertedChangeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == insertedChangeCount {
                pasteboard.clearContents()
                if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(app.textFields["Search or Enter URL"].value as? String, url)
    }

    private func selectedTabTitle(_ title: String) -> XCUIElement {
        app.outlines["sidebarTabList"].cells.matching(NSPredicate(format: "selected == true"))
            .firstMatch.staticTexts[title]
    }
}

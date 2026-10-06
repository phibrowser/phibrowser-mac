// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest

/// Opt-in end-to-end coverage for the real sidebar hover and seek hit areas.
/// Start Tests/SidebarMedia/fixtures/serve_range.py first and set
/// PHI_MEDIA_UI_FIXTURE_URL=http://127.0.0.1:8766/ui-test.html for this test.
/// It skips in ordinary CI runs, where that external local server is absent.
final class SidebarMediaUITests: XCTestCase {
    private var app: XCUIApplication?

    private enum Presentation: String, CaseIterable {
        case alwaysExpanded = "Always expanded"
        case alwaysCompact = "Always compact"
        case dynamic = "Dynamic (expand on hover)"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testRepeatedHoverAndSeekAtMinimumSidebarWidth() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["PHI_MEDIA_UI_FIXTURE_URL"],
              fixtureURL.hasPrefix("http://127.0.0.1:8766/") else {
            throw XCTSkip("Set PHI_MEDIA_UI_FIXTURE_URL to the local Range fixture")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1",
            "-layoutMode", "balanced",
            "-spacesFeatureEnabled", "NO",
            "-sidebarHeaderWidth", "193",
            "--force-renderer-accessibility",
            "--user-data-dir=\(NSTemporaryDirectory())PhiMediaUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]
        app.launch()
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 120),
                      "Phi's main window did not appear")
        app.activate()
        try ensureSidebarExpanded(in: app)
        let originalPreferences = try setMediaPreferences(in: app, enabled: nil, mode: nil)
        var preferencesRestored = false
        defer {
            if !preferencesRestored {
                try? setMediaPreferences(in: app, enabled: originalPreferences.enabled,
                                        mode: originalPreferences.mode)
            }
        }
        try setMediaPreferences(in: app, enabled: true, mode: .dynamic)

        try navigateToFixture(fixtureURL, in: app)
        let start = app.buttons["Start playback"]
        guard start.waitForExistence(timeout: 30) else {
            attachDiagnostics(app, reason: "local fixture did not load")
            XCTFail("The local media fixture did not expose Start playback")
            return
        }
        XCTAssertFalse(app.buttons["sidebarMedia.playPause"].exists,
                       "Preloaded but unplayed media should not create a player")
        start.click()
        let pause = app.buttons["sidebarMedia.playPause"]
        XCTAssertFalse(pause.exists,
                       "Media in the currently viewed tab should not show a widget")

        // Pin the actual media fixture, ensuring a nonempty pinned item is
        // measured alongside an ordinary foreground row on both surfaces.
        let sourceRow = app.outlines["sidebarTabList"].cells
            .matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10))
        sourceRow.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
        let pin = app.menuItems["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.click()
        let pinned = app.buttons.matching(identifier: "sidebarPinnedTab")
            .matching(NSPredicate(format: "label == %@", "Phi media UI fixture")).firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 10), "The pinned fixture must be present")
        XCTAssertGreaterThan(pinned.frame.width, 0)
        XCTAssertGreaterThan(pinned.frame.height, 0)
        app.typeKey("t", modifierFlags: .command)
        guard pause.waitForExistence(timeout: 20) else {
            attachDiagnostics(app, reason: "player did not appear")
            XCTFail("Background playback did not create the sidebar player")
            return
        }
        let outsideSidebar = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25))
        let revealEdge = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        try toggleSidebar(in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { !pause.exists },
                      "Closing the docked sidebar should conceal its media card")
        for iteration in 0..<2 {
            revealEdge.hover()
            guard pause.waitForExistence(timeout: 10) else {
                attachDiagnostics(app, reason: "floating sidebar reveal did not restore media")
                XCTFail("Hover reveal should show background media (cycle \(iteration))")
                return
            }
            let floatingOutline = app.outlines["sidebarTabList"].firstMatch
            let floatingOutlineFrame = floatingOutline.frame
            let floatingRow = floatingOutline.cells.matching(NSPredicate(format: "selected == true")).firstMatch
            let floatingRowFrame = floatingRow.frame
            let floatingFooter = app.descendants(matching: .any)
                .matching(identifier: "sidebar.footer").firstMatch
            let floatingFooterFrame = floatingFooter.frame
            XCTAssertTrue(pinned.exists && floatingRow.exists)
            let floatingPinnedFrame = pinned.frame
            pause.hover()
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "sidebarMedia.timeline").firstMatch
                .waitForExistence(timeout: 5),
                "Floating sidebar media should expand on hover")
            assertFrame(floatingOutline, remains: floatingOutlineFrame, "Floating tab list")
            assertFrame(floatingRow, remains: floatingRowFrame, "Floating ordinary tab row")
            assertFrame(pinned, remains: floatingPinnedFrame, "Floating pinned fixture")
            assertFrame(floatingFooter, remains: floatingFooterFrame, "Floating footer")
            assertFooterGap(in: app)
            outsideSidebar.hover()
            XCTAssertTrue(waitUntil(timeout: 8) { !pause.exists },
                          "Floating sidebar should hide after pointer exit")
        }
        try toggleSidebar(in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 10),
                      "Docked sidebar should restore the same source")
        let initialCenter = pause.frame.midY
        let timeline = app.descendants(matching: .any)
            .matching(identifier: "sidebarMedia.timeline").firstMatch
        let title = app.staticTexts["sidebarMedia.title"]
        let offCard = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25))
        let outline = app.outlines["sidebarTabList"].firstMatch
        let row = outline.cells.matching(NSPredicate(format: "selected == true")).firstMatch
        let footer = app.descendants(matching: .any)
            .matching(identifier: "sidebar.footer").firstMatch
        let outlineFrame = outline.frame
        XCTAssertTrue(pinned.exists && row.exists)
        let rowFrame = row.frame
        let pinnedFrame = pinned.frame
        let footerFrame = footer.frame
        let card = app.descendants(matching: .any)
            .matching(identifier: "sidebarMedia.card").firstMatch
        let compactCardFrame = card.frame

        for iteration in 0..<3 {
            offCard.hover()
            XCTAssertTrue(waitUntil(timeout: 3) { !timeline.exists },
                          "The timeline should collapse after pointer exit (cycle \(iteration))")
            assertFrame(outline, remains: outlineFrame, "Collapsed tab list")
            assertFrame(row, remains: rowFrame, "Collapsed ordinary tab row")
            assertFrame(pinned, remains: pinnedFrame, "Collapsed pinned fixture")
            assertFrame(footer, remains: footerFrame, "Collapsed footer")
            pause.hover()
            guard timeline.waitForExistence(timeout: 5),
                  title.waitForExistence(timeout: 5) else {
                attachDiagnostics(app, reason: "hover did not expand")
                XCTFail("Hover should reveal metadata and timeline (cycle \(iteration))")
                return
            }
            XCTAssertEqual(pause.frame.midY, initialCenter, accuracy: 2,
                           "The play control should remain at the same pointer location")
            XCTAssertEqual(title.label, "UI Test Track")
            assertFrame(outline, remains: outlineFrame, "Expanded tab list")
            assertFrame(row, remains: rowFrame, "Expanded ordinary tab row")
            assertFrame(pinned, remains: pinnedFrame, "Expanded pinned fixture")
            assertFrame(footer, remains: footerFrame, "Expanded footer")
            assertFooterGap(in: app)
            XCTAssertLessThan(timeline.frame.maxY, compactCardFrame.minY,
                              "The seek hit area should sit above the compact reserved slot")
        }

        pause.click()
        XCTAssertTrue(waitUntil(timeout: 5) { pause.label == "Play" },
                      "Clicking the hovered Pause control should pause the source")
        pause.click()
        XCTAssertTrue(waitUntil(timeout: 5) { pause.label == "Pause" },
                      "The same control should resume playback")

        let elapsed = app.staticTexts["sidebarMedia.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let beforeDrag = seconds(elapsed.label) ?? 0
        let dragStart = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let dragEnd = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        dragStart.press(forDuration: 0.15, thenDragTo: dragEnd)
        XCTAssertTrue(waitUntil(timeout: 8) {
            (seconds(elapsed.label) ?? 0) > beforeDrag + 50
        }, "Dragging the knobless timeline should seek the real media")

        let afterDrag = seconds(elapsed.label) ?? 0
        let back = app.buttons["sidebarMedia.backward"]
        let forward = app.buttons["sidebarMedia.forward"]
        XCTAssertTrue(back.isEnabled && forward.isEnabled,
                      "The Range-backed fixture should expose ten-second seeking")
        back.click()
        XCTAssertTrue(waitUntil(timeout: 6) {
            (seconds(elapsed.label) ?? Int.max) <= afterDrag - 7
        }, "Backward should seek about ten seconds")
        let afterBack = seconds(elapsed.label) ?? 0
        forward.click()
        XCTAssertTrue(waitUntil(timeout: 6) {
            (seconds(elapsed.label) ?? 0) >= afterBack + 7
        }, "Forward should seek about ten seconds")

        try setMediaPreferences(in: app, enabled: nil, mode: .alwaysExpanded)
        offCard.hover()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Always expanded should show details without hovering")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        XCTAssertTrue(timeline.exists, "Pointer exit must not collapse Always expanded")
        assertFrame(outline, remains: outlineFrame, "Always-expanded tab list")
        assertFrame(row, remains: rowFrame, "Always-expanded ordinary row")
        assertFrame(pinned, remains: pinnedFrame, "Always-expanded pinned fixture")
        assertFrame(footer, remains: footerFrame, "Always-expanded footer")
        try setMediaPreferences(in: app, enabled: nil, mode: .alwaysCompact)
        offCard.hover()
        pause.hover()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        XCTAssertFalse(timeline.exists, "Always compact should remain compact while hovered")
        try setMediaPreferences(in: app, enabled: false, mode: nil)
        XCTAssertTrue(waitUntil(timeout: 5) { !pause.exists },
                      "Disabling the player should remove the widget")
        pinned.click()
        let positionWhileDisabled = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Position:")).firstMatch
        XCTAssertTrue(positionWhileDisabled.waitForExistence(timeout: 10))
        let disabledTime = fixturePositionSeconds(positionWhileDisabled.label) ?? 0
        XCTAssertTrue(waitUntil(timeout: 5) {
            (fixturePositionSeconds(positionWhileDisabled.label) ?? 0) > disabledTime + 1
        }, "Turning the player off must leave page media playing")
        try setMediaPreferences(in: app, enabled: true, mode: nil)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        pause.hover()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        XCTAssertFalse(timeline.exists,
                       "Re-enabling the player must preserve Always compact")
        try setMediaPreferences(in: app, enabled: nil, mode: .dynamic)
        pause.hover()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        app.buttons["sidebarMedia.sourceTab"].click()
        XCTAssertTrue(waitUntil(timeout: 5) { !pause.exists },
                      "Viewing the source tab should hide the player immediately")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(pause.waitForExistence(timeout: 10),
                      "Switching away should restore background media")
        pause.hover()
        try setMediaPreferences(in: app, enabled: nil, mode: .alwaysExpanded)
        let dismiss = app.buttons["sidebarMedia.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        let timeAtDismissal = seconds(elapsed.label) ?? 0
        dismiss.click()
        XCTAssertTrue(waitUntil(timeout: 5) { !pause.exists },
                      "Dismiss should hide the current media widget")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.2))
        XCTAssertFalse(pause.exists, "Polling should not remount dismissed media")
        pinned.click()
        let pagePosition = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Position:")).firstMatch
        XCTAssertTrue(pagePosition.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) {
            (fixturePositionSeconds(pagePosition.label) ?? 0) > timeAtDismissal + 1
        }, "Dismiss should leave the page media playing")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertFalse(pause.exists, "Switching tabs should not restore dismissed media")
        pinned.click()
        let replaceMetadata = app.buttons["Replace metadata"]
        XCTAssertTrue(replaceMetadata.waitForExistence(timeout: 15))
        replaceMetadata.click()
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(pause.waitForExistence(timeout: 15),
                      "Metadata-only new track on the same element/source should restore dismissal")
        pause.hover()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "UI Test Next Track")
        dismiss.click()
        XCTAssertTrue(waitUntil(timeout: 5) { !pause.exists })
        pinned.click()
        let replace = app.buttons["Replace source"]
        XCTAssertTrue(replace.waitForExistence(timeout: 15))
        replace.click()
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(pause.waitForExistence(timeout: 15),
                      "A new media source should restore the widget after dismissal")

        try setMediaPreferences(in: app, enabled: false, mode: .alwaysCompact)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 120))
        let persisted = try setMediaPreferences(in: app, enabled: nil, mode: nil)
        XCTAssertFalse(persisted.enabled, "The feature switch should persist after relaunch")
        XCTAssertEqual(persisted.mode, .alwaysCompact, "The display mode should persist separately after relaunch")
        try setMediaPreferences(in: app, enabled: originalPreferences.enabled,
                                mode: originalPreferences.mode)
        preferencesRestored = true
    }

    @MainActor
    func testVisitOrderedMediaCycling() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["PHI_MEDIA_UI_FIXTURE_URL"],
              fixtureURL.hasPrefix("http://127.0.0.1:8766/") else {
            throw XCTSkip("Set PHI_MEDIA_UI_FIXTURE_URL to the local Range fixture")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "1", "-layoutMode", "balanced", "-spacesFeatureEnabled", "NO",
                                "-sidebarHeaderWidth", "193", "--force-renderer-accessibility",
                                "--user-data-dir=\(NSTemporaryDirectory())PhiMediaCycle-\(ProcessInfo.processInfo.globallyUniqueString)"]
        app.launch()
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 120))
        app.activate()
        try ensureSidebarExpanded(in: app)
        let original = try setMediaPreferences(in: app, enabled: nil, mode: nil)
        defer { try? setMediaPreferences(in: app, enabled: original.enabled, mode: original.mode) }
        try setMediaPreferences(in: app, enabled: true, mode: .dynamic)
        for label in ["Media A", "Media B", "Media C"] {
            if label != "Media A" { app.typeKey("t", modifierFlags: .command) }
            let url = fixtureURL + (fixtureURL.contains("?") ? "&" : "?") + "title="
                + label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            try navigateToFixture(url, in: app)
            let start = app.buttons["Start playback"]
            guard start.waitForExistence(timeout: 30) else {
                attachDiagnostics(app, reason: "rendered \(label) fixture accessibility missing")
                XCTFail("Rendered \(label) fixture is required")
                return
            }
            start.click()
        }
        app.typeKey("t", modifierFlags: .command)
        let play = app.buttons["sidebarMedia.playPause"]
        let title = app.staticTexts["sidebarMedia.title"]
        let card = app.descendants(matching: .any).matching(identifier: "sidebarMedia.card").firstMatch
        // Transitioning text can remain in the AX tree beyond the clipped card.
        // Read the visible front title instead of an outgoing first match.
        func presentedTitle() -> String {
            guard card.exists else { return "" }
            let visibleTitles = app.staticTexts.matching(identifier: "sidebarMedia.title")
                .allElementsBoundByIndex.filter {
                    $0.exists && $0.isHittable && card.frame.insetBy(dx: -1, dy: -1).contains($0.frame)
                }
            return visibleTitles.count == 1 ? elementText(visibleTitles[0]) : ""
        }
        func waitForTitle(_ expected: String, timeout: TimeInterval = 10) -> Bool {
            var stableSince: Date?
            return waitUntil(timeout: timeout) {
                guard presentedTitle() == expected else { stableSince = nil; return false }
                if stableSince == nil { stableSince = Date() }
                return Date().timeIntervalSince(stableSince!) >= 0.35
            }
        }
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.hover()
        guard waitForTitle("Media C", timeout: 8) else {
            attachDiagnostics(app, reason: "MRU title: exists=\(title.exists), label=\(title.label), value=\(String(describing: title.value)), hittable=\(title.isHittable)")
            XCTFail("Most recently visited background playing tab should lead; actual=\(presentedTitle())")
            return
        }
        XCTAssertFalse(app.buttons["sidebarMedia.dismiss"].exists,
                       "Dynamic header should not have a dismiss arrow")
        let outline = app.outlines["sidebarTabList"].firstMatch
        let outlineFrame = outline.frame
        let windowFrame = app.windows.firstMatch.frame
        func dragLeft() {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.15))
                .press(forDuration: 0.1, thenDragTo: card.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.22, dy: 0.15)))
        }
        func dragRight() {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.15))
                .press(forDuration: 0.1, thenDragTo: card.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.82, dy: 0.15)))
        }
        dragLeft()
        XCTAssertTrue(waitForTitle("Media B"))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.3))
        if presentedTitle() != "Media B" {
            attachDiagnostics(app, reason: "post-drag durability: " + presentedTitle())
        }
        XCTAssertEqual(presentedTitle(), "Media B", "Selected polling must preserve a swiped choice")
        dragLeft()
        XCTAssertTrue(waitForTitle("Media A"))
        dragRight()
        XCTAssertTrue(waitForTitle("Media B"),
                      "Right dragging should cycle to the previous source")
        dragLeft()
        XCTAssertTrue(waitForTitle("Media A"))
        app.buttons["sidebarMedia.sourceTab"].click()
        XCTAssertTrue(app.buttons["Start playback"].waitForExistence(timeout: 10))
        play.hover()
        XCTAssertTrue(waitForTitle("Media C", timeout: 8),
                      "An active media tab must coexist with another background player")
        app.typeKey("t", modifierFlags: .command)
        play.hover()
        XCTAssertTrue(waitForTitle("Media A", timeout: 8),
                      "Leaving the newly visited playing source should restore MRU choice")
        dragLeft()
        XCTAssertTrue(waitForTitle("Media C"))
        assertFrame(outline, remains: outlineFrame, "Cycling tab list")
        XCTAssertEqual(app.windows.firstMatch.frame.minX, windowFrame.minX, accuracy: 1,
                       "Dragging media must not move the window")
        XCTAssertEqual(app.windows.firstMatch.frame.minY, windowFrame.minY, accuracy: 1)
        assertFooterGap(in: app)
        try toggleSidebar(in: app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5)).hover()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.hover()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let beforeFloating = presentedTitle()
        dragLeft()
        XCTAssertTrue(waitUntil(timeout: 10) { !presentedTitle().isEmpty && presentedTitle() != beforeFloating },
                      "Floating media card should use the same ordered cycle")
        attachDiagnostics(app, reason: "visit-ordered cycling completed")
    }

    @MainActor
    @discardableResult
    private func setMediaPreferences(in app: XCUIApplication, enabled: Bool?, mode: Presentation?) throws
        -> (enabled: Bool, mode: Presentation) {
        app.typeKey(",", modifierFlags: .command)
        let general = app.toolbars.buttons["General"]
        if general.waitForExistence(timeout: 3) { general.click() }
        // XCUIElement.label can be empty even when the actual window title is
        // General. Select the observed title instead of rebuilding a label query.
        let settings = app.windows["General"]
        guard settings.waitForExistence(timeout: 10) else {
            attachDiagnostics(app, reason: "General Settings window missing")
            throw NSError(domain: "SidebarMediaUITests", code: 1)
        }
        let enableToggle = settings.descendants(matching: .any)
            .matching(identifier: "settings.sidebarMedia.enabled").firstMatch
        let modeMenu = settings.descendants(matching: .any)
            .matching(identifier: "settings.sidebarMedia.presentation").firstMatch
        for _ in 0..<10 {
            if enableToggle.exists && enableToggle.isHittable
                && modeMenu.exists && modeMenu.isHittable { break }
            let scroll = settings.scrollViews.firstMatch
            guard scroll.exists else {
                attachDiagnostics(app, reason: "General Settings scroll surface missing")
                throw NSError(domain: "SidebarMediaUITests", code: 2)
            }
            scroll.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(enableToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 10))
        if let enabled, try XCTUnwrap(toggleValue(enableToggle)) != enabled { enableToggle.click() }
        if let mode {
            modeMenu.click()
            let option = app.menuItems[mode.rawValue].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.click()
        }
        let selectedMode = Presentation(rawValue: modeMenu.value as? String ?? modeMenu.label)
        let values = (try XCTUnwrap(toggleValue(enableToggle)), try XCTUnwrap(selectedMode))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !enableToggle.exists })
        app.activate()
        return values
    }

    @MainActor
    private func navigateToFixture(_ fixtureURL: String, in app: XCUIApplication) throws {
        // XCTest key-by-key typing lost both shifted colons on this host.
        // Paste the exact local URL and verify the input before submitting it.
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(fixtureURL, forType: .string))
        let insertedChangeCount = pasteboard.changeCount
        defer {
            // Keep original content only in memory, and do not overwrite a
            // newer clipboard choice the user made during the test.
            if pasteboard.changeCount == insertedChangeCount {
                pasteboard.clearContents()
                if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }
        app.activate()
        app.typeKey("l", modifierFlags: .command)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        let input = app.textFields.matching(NSPredicate(format: "value == %@", fixtureURL)).firstMatch
        guard input.waitForExistence(timeout: 5) else {
            attachDiagnostics(app, reason: "exact fixture URL was not entered")
            throw NSError(domain: "SidebarMediaUITests", code: 3)
        }
        app.typeKey("\r", modifierFlags: [])
        app.activate()
        if let components = URLComponents(string: fixtureURL),
           let title = components.queryItems?.first(where: { $0.name == "title" })?.value {
            let selected = app.outlines["sidebarTabList"].cells
                .matching(NSPredicate(format: "selected == true")).firstMatch
            guard waitUntil(timeout: 20, { selected.staticTexts[title].exists }) else {
                attachDiagnostics(app, reason: "fixture title did not reach the selected tab")
                throw NSError(domain: "SidebarMediaUITests", code: 4)
            }
        }
    }

    private func elementText(_ element: XCUIElement) -> String {
        // macOS StaticText commonly stores its visible text in AXValue while
        // AXLabel is empty. Keep the title check tied to the rendered text.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func toggleValue(_ element: XCUIElement) -> Bool? {
        if let number = element.value as? NSNumber { return number.boolValue }
        if let value = element.value as? String, value == "0" || value == "1" { return value == "1" }
        return nil
    }

    @MainActor
    private func assertFrame(_ element: XCUIElement, remains original: CGRect, _ label: String) {
        XCTAssertEqual(element.frame.minX, original.minX, accuracy: 1, label)
        XCTAssertEqual(element.frame.minY, original.minY, accuracy: 1, label)
        XCTAssertEqual(element.frame.width, original.width, accuracy: 1, label)
        XCTAssertEqual(element.frame.height, original.height, accuracy: 1, label)
    }

    @MainActor
    private func assertFooterGap(in app: XCUIApplication) {
        let card = app.descendants(matching: .any).matching(identifier: "sidebarMedia.card").firstMatch
        let footer = app.descendants(matching: .any).matching(identifier: "sidebar.footer").firstMatch
        XCTAssertTrue(card.exists && footer.exists)
        XCTAssertEqual(footer.frame.minY - card.frame.maxY, 8, accuracy: 2,
                       "The visible media card should leave an eight-point footer gap")
    }

    @MainActor
    private func ensureSidebarExpanded(in app: XCUIApplication) throws {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        if outline.waitForExistence(timeout: 2) { return }
        try toggleSidebar(in: app)
        XCTAssertTrue(outline.waitForExistence(timeout: 20))
    }

    @MainActor
    private func toggleSidebar(in app: XCUIApplication) throws {
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 10))
        viewMenu.click()
        let toggle = app.menuBars.menuItems["Toggle Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
    }

    private func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func fixturePositionSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count == 3, parts[0] == "Position:", parts[2] == "seconds" else {
            return nil
        }
        return Int(parts[1])
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }
        return condition()
    }

    @MainActor
    private func attachDiagnostics(_ app: XCUIApplication, reason: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Sidebar media - \(reason)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.windows.firstMatch.debugDescription)
        tree.name = "Sidebar media accessibility - \(reason)"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest

/// Run with the OpenSource scheme and PHI_OMNIBOX_WORD_SELECTION_UI_TESTS=1.
final class OmniBoxWordSelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHI_OMNIBOX_WORD_SELECTION_UI_TESTS"] == "1",
                          "Opt in to the isolated OpenSource browser UI test")
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testDoubleClickReplacesOnlyTheURLWordInEveryLayout() throws {
        let text = "www.google.com/docs?q=hello_world#section"
        for layout in ["balanced", "performance", "comfortable"] {
            app.launchArguments = [
                "-uitest", "1", "-skip-onboarding", "-AppleLanguages", "(en)",
                "-authRequiresExplicitLogin", "YES", "-spacesFeatureEnabled", "NO",
                "-layoutMode", layout,
                "--user-data-dir=\(NSTemporaryDirectory())PhiOmniBoxWordUITest-\(UUID().uuidString)",
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
            app.activate()
            app.typeKey("l", modifierFlags: .command)
            let field = app.textFields["Search or Enter URL"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))

            for word in ["google", "docs", "hello_world", "section"] {
                field.typeKey("a", modifierFlags: .command)
                field.typeText(text)
                XCTAssertTrue(waitUntil { field.value as? String == text })
                let range = (text as NSString).range(of: word)
                let prefix = (text as NSString).substring(to: range.location)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
                let x = 2 + (prefix as NSString).size(withAttributes: attributes).width
                    + (word as NSString).size(withAttributes: attributes).width / 2
                field.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: field.frame.height / 2)).doubleClick()
                field.typeText("replacement")
                let expected = (text as NSString).replacingCharacters(in: range, with: "replacement")
                XCTAssertTrue(waitUntil { field.value as? String == expected },
                              "Double-click must replace only \(word) in \(layout); got \(field.value ?? "nil")")
            }
            app.terminate()
        }
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}

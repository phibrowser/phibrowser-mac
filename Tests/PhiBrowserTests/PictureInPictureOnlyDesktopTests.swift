// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class PictureInPictureOnlyDesktopTests: XCTestCase {
    /// A window whose desktop state the test sets.
    private final class StubWindow: NSWindow {
        var stubVisible = true
        var stubMiniaturized = false
        var stubOnActiveSpace = true
        var stubCanBecomeKey = true
        var stubParent: NSWindow?
        var stubSheetParent: NSWindow?

        override var isVisible: Bool { stubVisible }
        override var isMiniaturized: Bool { stubMiniaturized }
        override var isOnActiveSpace: Bool { stubOnActiveSpace }
        override var canBecomeKey: Bool { stubCanBecomeKey }
        override var parent: NSWindow? {
            get { stubParent }
            set { stubParent = newValue }
        }
        override var sheetParent: NSWindow? { stubSheetParent }
    }

    private var pictureInPicture: StubWindow!
    private var browser: StubWindow!
    private var pictureInPictureWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        pictureInPicture = makeWindow()
        browser = makeWindow()
        pictureInPictureWindows = [pictureInPicture]
    }

    override func tearDown() {
        pictureInPicture = nil
        browser = nil
        pictureInPictureWindows = []
        super.tearDown()
    }

    private func makeWindow() -> StubWindow {
        let window = StubWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Chromium answers for the windows in `pictureInPictureWindows`, as a
    /// framework that knows the question does; `frameworkAnswers: false` is
    /// an older framework.
    private func isActive(
        switchOn: Bool = true,
        frameworkAnswers: Bool = true,
        keyWindow: NSWindow? = nil,
        others: [NSWindow] = []
    ) -> Bool {
        let pictureInPictureWindows = pictureInPictureWindows
        return PictureInPictureOnlyDesktop.isActive(
            switchOn: switchOn,
            keyWindow: keyWindow ?? pictureInPicture,
            windows: [browser, pictureInPicture] + others,
            isPictureInPicture: { window in
                frameworkAnswers ? pictureInPictureWindows.contains { $0 === window } : nil
            })
    }

    func testActiveWhenThePhiWindowIsOnAnotherDesktop() {
        browser.stubOnActiveSpace = false
        XCTAssertTrue(isActive())
    }

    func testInactiveWithAPhiWindowOnThisDesktop() {
        XCTAssertFalse(isActive())
    }

    func testMinimizedPhiWindowDoesNotCount() {
        browser.stubMiniaturized = true
        XCTAssertTrue(isActive())
    }

    func testHiddenOrTransparentPhiWindowDoesNotCount() {
        browser.stubVisible = false
        XCTAssertTrue(isActive())
        browser.stubVisible = true
        browser.alphaValue = 0
        XCTAssertTrue(isActive())
    }

    func testWindowThatCannotBecomeKeyDoesNotCount() {
        browser.stubOnActiveSpace = false
        let tooltip = makeWindow()
        tooltip.stubCanBecomeKey = false
        XCTAssertTrue(isActive(others: [tooltip]))
    }

    func testAnotherPictureInPictureWindowDoesNotCount() {
        browser.stubOnActiveSpace = false
        let other = makeWindow()
        pictureInPictureWindows.append(other)
        XCTAssertTrue(isActive(others: [other]))
    }

    func testWindowAttachedToThePictureInPictureCountsAsIt() {
        browser.stubOnActiveSpace = false
        let alert = makeWindow()
        alert.stubParent = pictureInPicture
        XCTAssertTrue(isActive(others: [alert]))
        XCTAssertTrue(isActive(keyWindow: alert, others: [alert]))
    }

    func testInactiveWhileTheSwitchIsOff() {
        browser.stubOnActiveSpace = false
        XCTAssertFalse(isActive(switchOn: false))
    }

    func testInactiveWhenTheFrameworkDoesNotAnswer() {
        browser.stubOnActiveSpace = false
        XCTAssertFalse(isActive(frameworkAnswers: false))
    }

    func testInactiveWhenTheKeyWindowIsNotPictureInPicture() {
        browser.stubOnActiveSpace = false
        XCTAssertFalse(isActive(keyWindow: browser))
    }

    func testSheetOnThePictureInPictureCountsAsIt() {
        browser.stubOnActiveSpace = false
        let fileChooser = makeWindow()
        fileChooser.stubSheetParent = pictureInPicture
        XCTAssertTrue(isActive(others: [fileChooser]))
        XCTAssertTrue(isActive(keyWindow: fileChooser, others: [fileChooser]))
    }

    func testWindowsAttachedThroughSeveralLevelsCountAsThePictureInPicture() {
        browser.stubOnActiveSpace = false
        let alert = makeWindow()
        alert.stubParent = pictureInPicture
        let sheet = makeWindow()
        sheet.stubSheetParent = alert
        XCTAssertTrue(isActive(keyWindow: sheet, others: [alert, sheet]))
    }

    func testWindowAttachedToABrowserWindowCountsAsAnotherPhiWindow() {
        browser.stubOnActiveSpace = false
        let findBar = makeWindow()
        findBar.stubParent = browser
        XCTAssertFalse(isActive(others: [findBar]))
    }
}

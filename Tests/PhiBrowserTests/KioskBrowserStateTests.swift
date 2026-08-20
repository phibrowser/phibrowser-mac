// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class KioskBrowserStateTests: XCTestCase {
    func testExternalLinksInKioskDefaultsOff() {
        XCTAssertFalse(
            PhiPreferences.GeneralSettings.openExternalLinksInKiosk.defaultValue
        )
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testWireValuesAreAppendOnly() {
        XCTAssertEqual(ChromiumBrowserType.kiosk.rawValue, 11)
        XCTAssertEqual(ChromiumBrowserType.kioskIncognito.rawValue, 12)
    }

    func testStateIsIsolatedAndPreservesReportedProfile() throws {
        let state = try makeState(profileId: "Profile 2")

        XCTAssertTrue(state.isKioskWindow)
        XCTAssertFalse(state.participatesInSpaces)
        XCTAssertEqual(state.profileId, "Profile 2")
        XCTAssertTrue(state.pinnedTabs.isEmpty)
    }

    func testFirstChromiumTabBecomesFocusedContent() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0,
            title: "Example",
            windowId: state.windowId
        )

        state.handleNewTabFromChromium(tab)

        XCTAssertEqual(state.tabs.map(\.guid), [42])
        XCTAssertEqual(state.normalTabs.map(\.guid), [42])
        XCTAssertTrue(state.focusingTab === tab)
        XCTAssertTrue(tab.isActive)
        XCTAssertEqual(tab.profileId, state.profileId)
    }

    func testChromiumCloseRemovesFocusedContent() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0
        )
        state.handleNewTabFromChromium(tab)

        state.closeTab(tab.guid)

        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.focusingTab)
    }

    func testAddressFieldReturnNavigatesUsingFieldEditorText() throws {
        let state = try makeState()
        let wrapper = KioskTestWebContentWrapper(urlString: "https://old.example")
        let tab = Tab(
            guid: 42,
            url: "https://old.example",
            isActive: false,
            index: 0,
            webContentView: wrapper,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let controller = KioskBrowserContentViewController(state: state)
        _ = controller.view
        let addressField = try XCTUnwrap(findTextField(in: controller.view))
        addressField.stringValue = "https://old.example"
        let fieldEditor = NSTextView()
        fieldEditor.string = "example.com"

        XCTAssertFalse(controller.control(
            addressField,
            textView: fieldEditor,
            doCommandBy: #selector(NSTextView.moveLeft(_:))
        ))
        let handled = controller.control(
            addressField,
            textView: fieldEditor,
            doCommandBy: #selector(NSTextView.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(wrapper.navigatedURLs, ["https://example.com"])
    }

    func testAddressFieldKeypadEnterNavigatesUsingFieldEditorText() throws {
        let state = try makeState()
        let wrapper = KioskTestWebContentWrapper(urlString: "https://old.example")
        let tab = Tab(
            guid: 42,
            url: "https://old.example",
            isActive: false,
            index: 0,
            webContentView: wrapper,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let controller = KioskBrowserContentViewController(state: state)
        _ = controller.view
        let addressField = try XCTUnwrap(findTextField(in: controller.view))
        addressField.stringValue = "https://old.example"
        let fieldEditor = NSTextView()
        fieldEditor.string = "example.org"

        let handled = controller.control(
            addressField,
            textView: fieldEditor,
            doCommandBy: #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(wrapper.navigatedURLs, ["https://example.org"])
    }

    private func makeState(
        profileId: String = LocalStore.defaultProfileId
    ) throws -> KioskBrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        let account = Account(userID: UUID().uuidString)
        let store = LocalStore(
            account: account,
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        return KioskBrowserState(
            windowId: 73,
            localStore: store,
            profileId: profileId,
            isIncognito: false
        )
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) {
                return textField
            }
        }
        return nil
    }
}

private final class KioskTestWebContentWrapper: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String?

    private(set) var navigatedURLs: [String] = []

    init(urlString: String?) {
        self.urlString = urlString
        super.init()
    }

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) {
        navigatedURLs.append(urlString)
        self.urlString = urlString
    }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) {}
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

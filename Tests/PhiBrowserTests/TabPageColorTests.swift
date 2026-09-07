// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TabPageColorTests: XCTestCase {
    func testCachedColorIsAvailableImmediately() {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        wrapper.pageColor = .black
        let tab = makeTab(wrapper)
        XCTAssertEqual(tab.pageColor, .black)
    }

    func testColorAndNilUpdatesArePublishedOnMainThread() {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        let tab = makeTab(wrapper)
        var receivedOnMainThread = true
        let observation = tab.$pageColor.sink { _ in
            receivedOnMainThread = receivedOnMainThread && Thread.isMainThread
        }
        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertEqual(tab.pageColor, .white)
        wrapper.pageColor = nil
        drainPageColorUpdates()
        XCTAssertNil(tab.pageColor)
        XCTAssertTrue(receivedOnMainThread)
        withExtendedLifetime(observation) {}
    }

    func testReplacementRejectsQueuedAndLaterUpdatesFromOldWrapper() {
        let old = PageColorTestWebContentWrapper(urlString: "https://old.example")
        let replacement = PageColorTestWebContentWrapper(urlString: "https://new.example")
        replacement.pageColor = .white
        let tab = makeTab(old)
        old.pageColor = .black
        tab.setWebContentsWrapper(wrapper: replacement)
        XCTAssertEqual(tab.pageColor, .white)
        old.pageColor = .red
        drainPageColorUpdates()
        XCTAssertEqual(tab.pageColor, .white)
    }

    func testRemovalClearsColorAndRejectsOldUpdates() {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        wrapper.pageColor = .black
        let tab = makeTab(wrapper)
        tab.setWebContentsWrapper(wrapper: nil)
        XCTAssertNil(tab.pageColor)
        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertNil(tab.pageColor)
    }

    func testLegacyWrapperDoesNotReadOrObservePageColor() {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        wrapper.supportsPageColor = false
        let tab = makeTab(wrapper)
        XCTAssertNil(tab.pageColor)
        XCTAssertEqual(wrapper.pageColorReadCount, 0)
        XCTAssertEqual(wrapper.pageColorObservationCount, 0)
    }

    private func makeTab(_ wrapper: PageColorTestWebContentWrapper) -> Tab {
        Tab(url: wrapper.urlString, isActive: true, index: 0, webContentView: wrapper)
    }
}

@MainActor
func drainPageColorUpdates() {
    let drained = XCTestExpectation(description: "Tab and header main-queue updates completed")
    DispatchQueue.main.async {
        DispatchQueue.main.async {
            DispatchQueue.main.async { drained.fulfill() }
        }
    }
    XCTAssertEqual(XCTWaiter.wait(for: [drained], timeout: 5), .completed)
}

final class PageColorTestWebContentWrapper: NSObject, WebContentWrapper {
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
    @objc dynamic var isDiscarded = false
    @objc dynamic var isUnloaded = false
    @objc dynamic var isDistillable = false
    var supportsPageColor = true
    private var storedPageColor: NSColor?
    private(set) var pageColorReadCount = 0
    private(set) var pageColorObservationCount = 0
    @objc dynamic var pageColor: NSColor? {
        get {
            pageColorReadCount += 1
            return storedPageColor
        }
        set { storedPageColor = newValue }
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("pageColor"), !supportsPageColor { return false }
        return super.responds(to: selector)
    }

    override func addObserver(_ observer: NSObject, forKeyPath keyPath: String,
                              options: NSKeyValueObservingOptions, context: UnsafeMutableRawPointer?) {
        if keyPath == "pageColor" { pageColorObservationCount += 1 }
        super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
    }
    @objc dynamic var devToolsTargetId: String? = nil

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    private(set) var setAsActiveTabCallCount = 0
    private(set) var updatedCustomValues: [String] = []
    private(set) var closeCallCount = 0

    init(urlString: String?) {
        self.urlString = urlString
        super.init()
    }

    func close() { closeCallCount += 1 }
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) { self.urlString = urlString }
    func setAsActiveTab() { setAsActiveTabCallCount += 1 }
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  beforeTabId anchorTabId: Int64) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  afterTabId anchorTabId: Int64) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) { updatedCustomValues.append(customValue) }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

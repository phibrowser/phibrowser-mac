// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import class SwiftUI.NSHostingView
import XCTest
@testable import Phi

final class OverlayToastCenterTests: XCTestCase {
    private final class PreviewTab: Tab {
        let previewView = NSView()
        override var webContentView: NSView? { previewView }
    }

    @MainActor
    func testHighlightConfirmationLivesInsideKioskAndPeekAndClearsOnContentChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = KioskBrowserState(
            windowId: 987654, localStore: store, profileId: LocalStore.defaultProfileId, isIncognito: false)
        defer { OverlayToastCenter.shared.clearWindow(windowId: state.windowId) }
        let url = try XCTUnwrap(URL(string: "https://example.com/#:~:text=highlight"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let kiosk = KioskBrowserContentViewController(state: state)
        window.contentViewController = kiosk
        window.contentView?.layoutSubtreeIfNeeded()

        func overlay(in view: NSView) -> OverlayToastViewController.BgView? {
            if let overlay = view as? OverlayToastViewController.BgView { return overlay }
            return view.subviews.lazy.compactMap { overlay(in: $0) }.first
        }
        func shareButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityIdentifier() == "overlayToast.shareButton",
               !button.isHiddenOrHasHiddenAncestor { return button }
            return view.subviews.lazy.compactMap { shareButton(in: $0) }.first
        }
        func drainUpdates() {
            let drained = expectation(description: "Toast updates delivered")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 1)
        }

        let kioskOverlay = try XCTUnwrap(overlay(in: kiosk.view))
        let kioskModel = try XCTUnwrap(kioskOverlay.viewModel)
        OverlayToastCenter.shared.showHighlightLinkCopyConfirmation(url: url, in: state)
        drainUpdates()
        kiosk.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(kioskModel.genericToasts.first?.shareURLs, [url])
        XCTAssertEqual(kioskModel.genericToastTopOffset, 16)
        XCTAssertTrue(kioskOverlay.window === window)
        XCTAssertNotNil(shareButton(in: kioskOverlay))

        OverlayToastCenter.shared.showURLCopyConfirmation(copiedURLs: [url.absoluteString], in: state)
        drainUpdates()
        kiosk.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(kioskModel.genericToasts.first?.shareURLs, [url])
        XCTAssertNotNil(shareButton(in: kioskOverlay))

        let peek = PeekPanelController(
            browserState: state, parentWindow: window, anchorView: kiosk.view,
            cardViewProvider: { kiosk.view }, originTracker: nil)
        defer { peek.dismiss() }
        let tab = PreviewTab(guid: 10, url: url.absoluteString, isActive: false, index: 0)
        peek.present(tab: tab, flyIn: false)
        let peekWindow = try XCTUnwrap(window.childWindows?.first)
        let peekOverlay = try XCTUnwrap(overlay(in: try XCTUnwrap(peekWindow.contentView)))
        let peekModel = try XCTUnwrap(peekOverlay.viewModel)
        XCTAssertFalse(peekModel.toastCenter === kioskModel.toastCenter)
        XCTAssertEqual(peekModel.genericToastTopOffset, 16)

        peek.showHighlightLinkCopyConfirmation(url: url, tabId: tab.guid)
        drainUpdates()
        peekWindow.contentView?.layoutSubtreeIfNeeded()
        let originalID = try XCTUnwrap(peekModel.genericToasts.first?.id)
        XCTAssertEqual(peekModel.genericToasts.first?.shareURLs, [url])
        XCTAssertNotNil(shareButton(in: peekOverlay))
        peek.showHighlightLinkCopyConfirmation(url: url, tabId: 999)
        XCTAssertEqual(peekModel.toastCenter.visibleToasts(for: state.windowId).first?.id, originalID)

        let nextTab = PreviewTab(guid: 11, url: url.absoluteString, isActive: false, index: 1)
        peek.present(tab: nextTab, flyIn: false)
        XCTAssertTrue(peekModel.toastCenter.visibleToasts(for: state.windowId).isEmpty)
        peek.showHighlightLinkCopyConfirmation(url: url, tabId: tab.guid)
        XCTAssertTrue(peekModel.toastCenter.visibleToasts(for: state.windowId).isEmpty)
        peek.showHighlightLinkCopyConfirmation(url: url, tabId: nextTab.guid)
        XCTAssertEqual(peekModel.toastCenter.visibleToasts(for: state.windowId).count, 1)
        peekModel.toastCenter.clearWindow(windowId: state.windowId)
        peek.showURLCopyConfirmation(url: url, tabId: tab.guid)
        XCTAssertTrue(peekModel.toastCenter.visibleToasts(for: state.windowId).isEmpty)
        peek.showURLCopyConfirmation(url: url, tabId: nextTab.guid)
        let linkToast = try XCTUnwrap(peekModel.toastCenter.visibleToasts(for: state.windowId).first)
        XCTAssertEqual(linkToast.placement, .topTrailing)
        XCTAssertEqual(linkToast.shareURLs, [url])
        drainUpdates()
        peekWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(shareButton(in: peekOverlay))
        peek.hide()
        peek.showURLCopyConfirmation(url: url, tabId: nextTab.guid)
        XCTAssertTrue(peekModel.toastCenter.visibleToasts(for: state.windowId).isEmpty)
        peek.showHighlightLinkCopyConfirmation(url: url, tabId: nextTab.guid)
        XCTAssertTrue(peekModel.toastCenter.visibleToasts(for: state.windowId).isEmpty)
        XCTAssertEqual(OverlayToastCenter.shared.visibleToasts(for: state.windowId).count, 1)
    }

    private final class ManualScheduler {
        private final class ScheduledAction {
            var isCancelled: Bool = false
            let action: () -> Void

            init(action: @escaping () -> Void) {
                self.action = action
            }
        }

        private var scheduledActions: [ScheduledAction] = []

        var pendingCount: Int {
            scheduledActions.filter { !$0.isCancelled }.count
        }

        func schedule(delay: TimeInterval, action: @escaping () -> Void) -> AnyCancellable {
            let scheduledAction = ScheduledAction(action: action)
            scheduledActions.append(scheduledAction)
            return AnyCancellable {
                scheduledAction.isCancelled = true
            }
        }

        func fireNext() {
            while !scheduledActions.isEmpty {
                let scheduledAction = scheduledActions.removeFirst()
                guard !scheduledAction.isCancelled else { continue }
                scheduledAction.action()
                return
            }
        }
    }

    func testLinkCopiedCallbackIsExposedToObjectiveC() {
        XCTAssertTrue(PhiChromiumCoordinator.shared.responds(
            to: NSSelectorFromString("linkCopied:windowId:url:")))
    }

    func testHighlightLinkCallbackIsExposedToObjectiveC() {
        // Chromium uses respondsToSelector before delivering this optional event.
        XCTAssertTrue(PhiChromiumCoordinator.shared.responds(
            to: NSSelectorFromString("linkToHighlightCopied:windowId:url:isShortLink:")))
    }

    @MainActor
    func testOverlayHitTestingReachesShareButtonAndPassesThroughEmptySpace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 7, localStore: store, isKioskWindow: true)
        let viewModel = OverlayToastViewModel(browserState: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let root = OverlayToastViewController.BgView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        root.viewModel = viewModel
        window.contentView?.addSubview(root)
        let toast = OverlayToastItem(
            id: UUID(), title: "Link copied", message: nil, duration: 3,
            placement: .topCenter, shareURLs: [URL(string: "https://example.com/s/highlight")!]
        )
        let hostingView = NSHostingView(rootView: OverlayToastView(toast: toast))
        hostingView.frame = NSRect(x: 20, y: 120, width: 350, height: 60)
        root.addSubview(hostingView)
        hostingView.layoutSubtreeIfNeeded()

        func visibleShareButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityIdentifier() == "overlayToast.shareButton",
               !button.isHiddenOrHasHiddenAncestor {
                return button
            }
            return view.subviews.lazy.compactMap { visibleShareButton(in: $0) }.first
        }
        let button = try XCTUnwrap(visibleShareButton(in: hostingView))
        let buttonRect = button.convert(button.bounds, to: root)
        viewModel.hitTestFrames = [buttonRect.insetBy(dx: -10, dy: -10)]
        let localPoint = NSPoint(x: buttonRect.midX, y: buttonRect.midY)

        XCTAssertTrue(root.hitTest(root.convert(localPoint, to: root.superview)) === button)
        XCTAssertNil(root.hitTest(root.convert(NSPoint(x: 450, y: 20), to: root.superview)))

        root.setFrameOrigin(NSPoint(x: 40, y: 30))
        XCTAssertTrue(root.hitTest(root.convert(localPoint, to: root.superview)) === button)
        XCTAssertNotNil(button.target)
        XCTAssertNotNil(button.action)
    }

    func testReplacesVisibleToastForSameWindowAndPlacement() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "First", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Second", duration: 2, placement: .topCenter, in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Second"])
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.fireNext()

        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
    }

    func testShareURLFollowsReplacementAndStaysScopedToItsWindow() throws {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        let shortURL = try XCTUnwrap(URL(string: "https://example.com/s/highlight"))
        let fallbackURL = try XCTUnwrap(URL(string: "https://example.com/article#:~:text=Highlighted%20text"))

        center.show(title: "First link", shareURLs: [shortURL], in: .windowId(1))
        center.show(title: "Other window", shareURLs: [shortURL], in: .windowId(2))
        center.show(title: "Replacement link", shareURLs: [fallbackURL], in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).first?.shareURLs, [fallbackURL])
        XCTAssertEqual(center.visibleToasts(for: 2).first?.shareURLs, [shortURL])

        center.show(title: "Plain confirmation", in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).first?.shareURLs, [])
        XCTAssertEqual(center.visibleToasts(for: 2).first?.shareURLs, [shortURL])
    }

    func testMenuPausesOnlyItsToastAndDismissesImmediatelyAfterClosing() throws {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        let id = try XCTUnwrap(center.show(title: "Sharing", in: .windowId(1)))
        center.show(title: "Other window", in: .windowId(2))

        center.pauseDismissal(id: id)
        scheduler.fireNext()
        scheduler.fireNext()

        XCTAssertEqual(center.visibleToasts(for: 1).first?.id, id)
        XCTAssertTrue(center.visibleToasts(for: 2).isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)

        XCTAssertTrue(center.dismiss(id: id))
        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testClosingMenuDoesNotDismissReplacementToastOrReviveClosedWindow() throws {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        let oldID = try XCTUnwrap(center.show(title: "Sharing", in: .windowId(1)))
        center.pauseDismissal(id: oldID)
        let newID = try XCTUnwrap(center.show(title: "Replacement", in: .windowId(1)))

        XCTAssertFalse(center.dismiss(id: oldID))
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(center.visibleToasts(for: 1).first?.id, newID)

        center.pauseDismissal(id: newID)
        center.clearWindow(windowId: 1)
        XCTAssertFalse(center.dismiss(id: newID))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
    }

    func testIsolatesQueuesByWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "Window One", duration: 2, in: .windowId(1))
        center.show(title: "Window Two", duration: 2, in: .windowId(2))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Window One"])
        XCTAssertEqual(center.visibleToasts(for: 2).map(\.title), ["Window Two"])

        scheduler.fireNext()

        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
        XCTAssertEqual(center.visibleToasts(for: 2).map(\.title), ["Window Two"])
    }

    func testAllowsDifferentPlacementsInSameWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "Center", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Trailing", duration: 2, placement: .topTrailing, in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Center", "Trailing"])
        XCTAssertEqual(scheduler.pendingCount, 2)
    }

    func testRoutesDefaultTargetToActiveWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(
            scheduler: scheduler,
            resolver: { target in
                switch target {
                case .activeWindow:
                    return 7
                case .windowId(let windowId):
                    return windowId
                }
            }
        )

        center.show(title: "Active Window")

        XCTAssertEqual(center.visibleToasts(for: 7).map(\.title), ["Active Window"])
    }

    func testPublishesVisibleToastChanges() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        var publishedTitles: [[String]] = []
        let cancellable = center.visibleToastsPublisher(for: 1)
            .sink { toasts in
                publishedTitles.append(toasts.map(\.title))
            }

        center.show(title: "Published", duration: 2, in: .windowId(1))

        XCTAssertEqual(publishedTitles, [[], ["Published"]])

        scheduler.fireNext()

        XCTAssertEqual(publishedTitles, [[], ["Published"], []])
        cancellable.cancel()
    }

    func testPublishesReplacementForSameWindowAndPlacement() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        var publishedTitles: [[String]] = []
        let cancellable = center.visibleToastsPublisher(for: 1)
            .sink { toasts in
                publishedTitles.append(toasts.map(\.title))
            }

        center.show(title: "First", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Second", duration: 2, placement: .topCenter, in: .windowId(1))

        XCTAssertEqual(publishedTitles, [[], ["First"], ["Second"]])

        scheduler.fireNext()

        XCTAssertEqual(publishedTitles, [[], ["First"], ["Second"], []])
        cancellable.cancel()
    }

    func testGenericToastTopOffsetFollowsLayoutMode() {
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .comfortable), CGFloat(88))
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .performance), CGFloat(16))
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .balanced), CGFloat(56))
    }

    private func makeCenter(
        scheduler: ManualScheduler,
        resolver: @escaping OverlayToastCenter.TargetResolver = { target in
            switch target {
            case .activeWindow:
                return nil
            case .windowId(let windowId):
                return windowId
            }
        }
    ) -> OverlayToastCenter {
        var ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ]

        return OverlayToastCenter(
            targetResolver: resolver,
            scheduler: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            idFactory: { ids.removeFirst() }
        )
    }
}

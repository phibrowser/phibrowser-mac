// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class SpaceSwipeTransitionTests: XCTestCase {
    private var account: Account!
    private var directory: URL!
    private var manager: SpaceManager!
    private var slots: [SpaceWindowSlot] = []
    private var subscriptions = Set<AnyCancellable>()
    private var previousLayout: Any?
    private var previousBoundAccount: Any?
    private var nextWindowId = 123457000

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        account = Account(userID: "space-swipe-test-\(UUID().uuidString)")
        account.localStorage = LocalStore(account: account, storeDirectoryURL: directory,
                                          presentsCompatibilityAlerts: false)
        let context = try XCTUnwrap(account.localStorage.getMainContext())
        for (index, id) in ["first", "second"].enumerated() {
            context.insert(SpaceModel(spaceId: id, profileId: "Default", name: id,
                                      colorHex: "#123456", iconName: "circle", sortOrder: index))
        }
        try context.save()
        manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: account)
        await drain()
    }

    override func tearDown() async throws {
        subscriptions.removeAll()
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        await drain()
        manager = nil
        try await account.localStorage.closeForAccountDirectoryRemoval()
        for url in [directory, account.userDataStorage].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousBoundAccount, forKey: SpaceManager.lastBoundAccountUserIDKey)
    }

    func testDockedPreviewTracksDistanceAndCancellationRestoresSource() async throws {
        let slot = try makeSlot(showing: "first", target: "second")
        let source = try XCTUnwrap(slot.visibleController)
        let target = try XCTUnwrap(slot.windowController(for: "second"))
        let surface = source.mainSplitViewController.sidebarViewController
        let width = surface.spaceSwitchBandFrame.width - 8
        XCTAssertTrue(slot.handleSpaceSwipe(.update(distance: -width / 2, velocity: 0, began: true)))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        XCTAssertEqual(slot.activeSpaceId, "first")
        XCTAssertTrue(slot.visibleController === source)
        XCTAssertTrue(source.isPresented)
        XCTAssertFalse(target.isPresented)
        XCTAssertTrue(target.mainSplitViewController.view.isHidden, "Sidebar preview must not reveal the target page")
        let layer = try XCTUnwrap(surface.spaceSwitchBandViews.last?.layer)
        let expected = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : -width / 2
        XCTAssertEqual(layer.transform.m41, expected, accuracy: 1)
        XCTAssertNil(layer.animation(forKey: "phi.hostedBandSlide"), "Fingers down must not start a timed animation")
        await drain()
        let held = try XCTUnwrap(layer.animation(forKey: "phi.hostedBandSwipePosition") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(held.fromValue as? CGFloat), expected, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(held.toValue as? CGFloat), expected, accuracy: 1,
                       "Progress must stay where the fingers stopped even when AppKit relays out the rows")
        slot.handleSpaceSwipe(.update(distance: -width / 4, velocity: 0, began: false))
        XCTAssertEqual(layer.transform.m41, expected / 2, accuracy: 1)
        slot.handleSpaceSwipe(.end(distance: -width / 4, velocity: 0, cancelled: true))
        try await waitForSettle(slot)
        XCTAssertTrue(slot.visibleController === source)
        XCTAssertEqual(layer.transform.m41, 0, accuracy: 0.01)
        XCTAssertNil(layer.animation(forKey: "phi.hostedBandSwipePosition"))
        XCTAssertTrue(target.mainSplitViewController.sidebarViewController.view.isHidden)
    }

    func testReleaseCommitsOnceAfterSettling() async throws {
        let slot = try makeSlot(showing: "first", target: "second")
        var changes: [String?] = []
        slot.$activeSpaceId.dropFirst().sink { changes.append($0) }.store(in: &subscriptions)
        slot.handleSpaceSwipe(.update(distance: -150, velocity: 0, began: true))
        XCTAssertTrue(changes.isEmpty)
        slot.handleSpaceSwipe(.end(distance: -150, velocity: 0, cancelled: false))
        try await waitForSettle(slot)
        XCTAssertEqual(slot.visibleController?.spaceId, "second")
        XCTAssertEqual(changes.compactMap { $0 }, ["second"])
        let target = try XCTUnwrap(slot.visibleController)
        for view in target.mainSplitViewController.sidebarViewController.spaceSwitchBandViews {
            XCTAssertNil(view.layer?.animation(forKey: "phi.hostedBandSlide"), "Landing must not replay the normal switch")
            XCTAssertNil(view.layer?.animation(forKey: "phi.hostedBandSwipePosition"))
        }
        slot.handleSpaceSwipe(.consumed)
        XCTAssertEqual(changes.compactMap { $0 }, ["second"])
    }

    func testEdgeResistanceNeverCommits() async throws {
        let slot = try makeSlot(showing: "first", target: "second")
        let source = try XCTUnwrap(slot.visibleController)
        slot.handleSpaceSwipe(.update(distance: 500, velocity: 0, began: true))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        let layer = try XCTUnwrap(source.mainSplitViewController.sidebarViewController.spaceSwitchBandViews.last?.layer)
        XCTAssertLessThan(layer.transform.m41, 60)
        slot.handleSpaceSwipe(.end(distance: 500, velocity: 2000, cancelled: false))
        try await waitForSettle(slot)
        XCTAssertTrue(slot.visibleController === source)
        XCTAssertEqual(layer.transform.m41, 0, accuracy: 0.01)
    }

    func testDirectionReversalAndWindowResizeCancelCleanly() throws {
        let slot = try makeSlot(showing: "first", target: "second")
        slot.handleSpaceSwipe(.update(distance: -80, velocity: 0, began: true))
        slot.handleSpaceSwipe(.update(distance: 20, velocity: 0, began: false))
        XCTAssertTrue(slot.windowController(for: "second")!.mainSplitViewController.sidebarViewController.view.isHidden)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: slot.shell!.window)
        XCTAssertFalse(slot.isSwitchAnimationInFlight)
        XCTAssertEqual(slot.activeSpaceId, "first")
    }

    func testFloatingSidebarRemainsOpenAndReturnsToSourceOnCancel() async throws {
        let slot = try makeSlot(showing: "first", target: "second")
        let source = try XCTUnwrap(slot.visibleController)
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarCollapsed(true, animated: false)
        split.floatingSidebarHost.showFloatingSidebar()
        slot.handleSpaceSwipe(.update(distance: -80, velocity: 0, began: true))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        XCTAssertTrue(split.floatingSidebarHost.isVisible)
        slot.handleSpaceSwipe(.end(distance: -80, velocity: 0, cancelled: true))
        try await waitForSettle(slot)
        XCTAssertTrue(split.floatingSidebarHost.floatingSidebarViewController === source.mainSplitViewController.floatingSidebarContent)
        XCTAssertTrue(split.isSidebarCollapsed)
    }

    func testTraditionalPreviewRestoresPageOnCancel() async throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let slot = try makeSlot(showing: "first", target: "second")
        let source = try XCTUnwrap(slot.visibleController)
        let target = try XCTUnwrap(slot.windowController(for: "second"))
        slot.handleSpaceSwipe(.update(distance: -100, velocity: 0, began: true))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        XCTAssertEqual(slot.activeSpaceId, "first")
        XCTAssertFalse(target.mainSplitViewController.view.isHidden)
        slot.handleSpaceSwipe(.end(distance: -100, velocity: 0, cancelled: true))
        try await waitForSettle(slot)
        XCTAssertTrue(target.mainSplitViewController.view.isHidden)
        XCTAssertFalse(source.mainSplitViewController.view.isHidden)
        XCTAssertEqual(source.mainSplitViewController.view.layer?.transform.m41 ?? 0, 0, accuracy: 0.01)
    }

    func testProgrammaticActivationCancelsPreviewBeforePresenting() throws {
        let slot = try makeSlot(showing: "first", target: "second")
        slot.handleSpaceSwipe(.update(distance: -80, velocity: 0, began: true))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        slot.activate(spaceId: "second", animated: false)
        XCTAssertFalse(slot.isSwitchAnimationInFlight)
        XCTAssertEqual(slot.visibleController?.spaceId, "second")
        XCTAssertEqual(slot.activeSpaceId, "second")
    }

    func testEvictingPreviewTargetRestoresSource() throws {
        let slot = try makeSlot(showing: "first", target: "second")
        slot.handleSpaceSwipe(.update(distance: -80, velocity: 0, began: true))
        XCTAssertTrue(slot.isSwitchAnimationInFlight)
        slot.evictWindow(for: "second")
        XCTAssertFalse(slot.isSwitchAnimationInFlight)
        XCTAssertEqual(slot.activeSpaceId, "first")
        XCTAssertFalse(slot.visibleController!.mainSplitViewController.sidebarViewController.view.isHidden)
    }

    func testDifferentWindowsTrackTheirOwnSwipe() throws {
        let first = try makeSlot(showing: "first", target: "second")
        let second = try makeSlot(showing: "first", target: "second")
        first.handleSpaceSwipe(.update(distance: -60, velocity: 0, began: true))
        XCTAssertTrue(first.isSwitchAnimationInFlight)
        XCTAssertFalse(second.isSwitchAnimationInFlight)
        second.handleSpaceSwipe(.update(distance: -120, velocity: 0, began: true))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first.shell!.window)
        XCTAssertFalse(first.isSwitchAnimationInFlight)
        XCTAssertTrue(second.isSwitchAnimationInFlight)
        XCTAssertEqual(second.activeSpaceId, "first")
    }

    func testRenderedSelectionBackgroundFollowsSwipeAndReversal() async throws {
        let slot = try makeSlot(showing: "first", target: "second")
        let geometry = SpacesStripGeometry()
        let host = NSHostingView(rootView: SpacesStripView(manager: manager, slot: slot,
            rowHeight: 32, stripGeometry: geometry))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }

        func pixels(concealed: Bool) async throws -> NSBitmapImageRep {
            geometry.isChipConcealed = concealed
            await drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        func renderedCenter(progress: CGFloat) async throws -> CGFloat {
            geometry.swipeSelection = .init(source: "first", target: "second", progress: progress)
            let background = try await pixels(concealed: true)
            let selected = try await pixels(concealed: false)
            var weightedX: CGFloat = 0
            var weight: CGFloat = 0
            for y in 0..<selected.pixelsHigh {
                for x in 0..<selected.pixelsWide {
                    let a = try XCTUnwrap(background.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(selected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let difference = abs(a.redComponent - b.redComponent)
                        + abs(a.greenComponent - b.greenComponent)
                        + abs(a.blueComponent - b.blueComponent)
                        + abs(a.alphaComponent - b.alphaComponent)
                    weightedX += CGFloat(x) * difference
                    weight += difference
                }
            }
            XCTAssertGreaterThan(weight, 1, "The selection background must produce visible pixels")
            return weightedX / max(weight, 1) * host.bounds.width / CGFloat(selected.pixelsWide)
        }
        let origin = try await renderedCenter(progress: 0)
        let first = try XCTUnwrap(geometry.pipFrames["first"])
        let second = try XCTUnwrap(geometry.pipFrames["second"])
        let travel = second.midX - first.midX
        for progress in [CGFloat(0.25), 0.5, 1, 0.5, 0] {
            let center = try await renderedCenter(progress: progress)
            XCTAssertEqual(center - origin, travel * progress, accuracy: 1.5,
                           "Rendered chip must track progress, including reversal, while the source stays active")
            XCTAssertEqual(slot.activeSpaceId, "first")
        }
    }

    private func waitForSettle(_ slot: SpaceWindowSlot) async throws {
        let deadline = Date().addingTimeInterval(2)
        while slot.isSwitchAnimationInFlight, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(slot.isSwitchAnimationInFlight)
    }

    private func makeSlot(showing source: String, target: String = "first") throws -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: source)
        slots.append(slot)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        for id in [source, target] {
            nextWindowId += 1
            let state = BrowserState(windowId: nextWindowId, localStore: account.localStorage,
                                     profileId: "Default", spaceId: id)
            state.tabs = [Tab(guid: nextWindowId, url: "https://example.test", isActive: true,
                              index: 0, title: id)]
            state.updateNormalTabs()
            let session = SpaceSessionController(window: slot.shell!.window, windowId: nextWindowId,
                profileId: state.profileId, spaceId: id, account: account, slot: slot,
                browserState: state, dormant: true)
            session.hostSidebarViewInShell()
            slot.registerWindow(session, for: id)
            if id == source { slot.presentRequestedSession(session, activate: false) }
        }
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot.visibleController?.spaceId, source)
        slot.shell!.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        slot.shell!.window.orderFront(nil)
        XCTAssertTrue(manager.acceptsStoreAction())
        XCTAssertEqual(slot.presentedSpaces.map(\.spaceId), ["first", "second"])
        XCTAssertTrue(slot.shell!.window.isVisible)
        let current = try XCTUnwrap(slot.visibleController)
        XCTAssertTrue(current.mainSplitViewController.isViewLoaded)
        if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            let sidebar = current.mainSplitViewController.sidebarViewController.view
            XCTAssertTrue(sidebar.window === slot.shell!.window)
            XCTAssertFalse(sidebar.isHiddenOrHasHiddenAncestor)
        }
        return slot
    }

    private func drain() async {
        let drained = expectation(description: "Drain UI updates")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

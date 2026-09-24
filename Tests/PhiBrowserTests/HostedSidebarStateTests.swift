// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor
final class HostedSidebarStateTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private var subscriptions = Set<AnyCancellable>()
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 123456789

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "hosted-sidebar-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        SpaceBandSnapshotCache.shared.accountForTesting = account
    }

    override func tearDown() async throws {
        SpaceBandSnapshotCache.shared.accountForTesting = nil
        subscriptions.removeAll()
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        // Drain queued UI reads before resetting their SwiftData context.
        await drainPresentationUpdates()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testColdAndWarmPresentationCannotChangeCollapsedShell() throws {
        try checkPresentation(collapsed: true)
    }

    func testColdAndWarmPresentationCannotChangeExpandedShell() throws {
        try checkPresentation(collapsed: false)
    }

    private func checkPresentation(collapsed: Bool) throws {
        let slot = makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: collapsed)
        var changes: [Bool] = []
        split.sidebarCollapsedPublisher.sink { changes.append($0) }.store(in: &subscriptions)
        let first = makeSession(in: slot, spaceId: "first")
        let cold = makeSession(in: slot, spaceId: "cold")
        // A dormant session already reads the owner, before presentation or
        // Browser creation. There is no default collapse value to inherit.
        XCTAssertEqual(cold.browserState.sidebarCollapsed, collapsed)
        first.presentInShell(completing: false, deferringChromium: true)
        first.concealFromShell(removingView: false, deferringChromium: true)
        cold.presentInShell(installingView: false, completing: false, deferringChromium: true)
        cold.installPageTreeInShell()
        XCTAssertEqual(cold.browserState.sidebarCollapsed, collapsed)
        cold.installSessionViewInShell()
        first.removeSessionViewFromShell()
        cold.concealFromShell(removingView: false, deferringChromium: true)
        first.presentInShell(completing: false, deferringChromium: true)
        cold.removeSessionViewFromShell()
        XCTAssertEqual(split.isSidebarCollapsed, collapsed)
        XCTAssertEqual(first.browserState.sidebarWidth, split.sidebarWidth)
        XCTAssertEqual(cold.browserState.sidebarWidth, split.sidebarWidth)
        XCTAssertEqual(changes, [collapsed], "Session lifecycle must never write shell geometry")
    }

    func testSubscribersBeforeControllerAttachmentObserveTheSharedOwner() throws {
        let slot = makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: true)
        let state = makeState(spaceId: "cold")
        var changes: [Bool] = []
        state.sidebarCollapsedPublisher.sink { changes.append($0) }.store(in: &subscriptions)
        let cold = makeSession(in: slot, state: state)
        XCTAssertTrue(try XCTUnwrap(changes.last))
        split.setSidebarCollapsed(false, animated: false)
        XCTAssertFalse(state.sidebarCollapsed)
        XCTAssertFalse(try XCTUnwrap(changes.last))
        // Observe while still dormant, and again while its tree is concealed.
        cold.presentInShell(completing: false, deferringChromium: true)
        cold.concealFromShell(deferringChromium: true)
        split.setSidebarCollapsed(true, animated: false)
        XCTAssertTrue(state.sidebarCollapsed)
        XCTAssertTrue(try XCTUnwrap(changes.last))
    }

    func testCommandsChangeOnlyTheirOwningShell() async throws {
        let firstSlot = makeSlot()
        let secondSlot = makeSlot()
        let first = makeSession(in: firstSlot, spaceId: "first")
        let second = makeSession(in: secondSlot, spaceId: "second")
        let firstSplit = try XCTUnwrap(firstSlot.shell?.split)
        let secondSplit = try XCTUnwrap(secondSlot.shell?.split)
        firstSplit.setSidebarGeometry(width: 240, collapsed: false)
        secondSplit.setSidebarGeometry(width: 320, collapsed: false)
        // The menu/header command reaches the window owner directly, even
        // before this session has a Browser or has been presented.
        first.browserState.toggleSidebar(true)
        await drainPresentationUpdates()
        XCTAssertTrue(firstSplit.isSidebarCollapsed)
        XCTAssertFalse(secondSplit.isSidebarCollapsed)
        XCTAssertEqual(first.browserState.sidebarWidth, 0)
        XCTAssertEqual(second.browserState.sidebarWidth, secondSplit.sidebarWidth)
    }

    func testStandaloneIncognitoAndKioskRemainIndependent() async throws {
        let slot = makeSlot()
        let hosted = makeSession(in: slot, spaceId: "hosted")
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: false)
        let state = makeState(spaceId: "standalone")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
            browserType: .incognito, profileId: state.profileId, account: store.account, browserState: state)
        defer { window.close(); withExtendedLifetime(controller) {} }
        var changes: [Bool] = []
        state.sidebarCollapsedPublisher.sink { changes.append($0) }.store(in: &subscriptions)
        state.toggleSidebar(true)
        await drainPresentationUpdates()
        XCTAssertTrue(state.sidebarCollapsed)
        XCTAssertTrue(try XCTUnwrap(changes.last))
        XCTAssertFalse(hosted.browserState.sidebarCollapsed)
        let standaloneHost = controller.mainSplitViewController.webContentContainerViewController.floatingSidebarHost
        XCTAssertFalse(standaloneHost === split.floatingSidebarHost)
        standaloneHost.showFloatingSidebar()
        XCTAssertTrue(standaloneHost.isVisible)
        XCTAssertFalse(split.floatingSidebarHost.isVisible)
        let kiosk = KioskBrowserState(windowId: 123456700, localStore: store, profileId: "Default", isIncognito: false)
        kiosk.toggleSidebar(false)
        XCTAssertTrue(kiosk.sidebarCollapsed)
        XCTAssertEqual(kiosk.sidebarWidth, 0)
    }

    func testFloatingPanelStaysOpenAcrossSpacesThatNeverOpenedIt() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let visited = makeSession(in: slot, spaceId: "visited-without-floating")
        let cold = makeSession(in: slot, spaceId: "cold")
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.setSidebarCollapsed(true, animated: false)
        // Visit the target without ever opening the floating sidebar there.
        visited.presentInShell(completing: false, deferringChromium: true)
        visited.concealFromShell(deferringChromium: true)
        first.presentInShell(completing: false, deferringChromium: true)
        host.showFloatingSidebar()
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        XCTAssertTrue(host.isVisible)
        for target in [visited, cold, first] {
            target.presentInShell(completing: false, deferringChromium: true)
            for other in [first, visited, cold] where other !== target {
                other.concealFromShell(deferringChromium: true)
            }
            XCTAssertTrue(host.isVisible)
            XCTAssertTrue(host.floatingSidebarContainerView === panel)
            XCTAssertTrue(host.browserState === target.browserState)
            XCTAssertTrue(panel.window === slot.shell?.window)
            XCTAssertTrue(target.mainSplitViewController.webContentContainerViewController
                .floatingSidebarHost === host)
        }
        // A hidden panel must also stay hidden; a Space has no remembered
        // floating visibility to restore on return.
        host.hideFloatingSidebar(animated: false)
        visited.presentInShell(completing: false, deferringChromium: true)
        XCTAssertFalse(host.isVisible)
        XCTAssertTrue(host.floatingSidebarContainerView === panel)
        // The hidden panel still mounts the presented Space's own content
        // (hidden), so the next hover opens it without a rebuild.
        let mounted = try XCTUnwrap(host.floatingSidebarViewController)
        XCTAssertTrue(mounted.state === visited.browserState)
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible)
        XCTAssertNotNil(host.floatingSidebarViewController)
        XCTAssertTrue(host.floatingSidebarContainerView === panel)
    }

    func testFloatingResidentSwitchPreservesGeometryAfterResize() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "resize-first")
        let next = makeSession(in: slot, spaceId: "resize-next")
        first.warmUpDormantTree()
        next.warmUpDormantTree()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.setSidebarCollapsed(true, animated: false)
        first.presentInShell(completing: false, deferringChromium: true)
        host.showFloatingSidebar()
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let oldHeight = panel.frame.height
        let window = try XCTUnwrap(slot.shell?.window)
        window.setContentSize(NSSize(width: 1100, height: 820))
        split.view.layoutSubtreeIfNeeded()
        host.beginSpaceSwitch()
        host.present(next.browserState, retainingPrevious: true)
        let content = try XCTUnwrap(host.floatingSidebarViewController)
        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.floatingSidebarContainerView === panel)
        XCTAssertNotEqual(panel.frame.height, oldHeight)
        XCTAssertEqual(panel.frame.height, host.view.bounds.height - 10, accuracy: 0.5)
        XCTAssertEqual(content.view.frame, try XCTUnwrap(content.view.superview).bounds)
        XCTAssertEqual(panel.frame.minX, 0, accuracy: 0.5)
        host.finishSpaceSwitch()
    }

    func testPinnedPreparationReconcilesChangesBeforePublisherDelivery() throws {
        let state = makeState(spaceId: "pinned-prepare")
        let controller = PinnedTabViewController(state: state)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        controller.setActive(true)
        let collection = try XCTUnwrap(descendants(of: controller.view)
            .compactMap { $0 as? NSCollectionView }.first)
        let first = Tab(url: "https://example.test/first", isActive: false,
                        index: 0, customGuid: "prepare-first")
        let second = Tab(url: "https://example.test/second", isActive: false,
                         index: 1, customGuid: "prepare-second")
        state.pinnedTabs = [first]
        controller.formRestoredContentNow()
        XCTAssertEqual(collection.numberOfItems(inSection: 1), 1)
        let height = controller.contentHeight
        controller.formRestoredContentNow()
        XCTAssertEqual(collection.numberOfItems(inSection: 1), 1)
        XCTAssertEqual(controller.contentHeight, height)
        // No runloop drain: preparation must see changes even while the
        // Combine delivery is queued, including after an unchanged prepare.
        state.pinnedTabs = [second, first]
        controller.formRestoredContentNow()
        XCTAssertEqual(collection.numberOfItems(inSection: 1), 2)
        state.pinnedTabs = []
        controller.formRestoredContentNow()
        XCTAssertEqual(collection.numberOfItems(inSection: 1), 0)
        controller.setActive(false)
    }

    func testSnapshotPNGPreservesRetinaSizeAndTransparency() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 10, y: 10)
        rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 20, y: 20)
        let png = try XCTUnwrap(SpaceBandSnapshotCache.pngData(
            pixels: try XCTUnwrap(rep.cgImage), logicalSize: NSSize(width: 200, height: 100)))
        let image = try XCTUnwrap(NSImage(data: png))
        XCTAssertEqual(image.size.width, 200, accuracy: 0.1)
        XCTAssertEqual(image.size.height, 100, accuracy: 0.1)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 400)
        XCTAssertEqual(decoded.pixelsHigh, 200)
        XCTAssertEqual(try XCTUnwrap(decoded.colorAt(x: 10, y: 10)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(decoded.colorAt(x: 20, y: 20)).alphaComponent, 0, accuracy: 0.01)
    }

    func testBandCapturedAtAnotherWidthDoesNotStandIn() throws {
        let slot = makeSlot()
        let session = makeSession(in: slot, spaceId: UUID().uuidString)
        session.warmUpDormantTree()
        let split = try XCTUnwrap(slot.shell?.split)
        session.presentInShell(completing: false, deferringChromium: true)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        let source: any SpaceSwitchBandSurface = session.mainSplitViewController.sidebarViewController
        source.prepareSpaceSwitchBand()
        let spaceId = UUID().uuidString
        SpaceBandSnapshotCache.shared.capture(source, spaceId: spaceId)
        defer { SpaceBandSnapshotCache.shared.remove(spaceId: spaceId) }
        let width = source.spaceSwitchBandFrame.width

        XCTAssertNotNil(SpaceBandSnapshotCache.shared.snapshot(for: spaceId, appearanceOf: source.view,
                                                               width: width))
        // The sidebar was resized since the capture: the image would stand
        // in at its old size, so the switch goes without it.
        XCTAssertNil(SpaceBandSnapshotCache.shared.snapshot(for: spaceId, appearanceOf: source.view,
                                                            width: width + 60))
    }

    func testIncognitoBandIsNeverSnapshotted() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        let incognitoId = "\(SpaceManager.incognitoSpaceIdPrefix).test-\(UUID().uuidString)"
        let incognito = makeSession(in: slot, spaceId: incognitoId)
        first.warmUpDormantTree()
        incognito.warmUpDormantTree()
        let split = try XCTUnwrap(slot.shell?.split)
        first.presentInShell(completing: false, deferringChromium: true)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        let source: any SpaceSwitchBandSurface = first.mainSplitViewController.sidebarViewController
        source.prepareSpaceSwitchBand()

        // The cache refuses an Incognito id outright, while the same render
        // is kept for a regular Space, so the refusal is the id's.
        SpaceBandSnapshotCache.shared.capture(source, spaceId: incognitoId)
        XCTAssertNil(SpaceBandSnapshotCache.shared.snapshot(for: incognitoId, appearanceOf: source.view))
        let regularId = UUID().uuidString
        SpaceBandSnapshotCache.shared.capture(source, spaceId: regularId)
        defer { SpaceBandSnapshotCache.shared.remove(spaceId: regularId) }
        XCTAssertNotNil(SpaceBandSnapshotCache.shared.snapshot(for: regularId, appearanceOf: source.view))

        // The switch's own capture entry skips an Incognito session before
        // rendering anything.
        incognito.presentInShell(completing: false, deferringChromium: true)
        split.view.layoutSubtreeIfNeeded()
        SpaceWindowSlot.HostedBandSlide.captureBand(of: incognito)
        XCTAssertNil(SpaceBandSnapshotCache.shared.snapshot(for: incognitoId, appearanceOf: source.view))
        let directory = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory())
            .appendingPathComponent("SpaceBandSnapshots")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasPrefix(incognitoId) })
    }

    func testResidentAddressBarsBindToTheirOwnSession() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        let second = makeSession(in: slot, spaceId: UUID().uuidString)
        // Both sidebars become resident in the shell; only `first` is
        // presented, so the shell's windowController is `first`.
        first.warmUpDormantTree()
        second.warmUpDormantTree()
        first.presentInShell(completing: false, deferringChromium: true)
        XCTAssertTrue(slot.shell?.window.windowController === first)
        func addressBar(in view: NSView) -> SideAddressBar? {
            if let bar = view as? SideAddressBar { return bar }
            for subview in view.subviews {
                if let bar = addressBar(in: subview) { return bar }
            }
            return nil
        }
        let firstBar = try XCTUnwrap(addressBar(in: first.mainSplitViewController.sidebarViewController.view))
        let secondBar = try XCTUnwrap(addressBar(in: second.mainSplitViewController.sidebarViewController.view))
        XCTAssertTrue(firstBar.sessionBrowserStateForTesting === first.browserState)
        XCTAssertTrue(secondBar.sessionBrowserStateForTesting === second.browserState)
    }

    func testCrashPagesBindToTheirOwnSession() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        let second = makeSession(in: slot, spaceId: UUID().uuidString)
        first.warmUpDormantTree()
        second.warmUpDormantTree()
        // `second` was presented once, so its page tree stays resident in
        // the shell (hidden); `first` is the presented Space, so the shell's
        // windowController is `first`.
        second.presentInShell(completing: false, deferringChromium: true)
        second.concealFromShell(removingView: false, deferringChromium: true)
        first.presentInShell(completing: false, deferringChromium: true)
        second.removeSessionViewFromShell()
        XCTAssertTrue(slot.shell?.window.windowController === first)
        XCTAssertTrue(second.mainSplitViewController.view.isHidden)
        XCTAssertNotNil(second.mainSplitViewController.view.window)

        let tab = Tab(url: "https://example.com", isActive: true, index: 0)
        tab.crashState = CrashPageData(dictionary: ["title": "Aw, Snap!",
                                                    "buttonLabel": "Reload",
                                                    "helpLinkUrl": "https://example.com/help"])
        let page = WebContentViewController(state: second.browserState, tab: tab)
        let container = second.mainSplitViewController.webContentContainerViewController.view
        container.addSubview(page.view)
        page.view.frame = container.bounds
        page.updateAssociatedTab(tab)
        let crash = try XCTUnwrap(page.crashedPageControllerForTesting)
        XCTAssertTrue(crash.hostForTesting === second)
        XCTAssertFalse(crash.hostForTesting === first)
    }

    func testConcealingASessionDropsItsLiftedFullscreenPage() async throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        first.warmUpDormantTree()
        first.presentInShell(completing: false, deferringChromium: true)
        let shell = try XCTUnwrap(slot.shell)
        let tab = Tab(url: "https://example.com", isActive: true, index: 0)
        let page = WebContentViewController(state: first.browserState, tab: tab)
        let container = first.mainSplitViewController.webContentContainerViewController.view
        container.addSubview(page.view)
        page.view.frame = container.bounds
        // A page going fullscreen is lifted under the shell's content view,
        // above every Space.
        tab.isInContentFullscreen = true
        await drainPresentationUpdates()
        XCTAssertTrue(page.hostViewForTesting.superview === shell.window.contentView)
        // The Space leaving the shell takes its page with it, before the
        // tree is hidden: what the next Space shows is its own.
        first.concealFromShell(removingView: false, deferringChromium: true)
        first.removeSessionViewFromShell()
        XCTAssertFalse(page.hostViewForTesting.superview === shell.window.contentView)
        XCTAssertTrue(page.hostViewForTesting.isDescendant(of: page.view))
        XCTAssertTrue(first.mainSplitViewController.view.isHidden)
    }

    func testHostedCaptureComposesTheShellLayoutForABackgroundSession() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        let second = makeSession(in: slot, spaceId: UUID().uuidString)
        first.warmUpDormantTree()
        second.warmUpDormantTree()
        first.presentInShell(completing: false, deferringChromium: true)
        let shell = try XCTUnwrap(slot.shell)
        let split = try XCTUnwrap(shell.split)
        split.setSidebarCollapsed(false, animated: false)
        let canvas = try XCTUnwrap(shell.window.contentView)
        canvas.layoutSubtreeIfNeeded()
        XCTAssertFalse(second.isPresented)
        // The capture is the whole window the user would see — sidebar column
        // and page area — not the page tree alone.
        let rep = try XCTUnwrap(AgentSpaceRouter.renderWindow(of: second, webImage: nil))
        XCTAssertEqual(rep.size, canvas.bounds.size)
        XCTAssertGreaterThan(split.sidebarWidth, 0)
        XCTAssertLessThan(second.mainSplitViewController.view.frame.width, canvas.bounds.width)
        XCTAssertEqual(second.mainSplitViewController.view.frame.width,
                       split.contentHost.view.frame.width)
    }

    func testFloatingBandSlideUsesSharedPanelForIncomingContent() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let cold = makeSession(in: slot, spaceId: "cold")
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.setSidebarCollapsed(true, animated: false)
        first.presentInShell(completing: false, deferringChromium: true)
        host.showFloatingSidebar()
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let leavingSurface = try XCTUnwrap(host.floatingSidebarViewController)
        let slide = SpaceWindowSlot.HostedBandSlide(
            slot: slot, leaving: first, enteringSpaceId: cold.spaceId, root: host.view,
            bandFrame: leavingSurface.spaceSwitchBandFrame,
            leavingBandViews: leavingSurface.spaceSwitchBandViews,
            leavingBandContainer: leavingSurface.spaceSwitchBandContainer,
            direction: .forward, duration: 0.25, restoreLeavingTheme: {})
        slide.start()
        first.concealFromShell(removingView: false, deferringChromium: true)
        cold.presentInShell(installingView: false, completing: false, deferringChromium: true)
        slide.attachEntering(cold)
        let enteringSurface = try XCTUnwrap(host.floatingSidebarViewController)
        XCTAssertFalse(enteringSurface === leavingSurface)
        XCTAssertTrue(enteringSurface.parent === host)
        XCTAssertTrue(leavingSurface.parent === host)
        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.floatingSidebarContainerView === panel)
        XCTAssertTrue(enteringSurface.spaceSwitchBandViews.contains {
            $0.layer?.animation(forKey: "phi.hostedBandSlide") != nil
        })
        slide.settle()
        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.floatingSidebarContainerView === panel)
        XCTAssertTrue(leavingSurface.parent === host)
        XCTAssertTrue(leavingSurface.view.isHidden)
        XCTAssertTrue(enteringSurface.parent === host)
        XCTAssertTrue(host.browserState === cold.browserState)
        XCTAssertTrue(split.isSidebarCollapsed)
    }

    func testFloatingContentStaysResidentAndUpdatesWhileConcealed() async throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let next = makeSession(in: slot, spaceId: "next")
        first.warmUpDormantTree()
        next.warmUpDormantTree()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        let firstContent = first.mainSplitViewController.floatingSidebarContent
        let nextContent = next.mainSplitViewController.floatingSidebarContent
        XCTAssertTrue(firstContent.parent === host)
        XCTAssertTrue(nextContent.parent === host)
        XCTAssertTrue(nextContent.view.isHidden)
        XCTAssertFalse(host.isVisible, "Warming content must not reveal the panel")
        first.presentInShell(completing: false, deferringChromium: true)
        split.setSidebarCollapsed(true, animated: false)
        host.showFloatingSidebar()
        let outline = try XCTUnwrap(descendants(of: firstContent.view)
            .compactMap { $0 as? NSOutlineView }.first)
        let originalRowCount = outline.numberOfRows
        XCTAssertGreaterThan(originalRowCount, 0)
        next.presentInShell(completing: false, deferringChromium: true)
        first.removeSessionViewFromShell()
        XCTAssertTrue(firstContent.parent === host)
        XCTAssertTrue(firstContent.view.isHidden)
        XCTAssertEqual(outline.numberOfRows, originalRowCount,
                       "Switching away must not clear the resident outline")
        let backgroundTab = Tab(guid: 9010, url: "https://example.test",
            isActive: true, index: 0, title: "Updated while concealed")
        first.browserState.tabs = [backgroundTab]
        first.browserState.updateNormalTabs()
        await drainPresentationUpdates()
        XCTAssertTrue((0..<outline.numberOfRows).contains {
            (outline.item(atRow: $0) as? Tab)?.guid == backgroundTab.guid
        }, "Concealed content must keep receiving updates before the next click")
        host.host(first.browserState)
        XCTAssertTrue(firstContent.view.isHidden, "Hosting an existing tree must not present it")
        first.presentInShell(completing: false, deferringChromium: true)
        XCTAssertTrue(host.floatingSidebarViewController === firstContent)
        XCTAssertFalse(firstContent.view.isHidden)
        next.removeSessionViewFromShell(evictingSidebar: true)
        XCTAssertNil(nextContent.parent)
        XCTAssertNil(nextContent.view.superview)
    }

    func testFloatingPanelSurvivesPendingHideDuringSwitch() async throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.setSidebarCollapsed(true, animated: false)
        first.presentInShell(completing: false, deferringChromium: true)
        host.showFloatingSidebar()
        host.hideFloatingSidebar(animated: true)
        host.beginSpaceSwitch()
        let animationDrained = expectation(description: "Old hide animation completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { animationDrained.fulfill() }
        await fulfillment(of: [animationDrained], timeout: 2)
        XCTAssertTrue(host.isVisible, "An old hide completion must not dismiss the switching panel")
        host.finishSpaceSwitch()
        split.setSidebarCollapsed(false, animated: false)
        XCTAssertFalse(host.isVisible, "Expanding the docked sidebar still dismisses the floating panel")
    }

    func testFloatingOverlayDoesNotInterceptPageOutsidePanel() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let split = try XCTUnwrap(slot.shell?.split)
        first.presentInShell(completing: false, deferringChromium: true)
        split.view.layoutSubtreeIfNeeded()
        let host = split.floatingSidebarHost
        let point = NSPoint(x: host.view.frame.midX, y: host.view.frame.midY)
        XCTAssertNil(host.view.hitTest(point))
        split.setSidebarCollapsed(true, animated: false)
        host.showFloatingSidebar()
        XCTAssertNil(host.view.hitTest(point))
    }

    func testFloatingSlideBackdropStaysClearThroughThemeUpdates() async throws {
        guard #available(macOS 26, *) else { return }
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarCollapsed(true, animated: false)
        first.presentInShell(completing: false, deferringChromium: true)
        let host = split.floatingSidebarHost
        host.showFloatingSidebar()
        let surface = try XCTUnwrap(host.floatingSidebarViewController)
        surface.setSpaceSwitchBackdropHidden(true)
        first.browserState.themeContext.setTheme(first.browserState.themeContext.currentTheme)
        await drainPresentationUpdates()
        XCTAssertNil(surface.view.phiLayer?.backgroundColor,
                     "An incoming surface must not rebind its background during the theme ramp")
        XCTAssertNil(surface.view.layer?.backgroundColor)
        surface.setSpaceSwitchBackdropHidden(false)
        XCTAssertNotNil(surface.view.phiLayer?.backgroundColor)
    }

    func testFloatingAndDockedBandsUseTheSamePreparedMotion() throws {
        for direction in [SpaceWindowSlot.SwapDirection.forward, .backward] {
            var motions: [[Double]] = []
            for floating in [false, true] {
                let slot = makeSlot()
                let first = makeSession(in: slot, spaceId: UUID().uuidString)
                let next = makeSession(in: slot, spaceId: UUID().uuidString)
                for (index, session) in [first, next].enumerated() {
                    session.browserState.tabs = [Tab(guid: 9000 + index, url: "https://example.test",
                        isActive: true, index: 0, title: "Space \(index)")]
                    session.browserState.updateNormalTabs()
                }
                let split = try XCTUnwrap(slot.shell?.split)
                let host = split.floatingSidebarHost
                first.hostSidebarViewInShell()
                next.hostSidebarViewInShell()
                first.presentInShell(completing: false, deferringChromium: true)
                split.setSidebarGeometry(width: 240, collapsed: false)
                split.view.layoutSubtreeIfNeeded()
                if floating {
                    split.setSidebarCollapsed(true, animated: false)
                    host.showFloatingSidebar()
                    host.host(next.browserState)
                    XCTAssertTrue(next.mainSplitViewController.floatingSidebarContent.view.isHidden)
                    XCTAssertTrue(next.mainSplitViewController.floatingSidebarContent.parent === host)
                }
                let source: any SpaceSwitchBandSurface = floating
                    ? try XCTUnwrap(host.floatingSidebarViewController)
                    : first.mainSplitViewController.sidebarViewController
                source.view.layoutSubtreeIfNeeded()
                next.mainSplitViewController.sidebarViewController.view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(source.spaceSwitchBandFrame.width, 190)
                XCTAssertGreaterThan(source.spaceSwitchBandFrame.height, 100)
                let preparedFrame = floating
                    ? next.mainSplitViewController.floatingSidebarContent.spaceSwitchBandFrame
                    : next.mainSplitViewController.sidebarViewController.spaceSwitchBandFrame
                let slide = SpaceWindowSlot.HostedBandSlide(slot: slot, leaving: first, enteringSpaceId: next.spaceId,
                    root: floating ? host.view : split.sidebarHost.view,
                    bandFrame: source.spaceSwitchBandFrame,
                    leavingBandViews: source.spaceSwitchBandViews,
                    leavingBandContainer: source.spaceSwitchBandContainer,
                    direction: direction, duration: 0.25, restoreLeavingTheme: {})
                let timing = SpaceSwitchTiming(operation: "test_switch", event: nil)
                timing.sidebar = slot.timingSidebarMode
                timing.target = "regular"
                timing.preparation = "dormant"
                slide.timing = timing
                XCTAssertEqual(timing.sidebar, floating ? "floating" : "pinned")
                slide.start()
                next.presentInShell(installingView: false, completing: false, deferringChromium: true)
                slide.attachEntering(next)
                let target: any SpaceSwitchBandSurface = floating
                    ? try XCTUnwrap(host.floatingSidebarViewController)
                    : next.mainSplitViewController.sidebarViewController
                XCTAssertEqual(target.spaceSwitchBandFrame, preparedFrame,
                               "Incoming geometry must be formed before the slide starts")
                let outgoingLayer = try XCTUnwrap(source.spaceSwitchBandViews.last?.layer)
                let incomingLayer = try XCTUnwrap(target.spaceSwitchBandViews.last?.layer)
                let outgoing = try XCTUnwrap(outgoingLayer.animation(forKey: "phi.hostedBandSlide") as? CABasicAnimation)
                let incoming = try XCTUnwrap(incomingLayer.animation(forKey: "phi.hostedBandSlide") as? CABasicAnimation)
                XCTAssertEqual(outgoingLayer.convertTime(outgoing.beginTime, to: nil),
                               incomingLayer.convertTime(incoming.beginTime, to: nil), accuracy: 0.001)
                XCTAssertEqual(incoming.timingFunction, outgoing.timingFunction)
                let distance = Double(source.spaceSwitchBandFrame.width - 8)
                motions.append([incoming.duration, outgoing.duration,
                    try XCTUnwrap(incoming.fromValue as? Double) / distance,
                    try XCTUnwrap(outgoing.toValue as? Double) / distance])
                if floating {
                    XCTAssertTrue(host.floatingSidebarViewController === next.mainSplitViewController.floatingSidebarContent)
                    XCTAssertNil(target.view.phiLayer?.backgroundColor)
                    if #available(macOS 26, *) {
                        let fillLayer = try XCTUnwrap(source.view.layer)
                        let fill = try XCTUnwrap(fillLayer.animation(forKey: "phi.fillRamp") as? CABasicAnimation)
                        XCTAssertEqual(fill.duration, incoming.duration)
                        XCTAssertEqual(fill.timingFunction, incoming.timingFunction)
                        XCTAssertEqual(fillLayer.convertTime(fill.beginTime, to: nil),
                                       incomingLayer.convertTime(incoming.beginTime, to: nil), accuracy: 0.001)
                    }
                }
                slide.settle()
                let names = timing.steps.map(\.name)
                let prepare = try XCTUnwrap(names.firstIndex(of: "sidebar.prepare.begin"))
                let rows = try XCTUnwrap(names.firstIndex(of: "rows.realize.end"))
                let display = try XCTUnwrap(names.firstIndex(of: "sidebar.display.end"))
                let clock = try XCTUnwrap(names.firstIndex(of: "animation.clock_start"))
                let submitted = try XCTUnwrap(names.firstIndex(of: "animation.transaction_submitted"))
                let cleanup = try XCTUnwrap(names.firstIndex(of: "animation.cleanup.end"))
                XCTAssertLessThan(prepare, rows)
                XCTAssertLessThan(rows, display)
                XCTAssertLessThan(display, clock)
                XCTAssertLessThan(clock, submitted)
                XCTAssertLessThan(submitted, cleanup)
                XCTAssertEqual(timing.steps.map(\.milliseconds), timing.steps.map(\.milliseconds).sorted())
                timing.flush()
            }
            XCTAssertEqual(motions[0], motions[1], "Floating and docked motion must match in either direction")
        }
    }

    func testEnteringSideIsHeldAtItsStartUntilMotionBegins() throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: UUID().uuidString)
        let next = makeSession(in: slot, spaceId: UUID().uuidString)
        for (index, session) in [first, next].enumerated() {
            session.browserState.tabs = [Tab(guid: 9100 + index, url: "https://example.test",
                isActive: true, index: 0, title: "Space \(index)")]
            session.browserState.updateNormalTabs()
        }
        let split = try XCTUnwrap(slot.shell?.split)
        first.hostSidebarViewInShell()
        next.hostSidebarViewInShell()
        first.presentInShell(completing: false, deferringChromium: true)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        let source = first.mainSplitViewController.sidebarViewController
        source.view.layoutSubtreeIfNeeded()
        let slide = SpaceWindowSlot.HostedBandSlide(slot: slot, leaving: first, enteringSpaceId: next.spaceId,
            root: split.sidebarHost.view,
            bandFrame: source.spaceSwitchBandFrame,
            leavingBandViews: source.spaceSwitchBandViews,
            leavingBandContainer: source.spaceSwitchBandContainer,
            direction: .forward, duration: 0.25, restoreLeavingTheme: {})
        slide.start()
        next.presentInShell(installingView: false, completing: false, deferringChromium: true)
        slide.attachEntering(next)
        // The attach commits a frame one turn before the motion is added:
        // that frame must not show the entering band at rest over the
        // leaving one, nor the entering page at full opacity.
        let travel = source.spaceSwitchBandFrame.width - 8
        let bandViews = next.mainSplitViewController.sidebarViewController.spaceSwitchBandViews
        for view in bandViews {
            let layer = try XCTUnwrap(view.layer)
            XCTAssertNil(layer.animation(forKey: "phi.hostedBandSlide"))
            XCTAssertEqual(layer.transform.m41, travel, accuracy: 0.5)
            // AppKit can put the transform back when it syncs layer
            // geometry; the band is also kept transparent until then.
            XCTAssertEqual(view.alphaValue, 0)
        }
        let page = try XCTUnwrap(next.mainSplitViewController.view.layer)
        XCTAssertEqual(page.opacity, 0)
        // Settled before the motion started: nothing may stay held.
        slide.settle()
        for view in bandViews {
            XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(view.layer).transform))
            XCTAssertEqual(view.alphaValue, 1)
        }
        XCTAssertEqual(page.opacity, 1)
    }

    func testSharedPinnedStripStaysPutWhileTheListSlides() async throws {
        for shared in [true, false] {
            let slot = makeSlot()
            let first = makeSession(in: slot, spaceId: UUID().uuidString)
            let next = makeSession(in: slot, spaceId: UUID().uuidString)
            for (index, session) in [first, next].enumerated() {
                session.browserState.tabs = [Tab(guid: 9200 + index, url: "https://example.test",
                    isActive: true, index: 0, title: "Space \(index)")]
                session.browserState.updateNormalTabs()
                // Same physical row in both Spaces = one shared collection.
                let row = shared ? "pinned-row" : "pinned-row-\(index)"
                session.browserState.pinnedTabs = [Tab(guid: 9300 + index, url: "https://pinned.test",
                    isActive: false, index: 0, title: "Pinned", customGuid: row)]
            }
            let split = try XCTUnwrap(slot.shell?.split)
            first.hostSidebarViewInShell()
            next.hostSidebarViewInShell()
            first.presentInShell(completing: false, deferringChromium: true)
            split.setSidebarGeometry(width: 240, collapsed: false)
            split.view.layoutSubtreeIfNeeded()
            let source = first.mainSplitViewController.sidebarViewController
            let target = next.mainSplitViewController.sidebarViewController
            source.view.layoutSubtreeIfNeeded()
            target.view.layoutSubtreeIfNeeded()
            let slide = SpaceWindowSlot.HostedBandSlide(slot: slot, leaving: first, enteringSpaceId: next.spaceId,
                root: split.sidebarHost.view,
                bandFrame: source.spaceSwitchBandFrame,
                leavingBandViews: source.spaceSwitchBandViews,
                leavingBandContainer: source.spaceSwitchBandContainer,
                leavingPinnedStrip: source.spaceSwitchPinnedStrip,
                direction: .forward, duration: 0.25, restoreLeavingTheme: {})
            slide.start()
            next.presentInShell(installingView: false, completing: false, deferringChromium: true)
            slide.attachEntering(next)
            await drainPresentationUpdates()
            let key = "phi.hostedBandSlide"
            let leavingPinned = try XCTUnwrap(source.spaceSwitchPinnedStrip.layer)
            let enteringPinned = target.spaceSwitchPinnedStrip
            XCTAssertNotNil(source.spaceSwitchBandViews.last?.layer?.animation(forKey: key),
                            "The tab list slides either way (shared=\(shared))")
            XCTAssertEqual(leavingPinned.animation(forKey: key) == nil, shared,
                           "Only a pinned strip of its own slides out (shared=\(shared))")
            XCTAssertEqual(enteringPinned.layer?.animation(forKey: key) == nil, shared,
                           "Only a pinned strip of its own slides in (shared=\(shared))")
            if shared {
                XCTAssertEqual(enteringPinned.alphaValue, 0, "The entering copy waits for the landing")
            }
            slide.settle()
            XCTAssertEqual(enteringPinned.alphaValue, 1)
        }
    }

    func testPageResidencyPreservesAttachmentAndHidesBeforeEviction() throws {
        final class VisibilityProbe: NSView {
            var windowMoves = 0
            var hides = 0
            override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowMoves += 1 }
            override func viewDidHide() { super.viewDidHide(); hides += 1 }
        }
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let next = makeSession(in: slot, spaceId: "next")
        first.warmUpDormantTree()
        next.warmUpDormantTree()
        let host = try XCTUnwrap(slot.shell?.split.contentHost)
        let page = first.mainSplitViewController.view
        let probe = VisibilityProbe(frame: .zero)
        page.addSubview(probe)
        XCTAssertTrue(page.isHidden)
        XCTAssertTrue(page.superview === host.view)
        first.installPageTreeInShell()
        let moves = probe.windowMoves
        next.installPageTreeInShell()
        first.removeSessionViewFromShell()
        XCTAssertTrue(probe.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(probe.hides, 0, "Chromium's viewDidHide must receive ancestor hiding")
        XCTAssertTrue(page.window === slot.shell?.window)
        host.view.setFrameSize(NSSize(width: 730, height: 600))
        first.installPageTreeInShell()
        XCTAssertEqual(page.frame, host.view.bounds)
        XCTAssertTrue(host.view.subviews.last === page)
        XCTAssertFalse(probe.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(probe.windowMoves, moves, "A return switch must not reattach the native page")
        first.removeSessionViewFromShell(evictingSidebar: true)
        XCTAssertNil(page.superview)
        XCTAssertNil(probe.window)
    }

    func testSnapshotLayerPreservesPointSizeAndClipsAtTopLeft() throws {
        let source = try XCTUnwrap(CGContext(data: nil, width: 400, height: 600,
            bitsPerComponent: 8, bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        source.setFillColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
        source.fill(CGRect(x: 0, y: 300, width: 400, height: 300))
        let pixels = try XCTUnwrap(source.makeImage())
        let view = SpaceBandSnapshotView(snapshot: .init(pixels: pixels, size: NSSize(width: 200, height: 300)),
            frame: NSRect(x: 20, y: 40, width: 240, height: 250))
        let root = try XCTUnwrap(view.layer)
        let image = try XCTUnwrap(root.sublayers?.first)
        XCTAssertTrue(root.masksToBounds)
        XCTAssertTrue((image.contents as AnyObject?) === pixels)
        XCTAssertEqual(image.contentsScale, 2)
        XCTAssertEqual(image.frame, NSRect(x: 0, y: -50, width: 200, height: 300),
                       "A smaller viewport clips the bottom without stretching the cached image")
        let output = try XCTUnwrap(CGContext(data: nil, width: 240, height: 250,
            bitsPerComponent: 8, bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        root.render(in: output)
        let bytes = try XCTUnwrap(output.data).assumingMemoryBound(to: UInt8.self)
        // CALayer.render writes top-first scanlines, matching NSImageView's
        // rendered layer (rather than CGContext's source drawing coordinates).
        XCTAssertEqual(bytes[(10 * 240 + 10) * 4], 255, "The top of the snapshot stays at the top")
        XCTAssertEqual(bytes[(240 * 240 + 10) * 4 + 2], 255, "The bottom is clipped, not scaled")
        XCTAssertEqual(bytes[(10 * 240 + 220) * 4 + 3], 0, "Widening the panel must not stretch cached pixels")

    }

    func testCachedColdSlideUsesPixelsUntilLiveRowsAreReady() async throws {
        for floating in [false, true] {
            let slot = makeSlot()
            let first = makeSession(in: slot, spaceId: UUID().uuidString)
            let cold = makeSession(in: slot, spaceId: UUID().uuidString)
            first.warmUpDormantTree()
            cold.warmUpDormantTree()
            let split = try XCTUnwrap(slot.shell?.split)
            first.presentInShell(completing: false, deferringChromium: true)
            split.setSidebarGeometry(width: 240, collapsed: false)
            split.view.layoutSubtreeIfNeeded()
            if floating {
                split.setSidebarCollapsed(true, animated: false)
                split.floatingSidebarHost.showFloatingSidebar()
            }
            let source: any SpaceSwitchBandSurface = floating
                ? first.mainSplitViewController.floatingSidebarContent
                : first.mainSplitViewController.sidebarViewController
            source.prepareSpaceSwitchBand()
            SpaceBandSnapshotCache.shared.capture(source, spaceId: cold.spaceId)
            defer { SpaceBandSnapshotCache.shared.remove(spaceId: cold.spaceId) }
            XCTAssertNotNil(SpaceBandSnapshotCache.shared.snapshot(for: cold.spaceId, appearanceOf: source.view))
            let target: any SpaceSwitchBandSurface = floating
                ? cold.mainSplitViewController.floatingSidebarContent
                : cold.mainSplitViewController.sidebarViewController
            let originalLayer = target.spaceSwitchBandContainer.layer
            let timing = SpaceSwitchTiming(operation: "test_cached_switch", event: nil)
            let slide = SpaceWindowSlot.HostedBandSlide(slot: slot, leaving: first, enteringSpaceId: cold.spaceId,
                root: split.view, bandFrame: source.spaceSwitchBandFrame,
                leavingBandViews: source.spaceSwitchBandViews,
                leavingBandContainer: source.spaceSwitchBandContainer,
                direction: .forward, duration: 0.25, restoreLeavingTheme: {})
            slide.timing = timing
            slide.start()
            cold.presentInShell(installingView: false, completing: false, deferringChromium: true)
            slide.attachEntering(cold)
            XCTAssertTrue(timing.steps.contains { $0.name == "sidebar.cached_pixels.ready" })
            XCTAssertFalse(timing.steps.contains { $0.name == "rows.display.end" })
            let standIn = try XCTUnwrap(target.spaceSwitchBandContainer.subviews.compactMap { $0 as? SpaceBandSnapshotView }.first)
            XCTAssertNotNil(standIn.layer?.animation(forKey: "phi.hostedBandSlide"))
            slide.settle()
            XCTAssertTrue(target.spaceSwitchBandContainer.layer === originalLayer,
                          "Switch completion must preserve resident layer contents")
            cold.browserState.tabs = [Tab(guid: 9991, url: "https://example.test", isActive: true,
                                          index: 0, title: "Restored tab")]
            cold.browserState.updateNormalTabs()
            await drainPresentationUpdates()
            await drainPresentationUpdates()
            XCTAssertTrue(timing.steps.contains { $0.name == "rows.display.end" })
            XCTAssertTrue(target.spaceSwitchBandViews.allSatisfy { $0.alphaValue == 1 })
            let outline = try XCTUnwrap(descendants(of: target.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertTrue((0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? Tab)?.guid == 9991 })
            XCTAssertTrue((0..<outline.numberOfRows).contains {
                (outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
            })
        }
    }

    func testColdSlideWaitsForTargetAndRealizesNewTabBeforeMoving() throws {
        for floating in [false, true] {
            let slot = makeSlot()
            let first = makeSession(in: slot, spaceId: UUID().uuidString)
            let cold = makeSession(in: slot, spaceId: UUID().uuidString)
            first.warmUpDormantTree()
            cold.warmUpDormantTree()
            let split = try XCTUnwrap(slot.shell?.split)
            first.presentInShell(completing: false, deferringChromium: true)
            split.setSidebarGeometry(width: 240, collapsed: false)
            split.view.layoutSubtreeIfNeeded()
            if floating {
                split.setSidebarCollapsed(true, animated: false)
                split.floatingSidebarHost.showFloatingSidebar()
            }
            let source: any SpaceSwitchBandSurface = floating
                ? try XCTUnwrap(split.floatingSidebarHost.floatingSidebarViewController)
                : first.mainSplitViewController.sidebarViewController
            // A prior transition can capture while live rows are hidden.
            // Such an empty snapshot must not mask the target's New Tab row.
            source.setSwitchBandContentHidden(true)
            SpaceBandSnapshotCache.shared.capture(source, spaceId: cold.spaceId)
            source.setSwitchBandContentHidden(false)
            XCTAssertNil(SpaceBandSnapshotCache.shared.image(for: cold.spaceId, appearanceOf: source.view))
            defer { SpaceBandSnapshotCache.shared.remove(spaceId: cold.spaceId) }
            let slide = SpaceWindowSlot.HostedBandSlide(slot: slot, leaving: first, enteringSpaceId: cold.spaceId,
                root: split.view, bandFrame: source.spaceSwitchBandFrame,
                leavingBandViews: source.spaceSwitchBandViews,
                leavingBandContainer: source.spaceSwitchBandContainer,
                direction: .forward, duration: 0.25, restoreLeavingTheme: {})
            slide.start()
            for view in source.spaceSwitchBandViews {
                XCTAssertNil(view.layer?.animation(forKey: "phi.hostedBandSlide"),
                             "Cold setup must not send the outgoing rows into an empty destination")
            }
            cold.presentInShell(installingView: false, completing: false, deferringChromium: true)
            slide.attachEntering(cold)
            let target: any SpaceSwitchBandSurface = floating
                ? try XCTUnwrap(split.floatingSidebarHost.floatingSidebarViewController)
                : cold.mainSplitViewController.sidebarViewController
            let outline = try XCTUnwrap(descendants(of: target.view).compactMap { $0 as? NSOutlineView }.first)
            let newTabRow = try XCTUnwrap((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
            })
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: newTabRow, makeIfNecessary: false))
            XCTAssertTrue(cell is NewTabButtonCellView)
            XCTAssertFalse(cell.isHiddenOrHasHiddenAncestor)
            XCTAssertGreaterThan(cell.bounds.width, 100)
            for view in target.spaceSwitchBandViews {
                XCTAssertEqual(view.alphaValue, 1)
                XCTAssertNotNil(view.layer?.animation(forKey: "phi.hostedBandSlide"))
            }
            XCTAssertTrue(cold.isDormant, "New Tab must exist without a Chromium Browser")
            slide.settle()
        }
    }

    func testIncognitoPrewarmIsInvisibleAndAdoptsTheSameNativeTree() async throws {
        manager.bind(to: store.account)
        await drainPresentationUpdates()
        let slot = makeSlot()
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let spaceIds = manager.spaces.map(\.spaceId)
        let active = SpaceSessionControllersManager.shared.activeWindowController
        manager.prewarmIncognitoContent(windowId: 123456790, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let prepared = try XCTUnwrap(manager.prewarmedIncognitoContent)
        XCTAssertNil(prepared.state.windowController)
        XCTAssertNil(prepared.sidebarViewController.spacesStripRowView)
        XCTAssertNil(prepared.floatingSidebarContent.spacesStripRowView)
        XCTAssertNil(prepared.view.window)
        XCTAssertNil(prepared.sidebarViewController.view.window)
        XCTAssertNil(prepared.floatingSidebarContent.view.window)
        XCTAssertFalse(prepared.webContentContainerViewController.children.contains {
            $0 is FloatingSidebarHostViewController
        }, "An unbound hosted tree must not build a second floating panel owner")
        XCTAssertTrue(prepared.state.isIncognito)
        XCTAssertTrue(prepared.state.isIncognitoSpace)
        XCTAssertTrue(prepared.state.tabs.isEmpty)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertEqual(manager.spaces.map(\.spaceId), spaceIds)
        XCTAssertTrue(SpaceSessionControllersManager.shared.activeWindowController === active)
        XCTAssertNil(SpaceSessionControllersManager.shared.controller(for: prepared.state.windowId))
        XCTAssertTrue(slot.dormantSessionsBySpaceId.isEmpty)
        XCTAssertTrue(slot.windowsBySpaceId.isEmpty)
        XCTAssertFalse(store.getAllSpaces().contains { $0.spaceId == prepared.state.spaceId })
        let timing = SpaceSwitchTiming(operation: "test_new_incognito", event: nil)
        let requestedId = manager.createIncognitoSpace(timing: timing)
        XCTAssertEqual(timing.preparation, "spare_hit")
        XCTAssertTrue(timing.steps.contains { $0.name == "incognito.space_list.publish.end" })
        XCTAssertTrue(timing.steps.contains { $0.name == "incognito.replacement.schedule.end" })
        XCTAssertEqual(requestedId, prepared.state.spaceId)
        XCTAssertNil(manager.prewarmedIncognitoContent)
        XCTAssertTrue(manager.spaces.contains { $0.spaceId == requestedId })
        manager.adoptPrewarmedIncognitoContent(spaceId: requestedId, in: slot)
        let adopted = try XCTUnwrap(slot.dormantSessionsBySpaceId[requestedId])
        XCTAssertTrue(adopted.mainSplitViewController === prepared)
        XCTAssertNotNil(prepared.sidebarViewController.spacesStripRowView)
        XCTAssertNotNil(prepared.floatingSidebarContent.spacesStripRowView)
        XCTAssertTrue(adopted.browserState === prepared.state)
        XCTAssertTrue(adopted.isDormant)
        XCTAssertNil(adopted.hostedChromiumWindow)
        XCTAssertEqual(adopted.browserType, .incognitoSpace)
        XCTAssertTrue(slot.dormantSession(forWindowId: prepared.state.windowId) === adopted)
        // Refill once, with a fresh state/id. Repeated refill requests cannot
        // allocate several spares, and the published list stays unchanged.
        manager.prewarmIncognitoContent(windowId: 123456791, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let replacement = try XCTUnwrap(manager.prewarmedIncognitoContent)
        manager.prewarmIncognitoContent(windowId: 123456792, localStore: store,
            size: NSSize(width: 1000, height: 700))
        XCTAssertTrue(manager.prewarmedIncognitoContent === replacement)
        XCTAssertNotEqual(replacement.state.spaceId, requestedId)
        XCTAssertNotEqual(replacement.state.windowId, adopted.windowId)
        XCTAssertNil(replacement.state.windowController)
        XCTAssertFalse(manager.spaces.contains { $0.spaceId == replacement.state.spaceId })
        XCTAssertEqual(manager.createIncognitoSpace(), replacement.state.spaceId)
        manager.adoptPrewarmedIncognitoContent(spaceId: replacement.state.spaceId, in: slot)
        XCTAssertTrue(slot.dormantSessionsBySpaceId[requestedId] === adopted)
        XCTAssertTrue(slot.dormantSessionsBySpaceId[replacement.state.spaceId]?
            .mainSplitViewController === replacement)
    }

    func testIncognitoPrewarmCannotCrossAnAccountChange() async throws {
        manager.bind(to: store.account)
        await drainPresentationUpdates()
        let slot = makeSlot()
        manager.prewarmIncognitoContent(windowId: 123456795, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let requestedId = manager.createIncognitoSpace()
        manager.prewarmIncognitoContent(windowId: 123456796, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let otherAccount = Account(userID: "incognito-prewarm-test-\(UUID().uuidString)")
        let otherDirectory = directory.appendingPathComponent("other-store")
        let otherStore = LocalStore(account: otherAccount, storeDirectoryURL: otherDirectory,
            presentsCompatibilityAlerts: false)
        otherAccount.localStorage = otherStore
        manager.bind(to: otherAccount)
        await drainPresentationUpdates()
        XCTAssertNil(manager.prewarmedIncognitoContent)
        manager.adoptPrewarmedIncognitoContent(spaceId: requestedId, in: slot)
        XCTAssertTrue(slot.dormantSessionsBySpaceId.isEmpty)
        manager.prewarmIncognitoContent(windowId: 123456797, localStore: store,
            size: NSSize(width: 1000, height: 700))
        XCTAssertNil(manager.prewarmedIncognitoContent, "A stale store cannot refill the spare")
        manager.discardSpacePrewarm()
        try await otherStore.closeForAccountDirectoryRemoval()
        if FileManager.default.fileExists(atPath: otherAccount.userDataStorage.path) {
            try FileManager.default.removeItem(at: otherAccount.userDataStorage)
        }
    }

    func testAgentSpareIsUnboundAndAdoptsTheRequestedProfileAndShell() async throws {
        manager.bind(to: store.account)
        await drainPresentationUpdates()
        let firstSlot = makeSlot()
        let targetSlot = makeSlot()
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let spaceIds = manager.spaces.map(\.spaceId)
        let taskIds = Set(AgentSpaceManager.shared.tasksBySpaceId.keys)
        manager.prewarmAgentContent(windowId: 123456800, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let prepared = try XCTUnwrap(manager.prewarmedAgentContent)
        manager.prewarmAgentContent(windowId: 123456801, localStore: store,
            size: NSSize(width: 1000, height: 700))
        XCTAssertTrue(manager.prewarmedAgentContent === prepared, "There is only one agent spare")
        await drainPresentationUpdates()
        XCTAssertTrue(prepared.state.profileId.isEmpty)
        XCTAssertTrue(prepared.state.bookmarkManager.scope.profileId.isEmpty)
        XCTAssertFalse(prepared.state.bookmarkManager.didApplyFirstStoreDelivery)
        XCTAssertTrue(prepared.state.isAgentSpace)
        XCTAssertFalse(prepared.state.isIncognito)
        XCTAssertTrue(prepared.state.pinnedTabs.isEmpty)
        XCTAssertNil(prepared.state.windowController)
        XCTAssertNil(prepared.view.window)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertEqual(manager.spaces.map(\.spaceId), spaceIds)
        XCTAssertEqual(Set(AgentSpaceManager.shared.tasksBySpaceId.keys), taskIds)
        XCTAssertNil(SpaceSessionControllersManager.shared.controller(for: prepared.state.windowId))
        XCTAssertFalse(store.getAllSpaces().contains { $0.spaceId == prepared.state.spaceId })
        let profile = "agent-prewarm-profile-\(UUID().uuidString)"
        let claimedId = try XCTUnwrap(manager.claimPrewarmedAgentContent(profileId: profile))
        XCTAssertNil(manager.prewarmedAgentContent)
        XCTAssertTrue(prepared.state.profileId.isEmpty, "Claiming does not access the profile's store")
        XCTAssertEqual(manager.createSpace(name: "R1", colorHex: AgentSpaceManager.spaceColorHex,
            iconName: AgentSpaceManager.spaceIconName, profileId: profile,
            makeDefaultActive: false, spaceId: claimedId), claimedId)
        let session = try XCTUnwrap(manager.adoptPrewarmedAgentContent(spaceId: claimedId, in: targetSlot))
        XCTAssertTrue(session.mainSplitViewController === prepared)
        XCTAssertTrue(session.browserState === prepared.state)
        XCTAssertEqual(session.profileId, profile)
        XCTAssertEqual(prepared.state.profileId, profile)
        XCTAssertEqual(prepared.state.bookmarkManager.scope.profileId, profile)
        XCTAssertTrue(session.window === targetSlot.shell?.window)
        XCTAssertTrue(firstSlot.dormantSessionsBySpaceId.isEmpty)
        XCTAssertTrue(session.isDormant)
        XCTAssertNil(session.hostedChromiumWindow)
        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(session.browserType, .agentSpace)
        XCTAssertTrue(targetSlot.dormantSession(forWindowId: prepared.state.windowId) === session)
        XCTAssertFalse(prepared.state.bindPrewarmedAgentProfile("another-profile"))
        XCTAssertNil(manager.adoptPrewarmedAgentContent(spaceId: claimedId, in: firstSlot))
        manager.prewarmAgentContent(windowId: 123456802, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let replacement = try XCTUnwrap(manager.prewarmedAgentContent)
        XCTAssertFalse(replacement === prepared)
        XCTAssertTrue(replacement.state.profileId.isEmpty)
        XCTAssertNil(replacement.state.windowController)
        XCTAssertNotEqual(replacement.state.spaceId, claimedId)
    }

    func testAgentSpareRejectsDeniedProfilesAndChangedRequestBindings() async throws {
        manager.bind(to: store.account)
        await drainPresentationUpdates()
        let profile = "agent-prewarm-denied-\(UUID().uuidString)"
        let previousDenied = PhiPreferences.AgentSpaces.disallowedAgentProfileIds
        defer { PhiPreferences.AgentSpaces.disallowedAgentProfileIds = previousDenied }
        PhiPreferences.AgentSpaces.disallowedAgentProfileIds.insert(profile)
        manager.prewarmAgentContent(windowId: 123456803, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let prepared = try XCTUnwrap(manager.prewarmedAgentContent)
        XCTAssertNil(manager.claimPrewarmedAgentContent(profileId: profile))
        XCTAssertTrue(manager.prewarmedAgentContent === prepared)
        PhiPreferences.AgentSpaces.disallowedAgentProfileIds.remove(profile)
        let claimedId = try XCTUnwrap(manager.claimPrewarmedAgentContent(profileId: profile))
        _ = manager.createSpace(name: "R1", colorHex: AgentSpaceManager.spaceColorHex,
            iconName: AgentSpaceManager.spaceIconName, profileId: "different-profile",
            makeDefaultActive: false, spaceId: claimedId)
        let slot = makeSlot()
        XCTAssertNil(manager.adoptPrewarmedAgentContent(spaceId: claimedId, in: slot))
        XCTAssertTrue(slot.dormantSessionsBySpaceId.isEmpty)
        XCTAssertTrue(prepared.state.profileId.isEmpty)
        manager.prewarmAgentContent(windowId: 123456804, localStore: store,
            size: NSSize(width: 1000, height: 700))
        manager.markTerminating()
        XCTAssertNil(manager.prewarmedAgentContent)
    }

    func testIncognitoPrewarmIsDiscardedOnTermination() async throws {
        manager.bind(to: store.account)
        await drainPresentationUpdates()
        let slot = makeSlot()
        manager.prewarmIncognitoContent(windowId: 123456793, localStore: store,
            size: NSSize(width: 1000, height: 700))
        let requestedId = manager.createIncognitoSpace()
        manager.prewarmIncognitoContent(windowId: 123456794, localStore: store,
            size: NSSize(width: 1000, height: 700))
        manager.markTerminating()
        XCTAssertNil(manager.prewarmedIncognitoContent)
        manager.adoptPrewarmedIncognitoContent(spaceId: requestedId, in: slot)
        XCTAssertTrue(slot.dormantSessionsBySpaceId.isEmpty)
    }

    func testDormantCommandsReplayOnlyInTheirOriginatingSession() async throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let second = makeSession(in: slot, spaceId: "second")
        let shell = try XCTUnwrap(slot.shell?.window)
        let target = HostedCommandRecordingWindow()
        defer { target.close() }
        first.presentInShell(completing: false, deferringChromium: true)
        shell.commandDispatch(nil)
        second.presentInShell(completing: false, deferringChromium: true)
        shell.commandTargetWindow = target
        await drainPresentationUpdates()
        XCTAssertEqual(target.commandCount, 0, "A new Space must not inherit queued commands")

        first.presentInShell(completing: false, deferringChromium: true)
        shell.commandDispatch(nil)
        shell.commandTargetWindow = target
        await drainPresentationUpdates()
        XCTAssertEqual(target.commandCount, 1, "The original session can replay after attachment")
    }

    func testDeferredCommandReplayStopsAfterPresentationChanges() async throws {
        let slot = makeSlot()
        let first = makeSession(in: slot, spaceId: "first")
        let second = makeSession(in: slot, spaceId: "second")
        let shell = try XCTUnwrap(slot.shell?.window)
        let target = HostedCommandRecordingWindow()
        defer { target.close() }
        first.presentInShell(completing: false, deferringChromium: true)
        shell.commandDispatch(nil)
        shell.commandTargetWindow = target
        // Switch after the replay was posted, before it executes.
        second.presentInShell(completing: false, deferringChromium: true)
        shell.commandTargetWindow = target
        await drainPresentationUpdates()
        XCTAssertEqual(target.commandCount, 0)

        first.presentInShell(completing: false, deferringChromium: true)
        shell.commandDispatch(nil)
        shell.commandDispatch(nil)
        target.onCommand = {
            second.presentInShell(completing: false, deferringChromium: true)
        }
        shell.commandTargetWindow = target
        await drainPresentationUpdates()
        XCTAssertEqual(target.commandCount, 1, "A command that changes Space cancels the remaining replay")
        target.onCommand = nil
    }

    func testChromiumCreationFrameIsUsedOnlyForANewShell() throws {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slots.append(slot)
        // Below the saved-frame repair threshold, but above the shell minimum.
        let requested = NSRect(x: 90, y: 120, width: 520, height: 420)
        let shell = slot.prepareShellForChromiumWindow(windowId: 123456810,
            frame: requested, waitsForShow: true)
        XCTAssertEqual(shell.window.frame, requested)
        XCTAssertFalse(shell.window.isVisible)
        let sameShell = slot.prepareShellForChromiumWindow(windowId: 123456811,
            frame: NSRect(x: 200, y: 240, width: 900, height: 700), waitsForShow: false)
        XCTAssertTrue(shell === sameShell)
        XCTAssertEqual(shell.window.frame, requested, "A sibling cannot overwrite shell geometry")
    }

    func testInactiveInitialShowDoesNotActivateOrRevealOtherSpaces() async throws {
        let slot = makeSlot()
        let shell = slot.prepareShellForChromiumWindow(windowId: 123456812,
            frame: .zero, waitsForShow: true)
        let first = makeSession(in: slot, spaceId: "first")
        slot.registerWindow(first, for: first.spaceId)
        XCTAssertFalse(shell.window.isVisible, "Registration must wait for Chromium's show intent")
        let otherWindow = HostedCommandRecordingWindow()
        otherWindow.makeKeyAndOrderFront(nil)
        defer { otherWindow.close() }
        slot.presentRequestedSession(first, activate: false)
        await drainPresentationUpdates()
        XCTAssertTrue(shell.window.isVisible)
        XCTAssertTrue(otherWindow.isKeyWindow)
        XCTAssertFalse(shell.window.isKeyWindow)
        let second = makeSession(in: slot, spaceId: "second")
        slot.registerWindow(second, for: second.spaceId)
        slot.presentRequestedSession(second, activate: false)
        await drainPresentationUpdates()
        XCTAssertTrue(slot.visibleController === first)
        XCTAssertTrue(otherWindow.isKeyWindow)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeSlot() -> SpaceWindowSlot {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        return slot
    }

    private func makeState(spaceId: String) -> BrowserState {
        nextWindowId += 1
        return BrowserState(windowId: nextWindowId, localStore: store, profileId: "Default", spaceId: spaceId)
    }

    private func makeSession(in slot: SpaceWindowSlot, spaceId: String) -> SpaceSessionController {
        makeSession(in: slot, state: makeState(spaceId: spaceId))
    }

    private func makeSession(in slot: SpaceWindowSlot, state: BrowserState) -> SpaceSessionController {
        SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            slot: slot, browserState: state, dormant: true)
    }

    private func drainPresentationUpdates() async {
        let drained = expectation(description: "Presentation updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

@MainActor
private final class HostedCommandRecordingWindow: NSWindow {
    var commandCount = 0
    var onCommand: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    @objc func commandDispatch(_ sender: Any?) {
        commandCount += 1
        onCommand?()
    }
}

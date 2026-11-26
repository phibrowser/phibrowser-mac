// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Pinning the sidebar from the floating panel, or unpinning it with the
/// shortcut while the pointer is on it, changes one sidebar in place: the
/// floating panel covers the column while the column opens or closes under
/// it, and morphs between its inset glass shape and the column's flush shape.
@MainActor
final class SidebarDockHandOffTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var previousSidebarPosition: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223478789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    private typealias Host = FloatingSidebarHostViewController

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        previousSidebarPosition = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.left)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "sidebar-dock-hand-off-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        context.insert(SpaceModel(spaceId: "first", profileId: LocalStore.defaultProfileId,
            name: "first", colorHex: "#AAAAAA", iconName: "target", sortOrder: 0))
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousSidebarPosition, forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        try await super.tearDown()
    }

    private let inset = FloatingSidebarHostViewController.floatingSidebarInset

    // MARK: - Host primitives

    func testDockingTheVisiblePanelKeepsItOnScreenUntilTheColumnIsOpen() throws {
        let (_, host) = try visiblePanel()

        XCTAssertTrue(host.beginSidebarHandOff(.dock))
        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.isSidebarHandOffRunning)
        host.animateSidebarHandOff()
        host.view.layoutSubtreeIfNeeded()

        let frame = try rowsFrame(in: host)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "the docked shape is flush with the window edge")
        XCTAssertEqual(frame.height, host.view.bounds.height, accuracy: 0.5, "the docked shape spans the full height")
        host.finishSidebarHandOffImmediately()
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testTheRestingShapeIsBackAfterADock() throws {
        let (_, host) = try visiblePanel()
        XCTAssertTrue(host.beginSidebarHandOff(.dock))
        host.animateSidebarHandOff()
        host.finishSidebarHandOffImmediately()

        host.showFloatingSidebar()
        host.view.layoutSubtreeIfNeeded()

        let frame = try visualFrame(in: host)
        XCTAssertEqual(frame.minX, inset, accuracy: 0.5)
        XCTAssertEqual(frame.height, host.view.bounds.height - 2 * inset, accuracy: 0.5)
        XCTAssertEqual(host.floatingSidebarContainerView?.alphaValue ?? 0, 1, accuracy: 0.01)
    }

    func testDockingAHiddenPanelIsNotAHandOff() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        XCTAssertFalse(host.isVisible, "precondition: the panel is hidden")

        XCTAssertFalse(host.beginSidebarHandOff(.dock))
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testUndockShowsThePanelInTheDockedShape() throws {
        let (split, host) = try expandedColumn()

        XCTAssertTrue(host.beginSidebarHandOff(.undock))
        XCTAssertTrue(host.isVisible)
        host.view.layoutSubtreeIfNeeded()

        let frame = try rowsFrame(in: host)
        let column = split.sidebarHost.view.convert(split.sidebarHost.view.bounds, to: host.view)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.height, host.view.bounds.height, accuracy: 0.5)
        XCTAssertEqual(frame.width, column.width, accuracy: 0.5, "the panel covers exactly the column")
        host.finishSidebarHandOffImmediately()
    }

    /// The glass draws a rim just inside its edge. Docked, an edge on the
    /// window's edge would draw a second line just inside the window's own
    /// border, so the glass reaches past the window there, and its rows sit
    /// inset by as much.
    func testInTheDockedShapeTheGlassRimLiesOutsideTheWindow() throws {
        let (split, host) = try expandedColumn()

        XCTAssertTrue(host.beginSidebarHandOff(.undock))
        host.view.layoutSubtreeIfNeeded()

        let glass = try visualFrame(in: host)
        let rows = try rowsFrame(in: host)
        let column = split.sidebarHost.view.convert(split.sidebarHost.view.bounds, to: host.view)
        XCTAssertLessThanOrEqual(glass.minX, -inset + 0.5, "past the window's leading edge")
        XCTAssertLessThanOrEqual(glass.minY, -inset + 0.5, "past the window's bottom edge")
        XCTAssertGreaterThanOrEqual(glass.maxY, host.view.bounds.maxY + inset - 0.5, "past the window's top edge")
        XCTAssertEqual(glass.maxX, column.maxX, accuracy: 0.5, "and on the column's trailing edge")
        XCTAssertEqual(rows.minX, column.minX, accuracy: 0.5)
        XCTAssertEqual(rows.width, column.width, accuracy: 0.5)
        XCTAssertEqual(rows.minY, 0, accuracy: 0.5)
        XCTAssertEqual(rows.height, host.view.bounds.height, accuracy: 0.5)
        host.finishSidebarHandOffImmediately()
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try rowsFrame(in: host), try visualFrame(in: host), "at rest the rows fill the glass")
    }

    func testAfterAnUndockThePanelRestsAndStaysUnderThePointer() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }
        split.setSidebarCollapsed(true, animated: true)
        XCTAssertTrue(host.isSidebarHandOffRunning, "precondition: the unpin hands off")

        host.finishSidebarHandOffImmediately()
        host.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
        let frame = try visualFrame(in: host)
        XCTAssertEqual(frame.minX, inset, accuracy: 0.5, "the panel rests in its inset glass shape")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(host.isVisible, "the minimum visible time counts from the end of the hand-off")
    }

    func testAHoverHideDuringTheDockHandOffDoesNotHideThePanelEarly() throws {
        let (_, host) = try visiblePanel()
        XCTAssertTrue(host.beginSidebarHandOff(.dock))

        host.scheduleFloatingSidebarHide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))

        XCTAssertTrue(host.isSidebarHandOffRunning)
        XCTAssertTrue(host.isVisible, "the pointer leaving mid hand-off does not slide the panel out")
        host.finishSidebarHandOffImmediately()
    }

    func testTheAvailabilityReactionWaitsForTheHandOff() throws {
        let (split, host) = try visiblePanel()
        split.setSidebarCollapsed(false, animated: true)
        XCTAssertTrue(host.isSidebarHandOffRunning, "precondition: the pin hands off")

        host.updateFloatingSidebarAvailability()

        XCTAssertTrue(host.isVisible, "the column opening does not pull the cover away")
        host.finishSidebarHandOffImmediately()
        XCTAssertFalse(host.isVisible)
    }

    func testOnTheRightTheDockedShapeIsFlushWithTheRightEdge() throws {
        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        let (_, host) = try visiblePanel()

        XCTAssertTrue(host.beginSidebarHandOff(.dock))
        host.animateSidebarHandOff()
        host.view.layoutSubtreeIfNeeded()

        let frame = try rowsFrame(in: host)
        XCTAssertEqual(frame.maxX, host.view.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(frame.height, host.view.bounds.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(try visualFrame(in: host).maxX, host.view.bounds.maxX + inset - 0.5,
                                    "the glass reaches past the window's trailing edge")
        host.finishSidebarHandOffImmediately()
    }

    func testComfortableLayoutRefusesAHandOff() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let slot = try makeSlot()
        let host = try XCTUnwrap(slot.shell?.split).floatingSidebarHost

        XCTAssertFalse(host.beginSidebarHandOff(.undock))
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testTheUndockPullsInWhileTheColumnCloses() throws {
        let (_, host) = try expandedColumn()
        XCTAssertTrue(host.beginSidebarHandOff(.undock))
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let visual = try XCTUnwrap(host.floatingSidebarContainerView?.subviews.first)

        host.animateSidebarHandOff()

        // Read the glide from its animation rather than sampling frames: a
        // busy run loop can skip the whole toggle between two samples.
        let layer = try XCTUnwrap(visual.layer)
        let glide = try XCTUnwrap(layer.animation(forKey: "sidebarHandOff.position") as? CABasicAnimation,
                                  "the glass glides")
        let sizing = try XCTUnwrap(layer.animation(forKey: "sidebarHandOff.bounds") as? CABasicAnimation)
        let startCenter = try XCTUnwrap(glide.fromValue as? NSValue).pointValue
        let startWidth = try XCTUnwrap(sizing.fromValue as? NSValue).rectValue.width
        XCTAssertEqual(startCenter.x - startWidth * layer.anchorPoint.x, -Host.dockedGlassOverhang, accuracy: 0.5,
                       "it starts flush, over the column")
        XCTAssertEqual(glide.duration, Host.sidebarHandOffDuration, accuracy: 0.001,
                       "it pulls in with the column, not after it")
        XCTAssertEqual(glide.timingFunction, SidebarToggleAnimation.timingFunction, "on the column's curve")
        XCTAssertEqual(visual.frame.minX, inset, accuracy: 0.5)
        host.finishSidebarHandOffImmediately()
    }

    /// Through the real toggle: begin and glide run in the same turn, with no
    /// frame drawn between them.
    func testAnUnpinStartsThePanelAtTheColumnsWidthOnEveryFrame() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let visual = try XCTUnwrap(host.floatingSidebarContainerView?.subviews.first)
        let restingWidth = visual.frame.width
        var widths: [CGFloat] = []
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            widths.append(visual.layer?.presentation()?.bounds.width ?? visual.frame.width)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }

        XCTAssertGreaterThan(restingWidth, 100, "precondition: the panel has its width")
        XCTAssertTrue(widths.allSatisfy { $0 > restingWidth - 1 },
                      "the panel never grows in from a smaller width: \(widths)")
        host.finishSidebarHandOffImmediately()
    }

    /// A panel the pointer has hidden waits off screen. Unpinning later must
    /// not slide it in from there: it starts over the column.
    func testAnUnpinAfterThePanelWasHiddenDoesNotSlideItInFromOffScreen() throws {
        let (split, host) = try visiblePanel()
        host.hideFloatingSidebar(animated: false)
        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        // The hidden position reaches the screen before the next toggle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        var xs: [CGFloat] = []
        let end = Date().addingTimeInterval(0.3)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            xs.append((panel.layer?.presentation() ?? panel.layer)?.frame.minX ?? .nan)
        }

        XCTAssertTrue(xs.allSatisfy { abs($0 - panel.frame.minX) < 1 }, "the panel holds its place over the column: \(xs)")
        host.finishSidebarHandOffImmediately()
    }

    /// The panel's last showing left a rounded, bordered content layer on
    /// screen. An unpin must start square and borderless over the column,
    /// not with that border hugging the window's edge.
    func testAnUnpinStartsTheBorderAndCornerFromTheColumnsShape() throws {
        let (split, host) = try visiblePanel()
        split.setSidebarCollapsed(false, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(split.isSidebarCollapsed, "precondition: docked again")
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let content = try XCTUnwrap(Self.contentLayer(in: panel))
        let corner = try XCTUnwrap(content.animation(forKey: "sidebarHandOff.cornerRadius") as? CABasicAnimation,
                                   "the corner glides in")
        XCTAssertEqual((corner.fromValue as? NSNumber)?.doubleValue ?? -1, 0, accuracy: 0.01, "square over the column")
        XCTAssertNil(content.animation(forKey: "sidebarHandOff.borderWidth"),
                     "no border glides: it would show as a line on the panel's top edge")
        XCTAssertEqual(content.borderWidth, 0, "no border while the panel moves")

        host.finishSidebarHandOffImmediately()
        XCTAssertEqual(content.borderWidth, 1, "the border is back at rest")
        XCTAssertNotNil(content.animation(forKey: "borderIn"), "and fades in")
    }

    func testThePanelsContentStaysOpaqueThroughAnUnpin() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let opacities = try sampleContentOpacity(in: host, for: 0.2)

        XCTAssertTrue(opacities.allSatisfy { $0 > 0.99 }, "only the glass fades, not the rows: \(opacities)")
        host.finishSidebarHandOffImmediately()
    }

    func testThePanelsContentStaysOpaqueWhileThePinGlides() throws {
        let (split, host) = try visiblePanel()

        split.setSidebarCollapsed(false, animated: true)
        // The glide runs 0.25 s; the panel fades off the column only after.
        let opacities = try sampleContentOpacity(in: host, for: 0.2)

        XCTAssertTrue(opacities.allSatisfy { $0 > 0.99 }, "only the glass fades, not the rows: \(opacities)")
        host.finishSidebarHandOffImmediately()
    }

    func testStartingAHandOffStopsThePanelsRunningMotion() throws {
        let (_, host) = try visiblePanel()
        let layer = try XCTUnwrap(host.floatingSidebarContainerView?.layer)
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -100
        slide.toValue = 0
        slide.duration = 1
        layer.add(slide, forKey: "slideIn")

        XCTAssertTrue(host.beginSidebarHandOff(.dock))

        XCTAssertNil(layer.animation(forKey: "slideIn"), "the cover holds still over the column")
        host.finishSidebarHandOffImmediately()
    }

    func testPinningWhileThePanelSlidesOutBringsItBack() throws {
        let (_, host) = try visiblePanel()
        host.hideFloatingSidebar(animated: true)
        XCTAssertTrue(host.isVisible, "precondition: the slide-out runs")

        XCTAssertTrue(host.beginSidebarHandOff(.dock))
        host.animateSidebarHandOff()
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(host.isVisible, "the slide-out's end does not pull the cover away")
        XCTAssertEqual(try rowsFrame(in: host).minX, 0, accuracy: 0.5, "the cover is back at the edge")
        host.finishSidebarHandOffImmediately()
    }

    // MARK: - Lining up with the column

    func testInTheDockedShapeThePanelsHeaderLinesUpWithTheColumnsInPerformance() throws {
        try assertPanelHeaderLinesUpWithTheColumn(in: .performance)
    }

    func testInTheDockedShapeThePanelsHeaderLinesUpWithTheColumnsInBalanced() throws {
        try assertPanelHeaderLinesUpWithTheColumn(in: .balanced)
    }

    func testAtRestThePanelsHeaderKeepsItsFloatingSpacing() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }
        split.setSidebarCollapsed(true, animated: true)
        host.finishSidebarHandOffImmediately()
        host.view.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let button = try XCTUnwrap(Self.view(identified: "sidebarHeader.sidebarButton", in: panel))
        let frame = button.convert(button.bounds, to: nil)
        XCTAssertEqual(host.view.bounds.height - frame.maxY, inset + 8, accuracy: 0.5, "8 pt under the glass's top edge")
        let lights = try XCTUnwrap(Self.firstSubview(of: SidebarTrafficLightsView.self, in: panel))
        let lightsMinX = lights.convert(lights.bounds, to: nil).minX
        XCTAssertEqual(frame.minX, lightsMinX + lights.trailingEdge + 10, accuracy: 0.5, "10 pt after the panel's own lights")
    }

    func testThePanelGlidesIntoItsRestingShape() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let visual = try XCTUnwrap(host.floatingSidebarContainerView?.subviews.first)
        // Sample every frame: a jump shows only the end values, a glide
        // shows values in between.
        var xs: [CGFloat] = []
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            xs.append(visual.layer?.presentation()?.frame.minX ?? .nan)
        }

        let start = -FloatingSidebarHostViewController.dockedGlassOverhang
        XCTAssertTrue(xs.contains { $0 > start + 0.5 && $0 < inset - 0.5 }, "the glass pulls in gradually: \(xs)")
        XCTAssertEqual(xs.last ?? .nan, inset, accuracy: 0.5, "and rests at its inset")
        host.finishSidebarHandOffImmediately()
    }

    func testTheGlassItsCornerAndBorderComeInGraduallyAsThePanelPullsIn() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the glass panel is macOS 26+") }
        let (split, host) = try expandedColumn()
        XCTAssertTrue(host.beginSidebarHandOff(.undock))
        host.view.layoutSubtreeIfNeeded()
        _ = split
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let glass = try XCTUnwrap(host.floatingSidebarContainerView?.subviews.first as? NSGlassEffectView)
        let content = try XCTUnwrap(glass.contentView?.layer)
        XCTAssertEqual(glass.cornerRadius, 0, "precondition: square while docked")

        let began = CACurrentMediaTime()
        host.animateSidebarHandOff()
        // Sample every frame through the glide. The corner steps on a main
        // run loop timer, which a busy run loop can hold back, so a stalled
        // run can jump from 0 to 14. It must never run ahead of the ease-out
        // curve: a snap shows 14 while the curve is still low.
        let duration = FloatingSidebarHostViewController.sidebarHandOffDuration
        func curve(at time: CFTimeInterval) -> CGFloat {
            let progress = min(1, max(0, (time - began) / duration))
            return 14 * (1 - (1 - progress) * (1 - progress))
        }
        var radii: [(time: CFTimeInterval, radius: CGFloat)] = []
        var borders: [CGFloat] = []
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            radii.append((CACurrentMediaTime(), glass.cornerRadius))
            borders.append(content.presentation()?.borderWidth ?? content.borderWidth)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }

        let values = radii.map(\.radius)
        for sample in radii {
            XCTAssertLessThanOrEqual(sample.radius, curve(at: sample.time) + 0.5,
                                     "the corner rounds no faster than the glide at \(sample.time - began) s: \(values)")
        }
        XCTAssertEqual(values, values.sorted(), "the corner only rounds up: \(values)")
        XCTAssertTrue(borders.allSatisfy { $0 < 0.01 }, "no border while the panel moves: \(borders)")
        XCTAssertEqual(glass.cornerRadius, 14, accuracy: 0.01, "and lands on the resting radius")
        host.finishSidebarHandOffImmediately()
    }

    /// The column opens or closes under the panel, so for most of the glide
    /// there is page, not column, behind it. Its glass has to stay solid.
    func testTheGlassStaysSolidThroughAnUnpin() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let opacities = try sampleGlassOpacity(in: host, for: 0.3)

        XCTAssertTrue(opacities.allSatisfy { $0 > 0.99 }, "the page never shows through: \(opacities)")
        host.finishSidebarHandOffImmediately()
    }

    func testTheGlassStaysSolidWhileThePinGlides() throws {
        let (split, host) = try visiblePanel()

        split.setSidebarCollapsed(false, animated: true)
        // The glide only: once it ends the panel fades off the open column.
        let opacities = try sampleGlassOpacity(in: host, for: Host.sidebarHandOffDuration - 1.0 / 60)

        XCTAssertFalse(opacities.isEmpty)
        XCTAssertTrue(opacities.allSatisfy { $0 > 0.99 }, "the page never shows through: \(opacities)")
        host.finishSidebarHandOffImmediately()
    }

    /// Covering the column, the panel casts no shadow or rim past its edge
    /// onto the page; they come out with the edge as it pulls in.
    func testTheShadowComesOutWithTheEdgeOnAnUnpin() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let visual = try XCTUnwrap(panel.subviews.first)
        let mask = try XCTUnwrap(panel.layer?.mask, "the panel clips its shadow while it covers the column")
        let from = try XCTUnwrap(mask.animation(forKey: "sidebarHandOff.position") as? CABasicAnimation)
        let fromBounds = try XCTUnwrap(mask.animation(forKey: "sidebarHandOff.bounds") as? CABasicAnimation)
        let startEdge = ((from.fromValue as? NSValue)?.pointValue.x ?? .nan)
            + ((fromBounds.fromValue as? NSValue)?.rectValue.width ?? .nan) / 2
        XCTAssertEqual(startEdge, panel.bounds.width - inset,
                       accuracy: 0.5, "starts clipped at the docked panel's edge")
        XCTAssertEqual(Self.firstControlPoint(of: fromBounds).x, 0.42, accuracy: 0.01,
                       "it opens slowly, so the shadow comes out as the panel leaves, not on the click (ease-in)")
        // Read the opening from its animation rather than sampling frames: at
        // the toggle's speed a busy run loop can skip the whole glide.
        XCTAssertEqual(fromBounds.duration, FloatingSidebarHostViewController.sidebarHandOffDuration,
                       accuracy: 0.001, "the clip opens over the whole glide")
        let endEdge = mask.frame.maxX - visual.frame.maxX
        XCTAssertEqual(endEdge, FloatingSidebarHostViewController.panelShadowReach, accuracy: 0.5,
                       "it ends past the resting panel's shadow")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(panel.layer?.mask, "at rest nothing clips the shadow")
    }

    func testThePinTucksTheShadowInWithTheEdge() throws {
        let (split, host) = try visiblePanel()
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        XCTAssertNil(panel.layer?.mask, "precondition: at rest nothing clips the shadow")

        split.setSidebarCollapsed(false, animated: true)
        let visual = try XCTUnwrap(panel.subviews.first)
        let mask = try XCTUnwrap(panel.layer?.mask)
        let closing = try XCTUnwrap(mask.animation(forKey: "sidebarHandOff.bounds"))
        XCTAssertLessThanOrEqual(closing.duration, 0.6 * FloatingSidebarHostViewController.sidebarHandOffDuration + 0.001,
                                 "the clip closes over the rim before the panel slows into place")
        // Read the glide from its animations rather than sampling frames: a
        // busy run loop can skip the whole 0.15 s close between two samples.
        let moving = try XCTUnwrap(mask.animation(forKey: "sidebarHandOff.position") as? CABasicAnimation)
        let sizing = try XCTUnwrap(closing as? CABasicAnimation)
        let startCenter = try XCTUnwrap(moving.fromValue as? NSValue).pointValue
        let startSize = try XCTUnwrap(sizing.fromValue as? NSValue).rectValue.size
        let startEdge = startCenter.x + startSize.width * (1 - mask.anchorPoint.x)

        XCTAssertEqual(mask.frame.maxX, visual.frame.maxX,
                       accuracy: 0.5, "ends clipped at the panel's edge, where the column's begins")
        XCTAssertGreaterThan(startEdge - mask.frame.maxX, 1, "the clip starts out past its end and closes in")
        XCTAssertEqual(moving.duration, sizing.duration, accuracy: 0.001, "edge and size close together")
        host.finishSidebarHandOffImmediately()
    }

    func testUnpinningShowsTheTabListWhereTheColumnWasScrolled() throws {
        let (split, host) = try expandedColumn(extraTabs: 30)
        let window = try XCTUnwrap(split.view.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 420), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let mainSplit = try XCTUnwrap(host.browserState?.windowController?.mainSplitViewController)
        mainSplit.sidebarTabListScrollOffset = NSPoint(x: 0, y: 200)
        let scrolled = mainSplit.sidebarTabListScrollOffset
        XCTAssertGreaterThan(scrolled.y, 50, "precondition: the column's list scrolls")

        XCTAssertTrue(host.beginSidebarHandOff(.undock))
        host.view.layoutSubtreeIfNeeded()

        let panelOffset = try XCTUnwrap(host.floatingSidebarViewController?.tabListScrollOffset)
        XCTAssertEqual(panelOffset.y, scrolled.y, accuracy: 0.5, "the panel shows the rows the column showed")
        host.finishSidebarHandOffImmediately()
    }

    func testPinningLeavesTheColumnWhereThePanelWasScrolled() throws {
        let (split, host) = try visiblePanel(extraTabs: 30)
        let window = try XCTUnwrap(split.view.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 420), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panel = try XCTUnwrap(host.floatingSidebarViewController)
        panel.tabListScrollOffset = NSPoint(x: 0, y: 200)
        let scrolled = panel.tabListScrollOffset
        XCTAssertGreaterThan(scrolled.y, 50, "precondition: the panel's list scrolls")

        XCTAssertTrue(host.beginSidebarHandOff(.dock))

        let mainSplit = try XCTUnwrap(host.browserState?.windowController?.mainSplitViewController)
        XCTAssertEqual(mainSplit.sidebarTabListScrollOffset.y, scrolled.y, accuracy: 0.5,
                       "the column the panel fades off shows the same rows")
        host.finishSidebarHandOffImmediately()
    }

    // MARK: - Shell routing

    func testTouchTapOnHiddenNotchBandRevealsOnlyTheNativeDragHandle() throws {
        let key = PhiPreferences.GeneralSettings.edgeToEdgeWebContent.rawValue
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let (split, host) = try expandedColumn()
        let shell = try XCTUnwrap(host.browserState?.windowController)
        let content = shell.mainSplitViewController.webContentContainerViewController
        let band = try XCTUnwrap(content.view.subviews.compactMap { $0 as? WindowDragNotchView }.first)
        let window = try XCTUnwrap(split.view.window)
        let frame = try XCTUnwrap(window.contentView?.superview)
        split.view.layoutSubtreeIfNeeded()
        let tap = band.convert(NSPoint(x: 20, y: band.bounds.midY), to: nil)
        let center = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.midY), to: nil)
        let page = band.convert(NSPoint(x: 20, y: band.bounds.minY - 2), to: nil)
        band.supportsTouch = { _ in false }
        XCTAssertFalse(frame.hitTest(tap) === band, "the hidden band passes through on a pointer-only display")
        band.supportsTouch = { _ in true }
        XCTAssertTrue(frame.hitTest(tap) === band, "a touch away from the centered handle reaches the recognizer")
        XCTAssertFalse(frame.hitTest(page) === band)
        let recognizer = try XCTUnwrap(band.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        XCTAssertEqual(recognizer.allowedTouchTypes, .direct)
        XCTAssertEqual(recognizer.buttonMask, 0)

        band.revealForTouchTap(at: page)
        XCTAssertTrue(frame.hitTest(center) === band, "a tap below the band does not reveal it")
        band.revealForTouchTap(at: tap)
        band.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: tap,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(frame.hitTest(center) === frame, "the revealed handle uses native window gestures")
        XCTAssertFalse(frame.hitTest(tap) === band, "touches beside the visible handle reach the page")
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(frame.hitTest(tap) === band, "the band accepts a new reveal after the timeout")
    }

    func testEdgeToEdgeWindowDragNotchOnlyTakesHitsWhileTheTopEdgeIsHovered() throws {
        let key = PhiPreferences.GeneralSettings.edgeToEdgeWebContent.rawValue
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)

        let (split, host) = try expandedColumn()
        let window = try XCTUnwrap(split.view.window)
        let state = try XCTUnwrap(host.browserState)
        state.themeContext.setTheme(.mint)
        let content = try XCTUnwrap(state.windowController).mainSplitViewController.webContentContainerViewController
        let band = try XCTUnwrap(content.view.subviews.first { $0 is TitlebarAwareHitTestable })
        let frameView = try XCTUnwrap(window.contentView?.superview)

        func trackingEvent(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }

        func settleLayout() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            split.view.layoutSubtreeIfNeeded()
        }

        func waitForReveal(_ notch: CALayer) {
            let deadline = Date().addingTimeInterval(1)
            while notch.opacity == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        settleLayout()
        XCTAssertFalse(split.isSidebarCollapsed)
        XCTAssertGreaterThan(band.bounds.height, 0, "the page has its own hover target beside the docked sidebar")

        let center = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.maxY - 10), to: nil)
        let side = band.convert(NSPoint(x: band.bounds.width * 0.25, y: band.bounds.maxY - 10), to: nil)
        let notch = try XCTUnwrap(band.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let outline = try XCTUnwrap(notch.path)
        for x in [outline.boundingBoxOfPath.minX + 3, outline.boundingBoxOfPath.maxX - 3] {
            XCTAssertTrue(outline.contains(CGPoint(x: x, y: band.bounds.maxY - 0.5)))
            XCTAssertFalse(outline.contains(CGPoint(x: x, y: band.bounds.maxY - 3)))
        }
        let fill = try XCTUnwrap(notch.fillColor)
        XCTAssertGreaterThan(fill.alpha, 0)
        XCTAssertLessThan(fill.alpha, 1)
        XCTAssertFalse(frameView.hitTest(center) === frameView, "a hidden notch leaves the page clickable")
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: side))
        XCTAssertFalse(frameView.hitTest(center) === frameView, "the page receives clicks during the hover delay")
        band.mouseExited(with: try trackingEvent(.mouseExited, at: side))
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(notch.opacity, 0, "a quick pass cancels the pending reveal")
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: side))
        waitForReveal(notch)
        XCTAssertEqual(notch.opacity, 1)
        XCTAssertEqual(notch.affineTransform().ty, 0)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNil(notch.animation(forKey: "opacity"), "the notch shows at full opacity")
            XCTAssertNotNil(notch.animation(forKey: "transform"), "the notch slides down")
        }
        XCTAssertTrue(frameView.hitTest(center) === frameView, "the notch routes to the native titlebar")
        XCTAssertFalse(frameView.hitTest(side) === frameView, "the rest of the hover band routes to the page")

        state.themeContext.setTheme(.iris)
        settleLayout()
        XCTAssertNotEqual(try XCTUnwrap(notch.fillColor), fill, "an open notch follows the Space theme")
        let crop = NSRect(x: band.bounds.midX - 70, y: 0, width: 140, height: band.bounds.height)
        let bitmap = try XCTUnwrap(band.bitmapImageRepForCachingDisplay(in: crop))
        band.cacheDisplay(in: crop, to: bitmap)
        let preview = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                    uniformTypeIdentifier: "public.png")
        preview.name = "Window drag notch"
        preview.lifetime = .keepAlways
        add(preview)

        band.mouseExited(with: try trackingEvent(.mouseExited, at: center))
        XCTAssertEqual(notch.opacity, 1, "overshooting the edge keeps the notch available")
        XCTAssertFalse(frameView.hitTest(side) === frameView)
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: center))
        XCTAssertTrue(frameView.hitTest(center) === frameView, "returning needs no second hover delay")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(notch.opacity, 1, "returning cancels the scheduled hide")
        band.mouseExited(with: try trackingEvent(.mouseExited, at: center))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(notch.opacity, 0)
        XCTAssertGreaterThanOrEqual(notch.affineTransform().ty, outline.boundingBoxOfPath.height,
                                    "the hidden notch sits above the band, out of view")
        XCTAssertFalse(frameView.hitTest(center) === frameView)

        split.setSidebarCollapsed(true, animated: false)
        settleLayout()
        host.prefersReducedMotion = { true }
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible)
        settleLayout()
        let floatingCenter = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.maxY - 10), to: nil)
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: floatingCenter))
        waitForReveal(notch)
        XCTAssertTrue(frameView.hitTest(floatingCenter) === frameView, "the exposed notch works beside the floating sidebar")

        host.hideFloatingSidebar(animated: false)
        window.setContentSize(NSSize(width: 640, height: 420))
        settleLayout()
        let smallWindowCenter = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.maxY - 10), to: nil)
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: smallWindowCenter))
        waitForReveal(notch)
        XCTAssertTrue(frameView.hitTest(smallWindowCenter) === frameView)

        // A titlebar zoom can move the hover band without a mouse-exit event.
        let smallSize = window.frame.size
        window.performZoom(nil)
        settleLayout()
        XCTAssertGreaterThan(window.frame.width * window.frame.height, smallSize.width * smallSize.height)
        XCTAssertEqual(notch.opacity, 0, "zooming dismisses the old hover immediately")
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(notch.opacity, 0, "the old hover does not reopen the notch")

        let zoomedCenter = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.maxY - 10), to: nil)
        band.mouseEntered(with: try trackingEvent(.mouseEntered, at: zoomedCenter))
        waitForReveal(notch)
        XCTAssertTrue(frameView.hitTest(zoomedCenter) === frameView)

        state.isInFullScreenMode = true
        settleLayout()
        XCTAssertEqual(band.frame.height, 0)
    }

    func testReduceMotionCompletesHandOffImmediately() throws {
        let (split, host) = try expandedColumn()
        host.prefersReducedMotion = { true }
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }
        let closeButton = try XCTUnwrap(split.view.window?.standardWindowButton(.closeButton))
        host.browserState?.windowController?.refreshTrafficLightVisibility()
        XCTAssertFalse(closeButton.isHidden)

        var completions: [Bool] = []
        split.setSidebarCollapsed(true, animated: true) { completions.append($0) }
        XCTAssertTrue(split.isSidebarCollapsed)
        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
        XCTAssertTrue(closeButton.isHidden)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let content = try XCTUnwrap(Self.contentLayer(in: panel))
        XCTAssertNil(content.animation(forKey: "borderIn"))

        split.setSidebarCollapsed(false, animated: true) { completions.append($0) }
        XCTAssertTrue(split.sidebarTakesPageSpace)
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
        XCTAssertFalse(closeButton.isHidden)
        XCTAssertEqual(completions, [true, true])
    }

    func testPinningWhileThePanelIsOpenHandsOff() throws {
        let (split, host) = try visiblePanel()
        let panelWidth = host.currentFloatingWidth

        split.setSidebarCollapsed(false, animated: true)

        XCTAssertTrue(host.isVisible, "the panel stays while the column opens under it")
        XCTAssertTrue(host.isSidebarHandOffRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(split.isSidebarCollapsed)
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
        XCTAssertEqual(split.sidebarWidth, panelWidth, accuracy: 0.5, "the column docks at the panel's width")
    }

    /// The column's slide and the panel's glide are added in one turn, with
    /// one duration and one curve, so they start on the same commit and move
    /// as one.
    func testTheColumnSlidesWithThePanelsGlide() throws {
        let (split, host) = try visiblePanel()
        let visual = try XCTUnwrap(host.floatingSidebarContainerView?.subviews.first)

        split.setSidebarCollapsed(false, animated: true)

        let slide = try XCTUnwrap(split.sidebarHost.view.layer?
            .animation(forKey: ShellSplitView.slideAnimationKey) as? CABasicAnimation, "the column slides in")
        let glide = try XCTUnwrap(visual.layer?.animation(forKey: "sidebarHandOff.position") as? CABasicAnimation,
                                  "the panel glides")
        XCTAssertEqual(slide.duration, Host.sidebarHandOffDuration, accuracy: 0.001)
        XCTAssertEqual(slide.duration, glide.duration, accuracy: 0.001)
        XCTAssertEqual(slide.timingFunction, glide.timingFunction)
        XCTAssertEqual(slide.beginTime, glide.beginTime, "both start with the commit")
        XCTAssertEqual((slide.toValue as? NSNumber)?.doubleValue, 0, "the column ends at its place")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(split.sidebarHost.view.layer?.animation(forKey: ShellSplitView.slideAnimationKey))
        XCTAssertFalse(split.isSidebarCollapsed)
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testUnpinWithThePointerOnTheSidebarLeavesThePanelUp() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }

        split.setSidebarCollapsed(true, animated: true)

        XCTAssertTrue(host.isVisible, "the sidebar turns into the panel in place")
        XCTAssertTrue(host.isSidebarHandOffRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(split.isSidebarCollapsed)
        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testUnpinWithTheSidebarButtonCollapsesAsToday() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.sidebarHost.view) }
        split.currentEventType = { .leftMouseUp }

        split.setSidebarCollapsed(true, animated: true)

        XCTAssertFalse(host.isVisible, "a click puts the sidebar away")
        XCTAssertFalse(host.isSidebarHandOffRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(split.isSidebarCollapsed)
        XCTAssertFalse(host.isVisible, "no panel flash")
    }

    func testUnpinWithThePointerOverThePageCollapsesAsToday() throws {
        let (split, host) = try expandedColumn()
        split.pointerLocationInWindow = { [unowned split] in Self.middle(of: split.contentHost.view) }

        split.setSidebarCollapsed(true, animated: true)

        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(split.isSidebarCollapsed)
        XCTAssertFalse(host.isVisible, "no panel flash")
    }

    func testComfortableLayoutNeverHandsOff() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.pointerLocationInWindow = { NSPoint(x: 20, y: 300) }

        split.setSidebarCollapsed(false, animated: true)
        split.setSidebarCollapsed(true, animated: true)

        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testNonAnimatedChangesNeverHandOff() throws {
        let (split, host) = try visiblePanel()

        split.setSidebarCollapsed(false, animated: false)

        XCTAssertFalse(split.isSidebarCollapsed)
        XCTAssertFalse(host.isVisible, "today's path: the panel goes at once")
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testPinningDocksAtThePanelsWidthAfterAnInterruptedToggle() throws {
        let (split, host) = try visiblePanel()
        let panelWidth = host.currentFloatingWidth
        // A toggle that cuts AppKit's column animation short leaves the
        // collapsed column at its in-flight width.
        split.sidebarHost.view.setFrameSize(NSSize(width: 198, height: split.sidebarHost.view.frame.height))

        split.setSidebarCollapsed(false, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(split.sidebarWidth, panelWidth, accuracy: 0.5, "the column docks where the panel is")
        XCTAssertEqual(host.currentFloatingWidth, panelWidth, accuracy: 0.5, "the remembered width stays")
    }

    // MARK: - Interruptions

    func testTogglingAgainDuringAHandOffEndsInTheNewState() throws {
        let (split, host) = try visiblePanel()
        split.pointerLocationInWindow = { NSPoint(x: 20, y: 350) }

        split.setSidebarCollapsed(false, animated: true)
        split.setSidebarCollapsed(true, animated: true)

        XCTAssertTrue(host.isSidebarHandOffRunning, "the second toggle hands back to the panel")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(split.isSidebarCollapsed)
        XCTAssertTrue(host.isVisible, "the pointer is on it")
        XCTAssertFalse(host.isSidebarHandOffRunning)
    }

    func testASpaceSwitchFinishesTheHandOff() throws {
        let (split, host) = try visiblePanel()
        split.setSidebarCollapsed(false, animated: true)
        XCTAssertTrue(host.isSidebarHandOffRunning, "precondition: the dock runs")

        host.beginSpaceSwitch()

        XCTAssertFalse(host.isSidebarHandOffRunning)
        XCTAssertFalse(host.isVisible)
        host.finishSpaceSwitch()
    }

    // MARK: - Harness

    private func assertPanelHeaderLinesUpWithTheColumn(in mode: LayoutMode,
                                                       file: StaticString = #filePath,
                                                       line: UInt = #line) throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
        let (split, host) = try expandedColumn(file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let columnButton = try XCTUnwrap(Self.view(identified: "sidebarHeader.sidebarButton", in: split.sidebarHost.view),
                                         file: file, line: line)
        let columnHeader = try XCTUnwrap(Self.header(of: columnButton), file: file, line: line)

        XCTAssertTrue(host.beginSidebarHandOff(.undock), file: file, line: line)
        host.view.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        let panelButton = try XCTUnwrap(Self.view(identified: "sidebarHeader.sidebarButton", in: panel), file: file, line: line)
        let panelHeader = try XCTUnwrap(Self.header(of: panelButton), file: file, line: line)
        let expected = columnButton.convert(columnButton.bounds, to: nil)
        let actual = panelButton.convert(panelButton.bounds, to: nil)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "sidebar button x", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "sidebar button y", file: file, line: line)
        XCTAssertEqual(panelHeader.frame.height, columnHeader.frame.height, accuracy: 0.5, "header height", file: file, line: line)
        host.finishSidebarHandOffImmediately()
    }

    /// The visible view with `identifier` under `root`.
    private static func view(identified identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier, !root.isHiddenOrHasHiddenAncestor { return root }
        for child in root.subviews {
            if let found = view(identified: identifier, in: child) { return found }
        }
        return nil
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let found = firstSubview(of: type, in: child) { return found }
        }
        return nil
    }

    private static func header(of view: NSView) -> SidebarHeaderView? {
        var current = view.superview
        while let candidate = current {
            if let header = candidate as? SidebarHeaderView { return header }
            current = candidate.superview
        }
        return nil
    }

    /// How opaque the panel's sidebar button draws on each frame for
    /// `duration`: the product of its own and its ancestors' on-screen
    /// opacity, up to the panel.
    private func sampleContentOpacity(in host: FloatingSidebarHostViewController,
                                      for duration: TimeInterval,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws -> [Float] {
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        let button = try XCTUnwrap(Self.view(identified: "sidebarHeader.sidebarButton", in: panel), file: file, line: line)
        var chain: [NSView] = []
        var current: NSView? = button
        while let view = current, view !== panel {
            chain.append(view)
            current = view.superview
        }
        var opacities: [Float] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            opacities.append(chain.reduce(Float(1)) { product, view in
                guard let layer = view.layer else { return product * Float(view.alphaValue) }
                return product * (layer.presentation()?.opacity ?? layer.opacity)
            })
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }
        return opacities
    }

    /// How opaque the panel's glass draws on each frame for `duration`: the
    /// least opaque of the glass and its own subviews, times the panel's.
    private func sampleGlassOpacity(in host: FloatingSidebarHostViewController,
                                    for duration: TimeInterval,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> [Float] {
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        let visual = try XCTUnwrap(panel.subviews.first, file: file, line: line)
        func shown(_ view: NSView) -> Float {
            guard let layer = view.layer else { return Float(view.alphaValue) }
            return layer.presentation()?.opacity ?? layer.opacity
        }
        var opacities: [Float] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            let parts = ([visual] + visual.subviews).map(shown)
            opacities.append(shown(panel) * (parts.min() ?? 1))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }
        return opacities
    }

    /// The presented Space's rows in the panel, in the host's coordinates.
    private func rowsFrame(in host: FloatingSidebarHostViewController,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> NSRect {
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        let content = try XCTUnwrap(Self.contentLayer(in: panel)?.delegate as? NSView, file: file, line: line)
        // The column material sheet sits under the rows.
        let rows = try XCTUnwrap(content.subviews.first { !$0.isHidden && !($0 is NSVisualEffectView) },
                                 file: file, line: line)
        return rows.convert(rows.bounds, to: host.view)
    }

    /// The panel's content layer: the one that draws its border.
    private static func contentLayer(in panel: NSView) -> CALayer? {
        guard let visual = panel.subviews.first else { return nil }
        if #available(macOS 26.0, *), let glass = visual as? NSGlassEffectView {
            return glass.contentView?.layer
        }
        return visual.layer
    }

    private static func firstControlPoint(of animation: CABasicAnimation) -> CGPoint {
        var point: [Float] = [0, 0]
        animation.timingFunction?.getControlPoint(at: 1, values: &point)
        return CGPoint(x: CGFloat(point[0]), y: CGFloat(point[1]))
    }

    /// The middle of `view`, in its window's coordinates.
    private static func middle(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// The column collapsed and its floating panel shown.
    private func visiblePanel(extraTabs: Int = 0,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> (ShellSplitViewController, FloatingSidebarHostViewController) {
        let slot = try makeSlot(extraTabs: extraTabs)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        // Open the column once, as a user has, so the panel knows its width.
        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible, "precondition: the panel is shown", file: file, line: line)
        split.view.layoutSubtreeIfNeeded()
        return (split, host)
    }

    /// The column expanded and the floating panel hidden.
    private func expandedColumn(extraTabs: Int = 0,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> (ShellSplitViewController, FloatingSidebarHostViewController) {
        let slot = try makeSlot(extraTabs: extraTabs)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(split.isSidebarCollapsed, "precondition: the column is open", file: file, line: line)
        XCTAssertFalse(split.floatingSidebarHost.isVisible, "precondition: the panel is hidden", file: file, line: line)
        return (split, split.floatingSidebarHost)
    }

    /// The panel's visible glass, in the host's coordinates.
    private func visualFrame(in host: FloatingSidebarHostViewController,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> NSRect {
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        let visual = try XCTUnwrap(panel.subviews.first, file: file, line: line)
        return visual.convert(visual.bounds, to: host.view)
    }

    private func makeSlot(extraTabs: Int = 0) throws -> SpaceWindowSlot {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        // Toggles in these tests come from the shortcut unless a test says
        // otherwise.
        slot.shell?.split.currentEventType = { .keyDown }
        slot.shell?.split.floatingSidebarHost.prefersReducedMotion = { false }
        nextWindowId += 1
        let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first", isIncognito: false)
        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        webViews.append(webView)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://first.example/")
        wrapper.nativeView = webView
        let tab = Tab(guid: nextWindowId, url: wrapper.urlString, isActive: true,
            index: 0, webContentView: wrapper)
        state.tabs = [tab] + (0..<extraTabs).map { index in
            let extra = PageColorTestWebContentWrapper(urlString: "https://extra\(index).example/")
            return Tab(guid: nextWindowId * 100 + index, url: extra.urlString, isActive: false,
                       index: index + 1, webContentView: extra)
        }
        state.updateNormalTabs()
        state.focusingTab = tab
        let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: "first", account: store.account,
            slot: slot, browserState: state, dormant: true)
        slot.registerWindow(session, for: "first")
        XCTAssertTrue(session.isPresented, "precondition: the Space is presented")
        slot.shell?.window.orderFront(nil)
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(webView.window, "precondition: the page is mounted")
        return slot
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// These Browsers have their tab already, and must never seed one.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}

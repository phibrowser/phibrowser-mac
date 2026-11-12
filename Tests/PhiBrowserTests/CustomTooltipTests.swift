// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class CustomTooltipTests: XCTestCase {
    private struct TooltipThemeSnapshot: Equatable {
        let themeID: String
        let appearance: Appearance
        let colorScheme: ColorScheme
    }

    private final class TooltipThemeProbe {
        private(set) var snapshots: [TooltipThemeSnapshot] = []

        var latestSnapshot: TooltipThemeSnapshot? {
            snapshots.last
        }

        func record(_ snapshot: TooltipThemeSnapshot) {
            guard snapshots.last != snapshot else { return }
            snapshots.append(snapshot)
        }
    }

    private struct TooltipThemeProbeView: View {
        @Environment(\.phiTheme) private var theme
        @Environment(\.phiAppearance) private var appearance
        @Environment(\.colorScheme) private var colorScheme

        let probe: TooltipThemeProbe

        var body: some View {
            Text("Themed")
                .onAppear(perform: recordSnapshot)
                .onChange(of: theme.id) { _, _ in
                    recordSnapshot()
                }
                .onChange(of: appearance) { _, _ in
                    recordSnapshot()
                }
                .onChange(of: colorScheme) { _, _ in
                    recordSnapshot()
                }
        }

        private func recordSnapshot() {
            probe.record(
                TooltipThemeSnapshot(
                    themeID: theme.id,
                    appearance: appearance,
                    colorScheme: colorScheme
                )
            )
        }
    }

    private struct VisualCustomTooltipContent: View {
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom tooltip from B")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Warm handoff · no second delay")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45))
            }
            .fixedSize()
        }
    }

    private final class VisualFixtureSurfaceView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: dirtyRect).fill()

            let title = "Window-scoped custom tooltip"
            let subtitle = "Move directly from A to B to reuse the visible surface."
            (title as NSString).draw(
                at: NSPoint(x: 24, y: bounds.maxY - 38),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            (subtitle as NSString).draw(
                at: NSPoint(x: 24, y: bounds.maxY - 60),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
    }

    private final class VisualFixtureHostView: NSView {
        let title: String
        let subtitle: String
        var isActive = false {
            didSet {
                needsDisplay = true
            }
        }

        init(frame frameRect: NSRect, title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 9,
                yRadius: 9
            )
            let fillColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.controlBackgroundColor
            fillColor.setFill()
            path.fill()
            (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isActive ? 2 : 1
            path.stroke()

            (title as NSString).draw(
                at: NSPoint(x: 12, y: bounds.maxY - 25),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            (subtitle as NSString).draw(
                at: NSPoint(x: 12, y: 10),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
    }

    @MainActor
    private final class ManualScheduler {
        private final class ScheduledAction {
            let delay: TimeInterval
            let action: @MainActor () -> Void
            var isCancelled = false

            init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
                self.delay = delay
                self.action = action
            }
        }

        private var actions: [ScheduledAction] = []

        var pendingDelays: [TimeInterval] {
            actions.filter { !$0.isCancelled }.map(\.delay)
        }

        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> AnyCancellable {
            let scheduledAction = ScheduledAction(delay: delay, action: action)
            actions.append(scheduledAction)
            return AnyCancellable {
                MainActor.assumeIsolated {
                    scheduledAction.isCancelled = true
                }
            }
        }

        func fireNext() {
            while !actions.isEmpty {
                let scheduledAction = actions.removeFirst()
                guard !scheduledAction.isCancelled else { continue }
                scheduledAction.action()
                return
            }
        }
    }

    private final class RecordingPresenter: CustomTooltipPresenting {
        private let panelToken = NSObject()
        private let hostingViewToken = NSObject()

        private(set) var isVisible = false
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var lastThemeProvider: ThemeStateProvider?
        private(set) var lastPlacement: CustomTooltipPlacement?
        private(set) var lastAnchorScreenRect: CGRect?
        private(set) var frameAnimationDurations: [TimeInterval] = []

        var surfaceIdentifiers: (panel: ObjectIdentifier, hostingView: ObjectIdentifier)? {
            (ObjectIdentifier(panelToken), ObjectIdentifier(hostingViewToken))
        }

        func present(
            content: AnyView,
            anchorScreenRect: CGRect,
            screen: NSScreen?,
            themeProvider: ThemeStateProvider,
            placement: CustomTooltipPlacement,
            frameAnimationDuration: TimeInterval
        ) {
            isVisible = true
            presentCount += 1
            lastThemeProvider = themeProvider
            lastPlacement = placement
            lastAnchorScreenRect = anchorScreenRect
            frameAnimationDurations.append(frameAnimationDuration)
        }

        func dismiss() {
            isVisible = false
            dismissCount += 1
        }
    }

    func testWindowReusesOneControllerAndIsolatesOtherWindows() {
        let firstWindow = makeWindow().window
        let secondWindow = makeWindow().window

        XCTAssertTrue(firstWindow.customTooltipController === firstWindow.customTooltipController)
        XCTAssertFalse(firstWindow.customTooltipController === secondWindow.customTooltipController)
    }

    func testDifferentViewsReuseRealPanelAndHostingView() throws {
        let fixture = makeWindow()
        let secondHost = NSView(frame: CGRect(x: 220, y: 40, width: 120, height: 32))
        fixture.window.contentView?.addSubview(secondHost)
        let scheduler = ManualScheduler()
        var currentMouseLocation = fixture.mouseLocation
        let controller = CustomTooltipController(
            window: fixture.window,
            scheduler: scheduler.schedule,
            mouseLocation: { currentMouseLocation },
            isEligibleForPresentation: { _ in true }
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        controller.pointerExited(ownerID: firstOwnerID)

        let secondRectInWindow = secondHost.convert(secondHost.bounds, to: nil)
        let secondScreenRect = fixture.window.convertToScreen(secondRectInWindow)
        currentMouseLocation = CGPoint(x: secondScreenRect.midX, y: secondScreenRect.midY)
        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: secondHost,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)

        XCTAssertTrue(fixture.host !== secondHost)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
        controller.dismissAll()
    }

    func testReusedPanelAdaptsToContentHeight() throws {
        let fixture = makeWindow()
        let controller = CustomTooltipController(
            window: fixture.window,
            mouseLocation: { fixture.mouseLocation },
            isEligibleForPresentation: { _ in true }
        )
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffGroup: .tabPreview
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Color.clear.frame(width: 280, height: 240)),
            configuration: configuration
        )
        let panel = try XCTUnwrap(
            fixture.window.childWindows?.compactMap { $0 as? NSPanel }.first
        )
        let surface = try XCTUnwrap(controller.surfaceIdentifiers)
        let tallHeight = panel.frame.height

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Color.clear.frame(width: 280, height: 60)),
            configuration: configuration
        )

        XCTAssertEqual(controller.surfaceIdentifiers?.panel, surface.panel)
        XCTAssertEqual(controller.surfaceIdentifiers?.hostingView, surface.hostingView)
        XCTAssertLessThan(panel.frame.height, tallHeight)
        XCTAssertEqual(panel.frame.height, 60, accuracy: 1)
        controller.dismissAll()
    }

    func testInitialHoverUsesConfiguredDelay() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Delayed")),
            configuration: CustomTooltipConfiguration(showDelay: 0.75, displayDuration: nil)
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(controller.pendingOwnerID, ownerID)
        XCTAssertEqual(scheduler.pendingDelays, [0.75])

        scheduler.fireNext()

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, ownerID)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testGeometryRectCanDifferFromHoverHostBounds() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let geometryBounds = CGRect(x: 90, y: 4, width: 20, height: 24)
        let expectedRect = fixture.window.convertToScreen(
            fixture.host.convert(geometryBounds, to: nil)
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Inset geometry")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil),
            anchorRectProvider: { _ in geometryBounds }
        )

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(presenter.lastAnchorScreenRect, expectedRect)
    }

    func testPointerExitCancelsPendingPresentation() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Cancelled")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )
        controller.pointerExited(ownerID: ownerID)
        scheduler.fireNext()

        XCTAssertNil(controller.pendingOwnerID)
        XCTAssertNil(controller.activeOwnerID)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(presenter.presentCount, 0)
    }

    func testDismissAllCancelsPendingAndHidesVisibleTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(presenter.isVisible)

        controller.dismissAll()

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Pending")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )
        XCTAssertNotNil(controller.pendingOwnerID)

        controller.dismissAll()
        scheduler.fireNext()

        XCTAssertNil(controller.pendingOwnerID)
        XCTAssertNil(controller.activeOwnerID)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testPointerWatchdogHidesTooltipWhenExitEventIsMissed() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        var mouseLocation = fixture.mouseLocation
        let controller = CustomTooltipController(
            window: fixture.window,
            presenter: presenter,
            scheduler: scheduler.schedule,
            mouseLocation: { mouseLocation },
            isEligibleForPresentation: { _ in true }
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Watchdog")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(presenter.isVisible)

        mouseLocation = .zero
        let watchdogFired = expectation(description: "Pointer watchdog fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            watchdogFired.fulfill()
        }
        wait(for: [watchdogFired], timeout: 1)

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testWarmHandoffShowsNextViewImmediatelyAndReusesSurface() throws {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        controller.pointerExited(ownerID: firstOwnerID)

        XCTAssertFalse(presenter.isVisible, "Leaving the hosting view must hide synchronously.")

        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
    }

    func testSeamlessHandoffKeepsSurfaceVisibleUntilNextOwnerEnters() throws {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffDelay: 0.15
        )

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: configuration
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        controller.pointerExited(ownerID: firstOwnerID)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, firstOwnerID)
        XCTAssertEqual(scheduler.pendingDelays, [0.15])
        XCTAssertEqual(presenter.dismissCount, 0)

        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: configuration
        )
        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(presenter.dismissCount, 0)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
        XCTAssertEqual(presenter.frameAnimationDurations, [0, 0])

        scheduler.fireNext()
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
    }

    func testSeamlessHandoffAnimatesFrameOnlyForNextOwnerInSameGroup() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffDelay: 0.15,
            handoffGroup: .tabPreview,
            handoffFrameAnimationDuration: 0.18
        )
        let firstOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: configuration
        )
        controller.update(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Updated")),
            configuration: configuration
        )
        controller.pointerExited(ownerID: firstOwnerID)
        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: configuration
        )

        XCTAssertEqual(presenter.frameAnimationDurations, [0, 0, 0.18])
        XCTAssertEqual(presenter.dismissCount, 0)
    }

    func testCrossGroupHandoffDoesNotAnimateFrame() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Standard")),
            configuration: CustomTooltipConfiguration(
                showDelay: 0,
                displayDuration: nil,
                handoffGroup: .standard,
                handoffFrameAnimationDuration: 0.18
            )
        )
        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Preview")),
            configuration: CustomTooltipConfiguration(
                showDelay: 0,
                displayDuration: nil,
                handoffGroup: .tabPreview,
                handoffFrameAnimationDuration: 0.18
            )
        )

        XCTAssertEqual(presenter.frameAnimationDurations, [0, 0])
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testSeamlessHandoffDismissesAfterDelayWithoutNewOwner() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Preview")),
            configuration: CustomTooltipConfiguration(
                showDelay: 0,
                displayDuration: nil,
                handoffDelay: 0.15
            )
        )
        controller.pointerExited(ownerID: ownerID)

        XCTAssertTrue(presenter.isVisible)
        scheduler.fireNext()
        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testInvalidNextOwnerDoesNotCancelSeamlessDismissal() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffDelay: 0.15
        )
        let firstOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: configuration
        )
        controller.pointerExited(ownerID: firstOwnerID)
        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: NSView(frame: fixture.host.bounds),
            content: AnyView(Text("Detached")),
            configuration: configuration
        )

        XCTAssertEqual(controller.activeOwnerID, firstOwnerID)
        XCTAssertEqual(scheduler.pendingDelays, [0.15])
        scheduler.fireNext()
        XCTAssertFalse(presenter.isVisible)
    }

    func testStaleUpdateDoesNotCancelSeamlessDismissal() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffDelay: 0.15
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Preview")),
            configuration: configuration
        )
        controller.pointerExited(ownerID: ownerID)
        controller.update(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Stale")),
            configuration: configuration
        )

        XCTAssertEqual(scheduler.pendingDelays, [0.15])
        scheduler.fireNext()
        XCTAssertFalse(presenter.isVisible)
    }

    func testWarmStateDoesNotCrossHandoffGroups() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Standard")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        controller.pointerExited(ownerID: firstOwnerID)
        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Preview")),
            configuration: CustomTooltipConfiguration(
                showDelay: 0.5,
                displayDuration: nil,
                handoffGroup: .tabPreview
            )
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(scheduler.pendingDelays, [0.5])
    }

    func testExpiredSeamlessHandoffReturnsToColdDelay() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let configuration = CustomTooltipConfiguration(
            showDelay: 0,
            displayDuration: nil,
            handoffDelay: 0.15,
            handoffGroup: .tabPreview
        )

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: configuration
        )
        controller.pointerExited(ownerID: firstOwnerID)
        scheduler.fireNext()
        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(
                showDelay: 0.5,
                displayDuration: nil,
                handoffDelay: 0.15,
                handoffGroup: .tabPreview
            )
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(scheduler.pendingDelays, [0.5])
    }

    func testPreparationRunsOnlyWhenDelayedPresentationFires() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        var preparationCount = 0

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Deferred")),
            configuration: CustomTooltipConfiguration(showDelay: 0.5, displayDuration: nil),
            prepareForPresentation: {
                preparationCount += 1
                return true
            }
        )

        XCTAssertEqual(preparationCount, 0)
        scheduler.fireNext()
        XCTAssertEqual(preparationCount, 1)
        XCTAssertTrue(presenter.isVisible)
    }

    func testCancelledDelayedPresentationDoesNotRunPreparation() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()
        var preparationCount = 0

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Cancelled")),
            configuration: CustomTooltipConfiguration(showDelay: 0.5, displayDuration: nil),
            prepareForPresentation: {
                preparationCount += 1
                return true
            }
        )
        controller.pointerExited(ownerID: ownerID)
        scheduler.fireNext()

        XCTAssertEqual(preparationCount, 0)
        XCTAssertFalse(presenter.isVisible)
    }

    func testRightPlacementFlipsLeftAndClampsVertically() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let origin = CustomTooltipGeometry.origin(
            contentSize: CGSize(width: 180, height: 220),
            anchorScreenRect: CGRect(x: 450, y: 260, width: 30, height: 30),
            visibleFrame: visibleFrame,
            placement: .right
        )

        XCTAssertEqual(origin.x, 264)
        XCTAssertEqual(origin.y, 76)
    }

    func testAttachedLeftPlacementAndBothScreenEdgeFallbacks() {
        let size = CGSize(width: 180, height: 120)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(CustomTooltipGeometry.origin(
            contentSize: size, anchorScreenRect: CGRect(x: 750, y: 400, width: 200, height: 40),
            visibleFrame: screen, placement: .leftTopAttached
        ), CGPoint(x: 570, y: 320))
        XCTAssertEqual(CustomTooltipGeometry.origin(
            contentSize: size, anchorScreenRect: CGRect(x: 20, y: 400, width: 200, height: 40),
            visibleFrame: screen, placement: .leftTopAttached
        ), CGPoint(x: 220, y: 320))
        XCTAssertEqual(CustomTooltipGeometry.origin(
            contentSize: size, anchorScreenRect: CGRect(x: 750, y: 400, width: 200, height: 40),
            visibleFrame: screen, placement: .rightTopAttached
        ), CGPoint(x: 570, y: 320))
    }

    func testSidebarPreviewsOpenTowardThePage() {
        let keys = [PhiPreferences.GeneralSettings.sidebarPositionKey, PhiPreferences.GeneralSettings.layoutModeKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let preview = CustomTooltipConfiguration(placement: .rightTopAttached, handoffGroup: .tabPreview)
        let plain = CustomTooltipConfiguration(placement: .rightTopAttached)

        UserDefaults.standard.set(LayoutMode.performance.rawValue, forKey: keys[1])
        UserDefaults.standard.set(SidebarPosition.left.rawValue, forKey: keys[0])
        XCTAssertEqual(preview.presentationPlacement, .rightTopAttached)
        UserDefaults.standard.set(SidebarPosition.right.rawValue, forKey: keys[0])
        XCTAssertEqual(preview.presentationPlacement, .leftTopAttached)
        XCTAssertEqual(plain.presentationPlacement, .rightTopAttached)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: keys[1])
        XCTAssertEqual(preview.presentationPlacement, .rightTopAttached)
    }

    func testBelowPlacementFlipsAboveNearScreenBottom() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let origin = CustomTooltipGeometry.origin(
            contentSize: CGSize(width: 200, height: 120),
            anchorScreenRect: CGRect(x: 200, y: 10, width: 100, height: 30),
            visibleFrame: visibleFrame,
            placement: .below
        )

        XCTAssertEqual(origin.x, 150)
        XCTAssertEqual(origin.y, 46)
    }

    func testAttachedRightPlacementAlignsLeftAndTopEdges() {
        let contentSize = CGSize(width: 280, height: 220)
        let anchorRect = CGRect(x: 100, y: 400, width: 200, height: 40)
        let origin = CustomTooltipGeometry.origin(
            contentSize: contentSize,
            anchorScreenRect: anchorRect,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            placement: .rightTopAttached
        )

        XCTAssertEqual(origin.x, anchorRect.maxX)
        XCTAssertEqual(origin.y + contentSize.height, anchorRect.maxY)
    }

    func testAttachedBelowPlacementAlignsCentersAndEdges() {
        let contentSize = CGSize(width: 280, height: 220)
        let anchorRect = CGRect(x: 300, y: 400, width: 120, height: 40)
        let origin = CustomTooltipGeometry.origin(
            contentSize: contentSize,
            anchorScreenRect: anchorRect,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            placement: .belowAttached
        )

        XCTAssertEqual(origin.x + contentSize.width / 2, anchorRect.midX)
        XCTAssertEqual(origin.y + contentSize.height, anchorRect.minY)
    }

    func testStaleExitCannotDismissNewOwner() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        controller.pointerExited(ownerID: firstOwnerID)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertEqual(presenter.presentCount, 2)
    }

    func testConfiguredDisplayDurationHidesTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Timed")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: 2.5)
        )

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(scheduler.pendingDelays, [2.5])

        scheduler.fireNext()

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
    }

    func testUpdatingPendingShowDelayReschedulesPresentation() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Pending")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        controller.update(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Updated")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )

        XCTAssertEqual(scheduler.pendingDelays, [1])
        scheduler.fireNext()
        XCTAssertTrue(presenter.isVisible)
    }

    func testUpdatingVisibleDisplayDurationReschedulesDismissal() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        controller.update(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Updated")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: 3)
        )

        XCTAssertEqual(scheduler.pendingDelays, [3])
        scheduler.fireNext()
        XCTAssertFalse(presenter.isVisible)
    }

    func testWindowResignCancelsPendingAndHidesVisibleTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(presenter.isVisible)

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: fixture.window
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Pending")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: fixture.window
        )
        scheduler.fireNext()

        XCTAssertNil(controller.pendingOwnerID)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testApplicationResignHidesTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
    }

    func testOtherWindowResignDoesNotHideTooltip() {
        let fixture = makeWindow()
        let otherWindow = makeWindow().window
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: otherWindow
        )

        XCTAssertTrue(presenter.isVisible)
    }

    func testControllerUsesSourceWindowThemeProvider() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let themeContext = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: Theme(id: "tooltip-theme", name: "Tooltip"),
                userAppearanceChoice: .dark,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter,
            themeProvider: { _ in themeContext }
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Themed")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )

        XCTAssertTrue(presenter.lastThemeProvider === themeContext)
        XCTAssertEqual(presenter.lastThemeProvider?.currentAppearance, .dark)
    }

    func testRealTooltipSurfaceTracksWindowThemeAndSwiftUIEnvironment() throws {
        let fixture = makeWindow()
        fixture.window.orderFront(nil)
        let scheduler = ManualScheduler()
        let initialTheme = Theme(id: "tooltip-light", name: "Tooltip Light")
        let updatedTheme = Theme(id: "tooltip-dark", name: "Tooltip Dark")
        let themeContext = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: initialTheme,
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )
        let probe = TooltipThemeProbe()
        let controller = CustomTooltipController(
            window: fixture.window,
            scheduler: scheduler.schedule,
            mouseLocation: { fixture.mouseLocation },
            isEligibleForPresentation: { _ in true },
            themeProvider: { _ in themeContext }
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(TooltipThemeProbeView(probe: probe)),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        waitForMainQueueUpdates()

        let panel = try XCTUnwrap(
            fixture.window.childWindows?.compactMap { $0 as? NSPanel }.first
        )
        let surface = try XCTUnwrap(controller.surfaceIdentifiers)
        XCTAssertEqual(panel.appearance?.phiAppearance, .light)
        XCTAssertEqual(
            probe.latestSnapshot,
            TooltipThemeSnapshot(
                themeID: initialTheme.id,
                appearance: .light,
                colorScheme: .light
            )
        )

        themeContext.setTheme(updatedTheme)
        themeContext.setUserAppearanceChoice(.dark)
        waitForMainQueueUpdates()

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.surfaceIdentifiers?.panel, surface.panel)
        XCTAssertEqual(controller.surfaceIdentifiers?.hostingView, surface.hostingView)
        XCTAssertEqual(panel.appearance?.phiAppearance, .dark)
        XCTAssertEqual(
            probe.latestSnapshot,
            TooltipThemeSnapshot(
                themeID: updatedTheme.id,
                appearance: .dark,
                colorScheme: .dark
            )
        )

        controller.dismissAll()
        fixture.window.orderOut(nil)
    }

    func testVisualDefaultCustomWarmHandoffAndDarkModeAttachments() throws {
        let fixture = makeVisualWindow()
        fixture.window.appearance = Appearance.light.nsAppearance
        fixture.window.orderFront(nil)
        waitForMainQueueUpdates()

        let scheduler = ManualScheduler()
        let themeContext = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: Theme(id: "tooltip-visual", name: "Tooltip Visual"),
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )
        var mouseLocation = screenMidpoint(of: fixture.firstHost)
        let controller = CustomTooltipController(
            window: fixture.window,
            scheduler: scheduler.schedule,
            mouseLocation: { mouseLocation },
            isEligibleForPresentation: { _ in true },
            themeProvider: { _ in themeContext }
        )
        defer {
            controller.dismissAll()
            fixture.window.orderOut(nil)
        }

        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        fixture.firstHost.isActive = true
        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.firstHost,
            content: AnyView(DefaultCustomTooltipContent(text: "Default tooltip from A")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        waitForMainQueueUpdates()

        let panel = try XCTUnwrap(
            fixture.window.childWindows?.compactMap { $0 as? NSPanel }.first
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        let firstPanelOrigin = panel.frame.origin
        try attachVisualTooltipSnapshot(
            window: fixture.window,
            panel: panel,
            named: "Custom Tooltip - Light - Default Style"
        )

        controller.pointerExited(ownerID: firstOwnerID)
        XCTAssertFalse(controller.isVisible)

        fixture.firstHost.isActive = false
        fixture.secondHost.isActive = true
        mouseLocation = screenMidpoint(of: fixture.secondHost)
        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.secondHost,
            content: AnyView(VisualCustomTooltipContent()),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        waitForMainQueueUpdates()

        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
        XCTAssertNotEqual(firstPanelOrigin.x, panel.frame.origin.x)
        try attachVisualTooltipSnapshot(
            window: fixture.window,
            panel: panel,
            named: "Custom Tooltip - Light - Warm Custom Style"
        )

        themeContext.setUserAppearanceChoice(.dark)
        fixture.window.appearance = Appearance.dark.nsAppearance
        fixture.surface.needsDisplay = true
        fixture.firstHost.needsDisplay = true
        fixture.secondHost.needsDisplay = true
        waitForMainQueueUpdates()

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(panel.appearance?.phiAppearance, .dark)
        XCTAssertEqual(panel.contentView?.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(controller.surfaceIdentifiers?.panel, firstSurface.panel)
        XCTAssertEqual(controller.surfaceIdentifiers?.hostingView, firstSurface.hostingView)
        try attachVisualTooltipSnapshot(
            window: fixture.window,
            panel: panel,
            named: "Custom Tooltip - Dark - Warm Custom Style"
        )

        controller.pointerExited(ownerID: secondOwnerID)
        fixture.firstHost.isActive = true
        fixture.secondHost.isActive = false
        mouseLocation = screenMidpoint(of: fixture.firstHost)
        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.firstHost,
            content: AnyView(DefaultCustomTooltipContent(text: "Default tooltip from A")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        waitForMainQueueUpdates()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(controller.surfaceIdentifiers?.panel, firstSurface.panel)
        XCTAssertEqual(controller.surfaceIdentifiers?.hostingView, firstSurface.hostingView)
        try attachVisualTooltipSnapshot(
            window: fixture.window,
            panel: panel,
            named: "Custom Tooltip - Dark - Default Style"
        )
    }

    func testAppKitExtensionReusesRegistrationAndSuppressesNativeTooltip() throws {
        let fixture = makeWindow()
        let originalTrackingAreaCount = fixture.host.trackingAreas.count
        fixture.host.toolTip = "Native"

        fixture.host.setCustomTooltip(
            "Custom",
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstRegistration = try XCTUnwrap(fixture.host.customTooltipRegistration)

        XCTAssertNil(fixture.host.toolTip)
        XCTAssertEqual(fixture.host.trackingAreas.count, originalTrackingAreaCount + 1)

        fixture.host.setCustomTooltip(
            "Updated custom",
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(firstRegistration === fixture.host.customTooltipRegistration)
        XCTAssertEqual(fixture.host.trackingAreas.count, originalTrackingAreaCount + 1)

        fixture.host.toolTip = "Updated native"
        XCTAssertNil(fixture.host.toolTip)

        fixture.host.removeCustomTooltip()

        XCTAssertNil(fixture.host.customTooltipRegistration)
        XCTAssertEqual(fixture.host.toolTip, "Updated native")
    }

    func testAppKitExtensionDoesNotRestoreExplicitlyClearedNativeTooltip() {
        let fixture = makeWindow()
        fixture.host.toolTip = "Native"
        fixture.host.setCustomTooltip("Custom")

        fixture.host.toolTip = nil
        fixture.host.removeCustomTooltip()

        XCTAssertNil(fixture.host.toolTip)
    }

    func testAppKitRegistrationHandlesTrackingAreaObjectiveCSelectors() throws {
        let fixture = makeWindow()
        fixture.host.setCustomTooltip("Custom")
        let registration = try XCTUnwrap(fixture.host.customTooltipRegistration)
        let enteredSelector = NSSelectorFromString("mouseEntered:")
        let exitedSelector = NSSelectorFromString("mouseExited:")

        guard registration.responds(to: enteredSelector),
              registration.responds(to: exitedSelector) else {
            XCTFail("The tracking area owner must expose AppKit's mouse enter and exit selectors.")
            return
        }

        let enteredEvent = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        let exitedEvent = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseExited,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )

        registration.perform(enteredSelector, with: enteredEvent)
        XCTAssertTrue(registration.isHovering)

        registration.perform(exitedSelector, with: exitedEvent)
        XCTAssertFalse(registration.isHovering)
    }

    func testSwiftUIModifierInstallsSharedAppKitRegistration() {
        let fixture = makeWindow()
        let swiftUIView = Text("Host")
            .frame(width: 120, height: 32)
            .help("Native")
            .customTooltip("Custom")
        let hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.frame = CGRect(x: 20, y: 20, width: 120, height: 32)
        fixture.window.contentView?.addSubview(hostingView)
        hostingView.layoutSubtreeIfNeeded()

        let registration = allSubviews(of: hostingView)
            .compactMap(\.customTooltipRegistration)
            .first

        XCTAssertNotNil(registration)
    }

    func testSwiftUICustomTooltipSuppressesAdjacentHelpInEitherOrder() {
        let helpBeforeCustom = Text("Host")
            .help("Native")
            .customTooltip("Custom")
        let helpAfterCustom = Text("Host")
            .customTooltip("Custom")
            .help("Native")

        XCTAssertTrue(helpBeforeCustom.suppressesNativeHelp)
        XCTAssertTrue(helpAfterCustom.suppressesNativeHelp)
    }

    private typealias WindowFixture = (window: NSWindow, host: NSView, mouseLocation: CGPoint)
    private typealias VisualWindowFixture = (
        window: NSWindow,
        surface: VisualFixtureSurfaceView,
        firstHost: VisualFixtureHostView,
        secondHost: VisualFixtureHostView
    )

    private func makeWindow() -> WindowFixture {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        let host = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        contentView.addSubview(host)
        window.contentView = contentView

        let rectInWindow = host.convert(host.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return (window, host, CGPoint(x: screenRect.midX, y: screenRect.midY))
    }

    private func makeVisualWindow() -> VisualWindowFixture {
        let windowSize = CGSize(width: 560, height: 240)
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(
            x: 100,
            y: 100,
            width: windowSize.width,
            height: windowSize.height
        )
        let windowOrigin = CGPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
        let window = NSWindow(
            contentRect: CGRect(origin: windowOrigin, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let surface = VisualFixtureSurfaceView(
            frame: CGRect(origin: .zero, size: windowSize)
        )
        let firstHost = VisualFixtureHostView(
            frame: CGRect(x: 70, y: 110, width: 180, height: 56),
            title: "A · Default style",
            subtitle: "Default string overload"
        )
        let secondHost = VisualFixtureHostView(
            frame: CGRect(x: 310, y: 110, width: 180, height: 56),
            title: "B · Custom style",
            subtitle: "Configured cold delay: 5 s"
        )
        surface.addSubview(firstHost)
        surface.addSubview(secondHost)
        window.contentView = surface
        return (window, surface, firstHost, secondHost)
    }

    private func screenMidpoint(of view: NSView) -> CGPoint {
        guard let window = view.window else { return .zero }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return CGPoint(x: screenRect.midX, y: screenRect.midY)
    }

    private func attachVisualTooltipSnapshot(
        window: NSWindow,
        panel: NSPanel,
        named name: String
    ) throws {
        let sourceView = try XCTUnwrap(window.contentView)
        let panelView = try XCTUnwrap(panel.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        sourceView.layoutSubtreeIfNeeded()
        panelView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        panel.displayIfNeeded()

        let sourceImage = try XCTUnwrap(snapshot(of: sourceView))
        let panelImage = try XCTUnwrap(
            WebContentSnapshotter.captureOnScreen(
                panelView,
                resolution: .bestResolution
            ),
            "The visual attachment must use the real on-screen tooltip panel"
        )
        let panelOrigin = CGPoint(
            x: panel.frame.minX - window.frame.minX,
            y: panel.frame.minY - window.frame.minY
        )
        let composite = NSImage(
            size: sourceView.bounds.size,
            flipped: false
        ) { bounds in
            sourceImage.draw(in: bounds)
            panelImage.draw(
                in: CGRect(origin: panelOrigin, size: panel.frame.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        let attachment = XCTAttachment(image: composite, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func snapshot(of view: NSView) -> NSImage? {
        guard !view.bounds.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeController(
        fixture: WindowFixture,
        scheduler: ManualScheduler,
        presenter: RecordingPresenter,
        themeProvider: CustomTooltipController.ThemeProviderResolver? = nil
    ) -> CustomTooltipController {
        CustomTooltipController(
            window: fixture.window,
            presenter: presenter,
            scheduler: scheduler.schedule,
            mouseLocation: { fixture.mouseLocation },
            isEligibleForPresentation: { _ in true },
            themeProvider: themeProvider
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func waitForMainQueueUpdates() {
        let updatesFinished = expectation(description: "Main queue updates finished")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        updatesFinished.fulfill()
                    }
                }
            }
        }
        wait(for: [updatesFinished], timeout: 5)
    }
}

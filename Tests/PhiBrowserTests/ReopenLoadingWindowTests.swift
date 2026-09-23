// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A windowless reopen puts a loading window on screen at once, on the frame
/// the slot restore snapshot remembered, while Chromium replays the session
/// behind it. Whether a given saved slot gets one is decided before any window
/// exists, so the decision is a pure function of five facts — and every "no"
/// answer has to leave the reopen exactly as it is today.
///
/// This pins that truth table down. The frame the window is placed on is
/// covered by `SlotRestoreFrameTests`; this file only asks whether to place one.
final class ReopenLoadingWindowTests: XCTestCase {
    private let savedFrame = NSRect(x: 200, y: 100, width: 1180, height: 742)

    /// Every condition met: the switch is on, the user is reopening a
    /// windowless app with session restore on, and the saved slot was a normal
    /// window whose position we know.
    private func shouldShow(
        featureEnabled: Bool = true,
        sessionRestoreEnabled: Bool = true,
        isWindowlessReopen: Bool = true,
        slotWasFullScreen: Bool = false
    ) -> Bool {
        ReopenLoadingWindow.shouldShow(
            featureEnabled: featureEnabled,
            sessionRestoreEnabled: sessionRestoreEnabled,
            isWindowlessReopen: isWindowlessReopen,
            snapshotFrame: savedFrame,
            slotWasFullScreen: slotWasFullScreen
        )
    }

    func testShowsALoadingWindowForARememberedNormalSlot() {
        XCTAssertTrue(shouldShow())
    }

    func testShowsNothingWhileTheFeatureSwitchIsOff() {
        // The switch is the outermost gate: with it off a reopen must behave
        // exactly as it did before this feature existed, however good a
        // candidate the slot is.
        XCTAssertFalse(shouldShow(featureEnabled: false))
    }

    func testShowsNothingWhenTheUserTurnedSessionRestoreOff() {
        // Nothing is being restored, so there is nothing to wait for — the
        // reopen spawns one plain window through its own path.
        XCTAssertFalse(shouldShow(sessionRestoreEnabled: false))
    }

    func testShowsNothingWhenTheReopenIsNotWindowless() {
        // A browser window is already on screen; the user has feedback already.
        XCTAssertFalse(shouldShow(isWindowlessReopen: false))
    }

    func testShowsNothingForASlotWhoseSnapshotRememberedNoFrame() {
        // Written before the snapshot carried geometry, or unparseable. Placing
        // the window somewhere invented is the position jump this whole feature
        // exists to avoid. Spelled out rather than routed through the helper:
        // "no frame" is the one input the helper cannot express.
        XCTAssertFalse(ReopenLoadingWindow.shouldShow(
            featureEnabled: true,
            sessionRestoreEnabled: true,
            isWindowlessReopen: true,
            snapshotFrame: nil,
            slotWasFullScreen: false
        ))
    }

    func testShowsNothingForASlotThatWasFullScreen() {
        // A restored window always comes back as a normal window and only
        // re-enters fullscreen once restore settles, so a loading window here
        // would guarantee a visible jump instead of preventing one.
        XCTAssertFalse(shouldShow(slotWasFullScreen: true))
    }

    func testDecidesPerSlotSoOneFullScreenSlotDoesNotSuppressTheOthers() {
        // Multi-slot reopen: each saved slot answers for itself.
        XCTAssertTrue(shouldShow(slotWasFullScreen: false))
        XCTAssertFalse(shouldShow(slotWasFullScreen: true))
    }
}

/// The loading window and the restored browser window have to end up on
/// literally the same rect, or the hand-off jumps — the one thing this feature
/// must not do. The threat to that is AppKit: it rewrites a window's frame into
/// the screen's `visibleFrame` on every order-in, and a slot the user parked
/// half off an edge is a frame it will happily "repair". The Chromium fork
/// already refuses that for browser windows
/// (`-[BrowserNativeWidgetWindow constrainFrameRect:toScreen:]`); these pin the
/// other half down.
final class ReopenLoadingWindowPlacementTests: XCTestCase {
    /// The style mask the Chromium fork gives every normal browser window
    /// (`BrowserNativeWidgetMac::PopulateCreateWindowParams`, which starts from
    /// titled/closable/miniaturizable/resizable and adds full-size content for
    /// the `kBrowser` window class). The loading window has to wear the same one
    /// or AppKit builds it a different titlebar.
    private static let browserStyleMask: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    private static let trafficLights: [(String, NSWindow.ButtonType)] = [
        ("close", .closeButton), ("miniaturize", .miniaturizeButton), ("zoom", .zoomButton),
    ]

    /// A rect the work area certainly contains, so neither window under test is
    /// clamped and the comparison is about button placement only.
    private func settledFrame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.visibleFrame.minX + 40,
               y: screen.visibleFrame.minY + 40,
               width: 600,
               height: 400)
    }

    /// NOT a stand-in for the restored window — a stand-in for what AppKit
    /// alone does with the restored window's style mask. The real thing has the
    /// fork's own `NSThemeFrame` subclass under it and puts its traffic lights
    /// somewhere else; that difference is the whole reason
    /// `ReopenLoadingWindow.alignTrafficLights(to:)` exists, and this window is how
    /// the tests below show it is real.
    private func browserLikeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
                              styleMask: Self.browserStyleMask,
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        return window
    }

    /// Hangs off the left edge and below the work area — where a user may well
    /// have parked the window, and precisely what AppKit wants to correct.
    private func overhangingFrame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.visibleFrame.minX - 200,
               y: screen.visibleFrame.minY - 60,
               width: 800,
               height: 500)
    }

    func testKeepsAnOverhangingFrameThroughOrderIn() throws {
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let overhanging = overhangingFrame(on: screen)
        let window = ReopenLoadingWindow(frame: overhanging)
        defer { window.close() }

        window.orderFrontRegardless()

        XCTAssertEqual(window.frame, overhanging)
    }

    func testAppKitWouldOtherwiseHaveMovedIt() throws {
        // The control for the test above. Without it, that assertion would
        // still pass if AppKit ever stopped constraining ordered-in windows at
        // all, and would silently stop covering anything. This is the same
        // titled window with NEITHER of the loading window's two defenses: the
        // `setFrame` that undoes AppKit's constrain inside `init`, and the
        // `constrainFrameRect` refusal that stops it happening again on
        // order-in. The `setFrame` here is what makes this a control for the
        // second one — without it the assertion would be satisfied by the
        // init-time move alone, and order-in could stop constraining
        // altogether without any test noticing.
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let overhanging = overhangingFrame(on: screen)
        let titled = NSWindow(contentRect: overhanging,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        titled.isReleasedWhenClosed = false
        defer { titled.close() }
        titled.setFrame(overhanging, display: false)
        XCTAssertEqual(titled.frame, overhanging, "setFrame is refused too — control is void")

        titled.orderFrontRegardless()

        XCTAssertNotEqual(titled.frame, overhanging)
    }

    func testIsDressedLikeTheBrowserWindow() {
        // Corner radius, shadow and traffic-light placement all have to match
        // the restored window or the hand-off reads as one window being
        // replaced by another. Wearing its style mask is how they match: all
        // three then come from the same AppKit frame view. This asserts the
        // dressing, not the resulting pixels — the radius and shadow themselves
        // are a pixel judgement, made once against a real reopen and recorded
        // in the ticket, and the lights have their own two tests below. What it
        // buys is that a change back to borderless, or a mask trimmed back to
        // the buttonless one this window wore before, cannot pass unnoticed.
        let window = ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }

        XCTAssertEqual(window.styleMask, Self.browserStyleMask)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testCarriesTheThreeTrafficLights() throws {
        // The one piece of structure this window draws. A rect with nothing in
        // it reads as an application that has not started rather than one that
        // is loading, and the three lights are the cheapest thing that can be in
        // it: AppKit draws them, from the same style mask the browser window
        // uses, with no layout knowledge and nothing persisted.
        //
        // They are not merely hidden today — a titled window without
        // closable/miniaturizable/resizable HAS no standard buttons, so
        // `standardWindowButton` answers nil for all three.
        //
        // Built without a snapshot origin, so this is the fallback path: below
        // macOS 26 the window then keeps the buttonless mask, because the
        // constant the fallback uses was only ever measured on 26. See
        // `ReopenLoadingWindow.trafficLightOrigin(remembered:)`.
        guard #available(macOS 26, *) else {
            throw XCTSkip("no lights below macOS 26, on purpose")
        }
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let window = ReopenLoadingWindow(frame: settledFrame(on: screen))
        defer { window.close() }

        for (name, kind) in Self.trafficLights {
            let button = try XCTUnwrap(window.standardWindowButton(kind),
                                       "no \(name) button: the style mask does not ask for one")
            XCTAssertFalse(button.isHidden, "\(name) button is hidden")
            XCTAssertEqual(button.alphaValue, 1.0, accuracy: 0.001,
                           "\(name) button is transparent")
            // Visible but not pressable. `ignoresMouseEvents` handles the
            // mouse; this is the accessibility press, which would otherwise
            // reach a live `_close:` / `miniaturize:` / `_setNeedsZoom:` on a
            // window the user never opened. It costs nothing to look at —
            // disabled and enabled titlebars render byte-identically on a
            // window that can be neither key nor main.
            XCTAssertFalse(button.isEnabled, "\(name) button can still be pressed")
        }
    }

    /// Each light's origin as a distance from the window's top-left frame
    /// corner, which is the frame of reference both windows share.
    private func lightOrigins(of window: NSWindow) throws -> [NSPoint] {
        try Self.trafficLights.map { name, kind in
            let button = try XCTUnwrap(window.standardWindowButton(kind), "no \(name) button")
            let inWindow = button.convert(button.bounds, to: nil)
            return NSPoint(x: inWindow.minX, y: window.frame.height - inWindow.maxY)
        }
    }

    func testItsTrafficLightsSitWhereTheSnapshotSawTheRestoredWindowsOwn() throws {
        // The answer to the debt the copied constants are. When the snapshot
        // carries an origin it was read off the very window this one stands in
        // for — this machine, this Chromium, this layout — so there is nothing
        // left to keep in step with the fork and nothing to re-measure after a
        // Chromium upgrade. Deliberately NOT the fallback's value, so a wiring
        // mistake that quietly ignored the snapshot would fail here.
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let seen = NSPoint(x: 17, y: 11)
        let loading = ReopenLoadingWindow(frame: settledFrame(on: screen),
                                          trafficLightOrigin: seen)
        defer { loading.close() }

        XCTAssertEqual(try lightOrigins(of: loading),
                       [seen, NSPoint(x: 40, y: 11), NSPoint(x: 63, y: 11)])

        loading.orderFrontRegardless()

        XCTAssertEqual(try lightOrigins(of: loading),
                       [seen, NSPoint(x: 40, y: 11), NSPoint(x: 63, y: 11)],
                       "order-in put the lights back where AppKit wanted them")
    }

    func testTheSidebarBandDoesNotDisturbTheLights() throws {
        // The two pieces of structure interact, and the interaction is not
        // obviously safe: the band is installed by giving the window a content
        // view, and AppKit lays the titlebar out again when it gets one. The
        // correction runs once, at the end of `init`, so if that layout pass
        // came afterwards the lights would silently be back at AppKit's own
        // (9, 9) with a perfectly good band beside them.
        //
        // Also asserts the band did not swallow them: the buttons live in the
        // frame view, which is the content view's PARENT, so a band covering
        // the leading 193 points must still leave three visible buttons over
        // it and none of them inside the content view.
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let seen = NSPoint(x: 17, y: 11)
        let loading = ReopenLoadingWindow(frame: settledFrame(on: screen),
                                          sidebarWidth: 193,
                                          sidebarTint: .systemBlue,
                                          trafficLightOrigin: seen)
        defer { loading.close() }
        loading.orderFrontRegardless()

        XCTAssertNotNil(loading.sidebarBand, "no band, so this proves nothing")
        XCTAssertEqual(try lightOrigins(of: loading),
                       [seen, NSPoint(x: 40, y: 11), NSPoint(x: 63, y: 11)])
        for (name, kind) in Self.trafficLights {
            let button = try XCTUnwrap(loading.standardWindowButton(kind), "no \(name) button")
            XCTAssertFalse(button.isHidden, "the band hid the \(name) button")
            XCTAssertFalse(button.isDescendant(of: try XCTUnwrap(loading.contentView)),
                           "the \(name) button is inside the content view the band lives in")
        }
    }

    func testTheOriginItRecordsIsTheOriginItRestores() throws {
        // The persist side measures an origin off a real window and the reopen
        // side puts the lights back on it. The two use the same "distance down
        // from the top-left frame corner" convention and their docs say they
        // must — nothing enforced it, and a sign flip in either half would only
        // show up as a misaligned hand-off on a real machine.
        guard #available(macOS 26, *) else { throw XCTSkip("no lights below macOS 26") }
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        for wanted in [NSPoint(x: 13, y: 13.5), NSPoint(x: 17, y: 11), NSPoint(x: 4, y: 30)] {
            let window = ReopenLoadingWindow(frame: settledFrame(on: screen),
                                             trafficLightOrigin: wanted)
            defer { window.close() }

            XCTAssertEqual(ReopenLoadingWindow.measuredTrafficLightOrigin(in: window),
                           wanted, "round trip failed for \(wanted)")
        }
    }

    func testPrefersTheRememberedOriginButKeepsTheVersionGate() {
        // A remembered origin beats the copy, because it was read off the very
        // window this one stands in for. It does NOT lift the macOS 26 gate:
        // that gate is about the other two lights, whose 23pt pitch and 14pt
        // size were only ever measured against the fork's frame view on 26.5,
        // and the correction moves all three rigidly off the leading one.
        let remembered = NSPoint(x: 17, y: 11)

        if #available(macOS 26, *) {
            XCTAssertEqual(ReopenLoadingWindow.trafficLightOrigin(remembered: remembered),
                           remembered)
            XCTAssertEqual(ReopenLoadingWindow.trafficLightOrigin(remembered: nil),
                           ReopenLoadingWindow.copiedTrafficLightOrigin)
        } else {
            XCTAssertNil(ReopenLoadingWindow.trafficLightOrigin(remembered: remembered),
                         "the pitch was never measured here; no lights beats wrong lights")
            XCTAssertNil(ReopenLoadingWindow.trafficLightOrigin(remembered: nil))
        }
    }

    func testItsTrafficLightsSitOnTheOriginMeasuredOffARestoredWindow() throws {
        // The FALLBACK path — no snapshot origin, so the copied constant is
        // used. Reachable on the first reopen after a build that records the
        // origin, and on any snapshot written before it did.
        //
        // The load-bearing half, and the one that turned out not to be free.
        // Lights a few points out of place turn the hand-off into the visible
        // jump this whole route exists to avoid, and frame equality cannot see
        // it.
        //
        // Wearing the browser window's style mask is NOT enough on its own: the
        // fork puts its own `NSThemeFrame` subclass under the browser window and
        // moves them (see `alignTrafficLights(to:)`). These are
        // the positions measured off a real reopen, and the control below shows
        // that an untouched window with the same mask does not reach them.
        //
        // The name says "measured off" rather than "the same as" on purpose:
        // no restored window exists in this process, so what this compares
        // against is a number a human read off a screen recording, not the
        // browser window. It catches the correction being dropped, the
        // coordinate maths being wrong and the mask being trimmed. It cannot
        // catch the number itself going stale — only a pixel round can, and
        // when the fork's own value moves nothing here will go red.
        guard #available(macOS 26, *) else {
            throw XCTSkip("the positions asserted here were measured on macOS 26")
        }
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let loading = ReopenLoadingWindow(frame: settledFrame(on: screen))
        defer { loading.close() }
        let expected = [NSPoint(x: 13, y: 13.5),
                        NSPoint(x: 36, y: 13.5),
                        NSPoint(x: 59, y: 13.5)]

        XCTAssertEqual(try lightOrigins(of: loading), expected)

        // And again after order-in. The correction runs once, at the end of
        // `init`, and AppKit lays the titlebar out again whenever the window
        // changes — order-in being the first thing that happens to this one,
        // one line after it is built. A real reopen was measured holding the
        // position for the window's whole visible life, but nothing in the
        // suite would notice it stopping.
        loading.orderFrontRegardless()

        XCTAssertEqual(try lightOrigins(of: loading), expected,
                       "order-in put the lights back where AppKit wanted them")
    }

    func testAppKitAloneWouldPutThemSomewhereElse() throws {
        // The control for the test above. Same style mask, same rect, none of
        // this window's correction — if AppKit ever placed them where the fork
        // does, that test would be passing for a reason that no longer holds and
        // this one says so. It also records what AppKit's own answer is, which
        // is the number the correction is measured against.
        //
        // Phi itself never moves the browser window's buttons, so the fork is
        // the whole of the difference: the sidebar's floating lights are a
        // separate view that DRAWS lights and forwards clicks
        // (`FloatingTrafficLightsView.performWindowButtonAction`), deliberately
        // leaving the real ones in the titlebar, and the only thing Chromium
        // does to them directly is reset their alpha.
        guard #available(macOS 26, *) else {
            throw XCTSkip("paired with the test above")
        }
        let screen = try XCTUnwrap(NSScreen.main, "no display attached")
        let plain = browserLikeWindow(frame: settledFrame(on: screen))
        defer { plain.close() }

        XCTAssertEqual(try lightOrigins(of: plain),
                       [NSPoint(x: 9, y: 9), NSPoint(x: 32, y: 9), NSPoint(x: 55, y: 9)],
                       "AppKit's own placement changed; re-measure the fork's before trusting it")
    }

    func testSlipsUnderneathTheRestoredWindowInsteadOfBeingSwappedForIt() throws {
        // The load-bearing property of the whole hand-off. The restored window
        // reaches the screen several hundred milliseconds before its first frame does, so anything
        // that removes the loading window on a signal uncovers the desktop for
        // that long; leaving the loading window UNDERNEATH means the restored
        // window hides it itself, the moment it has something to hide it with.
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        let loading = ReopenLoadingWindow(frame: frame)
        let restored = NSWindow(contentRect: frame,
                                styleMask: [.titled, .closable],
                                backing: .buffered,
                                defer: false)
        restored.isReleasedWhenClosed = false
        defer { loading.close(); restored.close() }
        loading.orderFrontRegardless()
        restored.orderFrontRegardless()

        loading.pinUnder(restored)

        // Ordered index counts from the front, so a larger one is further back.
        XCTAssertGreaterThan(loading.orderedIndex, restored.orderedIndex)
    }

    func testStaysUnderTheRestoredWindowOnceTheHandOffIsDeclared() throws {
        // The sequence the test above does NOT reproduce, and the one that
        // actually happens: the hand-off is declared inside Chromium's
        // window-created callback, where the restored window exists but has
        // never been ordered in, and it has to hold from there on with nothing
        // running later to repair it — the runloop turn a repair would need is
        // starved by the replay for over a second.
        //
        // The `orderFrontRegardless` at the end stands in for anything that
        // fronts the loading window afterwards. It is the operation that
        // defeats a one-shot ordering, so it is what separates "the two windows
        // happened to come up in the right order" from "the loading window
        // cannot get on top".
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        let loading = ReopenLoadingWindow(frame: frame)
        let restored = NSWindow(contentRect: frame,
                                styleMask: [.titled, .closable],
                                backing: .buffered,
                                defer: false)
        restored.isReleasedWhenClosed = false
        defer { loading.close(); restored.close() }
        loading.orderFrontRegardless()

        loading.pinUnder(restored)
        XCTAssertTrue(loading.isVisible,
                      "declaring the hand-off must not take the loading window off the rect it is covering")
        restored.makeKeyAndOrderFront(nil)
        loading.orderFrontRegardless()

        // Both halves are needed. `orderedIndex` stays a normal, larger integer
        // for a window that has been ordered OUT, so the ordering assertion on
        // its own is equally satisfied by the loading window having left the
        // screen — which is the failure a child relationship could newly cause.
        XCTAssertTrue(loading.isVisible, "still behind, but no longer covering anything")
        XCTAssertGreaterThan(loading.orderedIndex, restored.orderedIndex)
    }

    func testIsOrderedOutWithTheWindowItIsPinnedUnder() throws {
        // The other half of the relationship, asserted because `pinUnder`'s
        // documentation claims it: while the restored window is off screen the
        // loading window must not be left behind on a bare rect.
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        let loading = ReopenLoadingWindow(frame: frame)
        let restored = NSWindow(contentRect: frame,
                                styleMask: [.titled, .closable],
                                backing: .buffered,
                                defer: false)
        restored.isReleasedWhenClosed = false
        defer { loading.close(); restored.close() }
        loading.orderFrontRegardless()
        loading.pinUnder(restored)
        restored.makeKeyAndOrderFront(nil)
        XCTAssertTrue(loading.isVisible)

        restored.orderOut(nil)

        XCTAssertFalse(loading.isVisible)
    }

    func testAnUndeclaredOrderingCanBeDefeated() throws {
        // The control for the test above: the same attack on two windows with
        // no hand-off declared between them. Without this, that assertion would
        // still pass if `orderFrontRegardless` ever stopped raising windows at
        // all, and would be pinning nothing.
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        let loading = ReopenLoadingWindow(frame: frame)
        let restored = NSWindow(contentRect: frame,
                                styleMask: [.titled, .closable],
                                backing: .buffered,
                                defer: false)
        restored.isReleasedWhenClosed = false
        defer { loading.close(); restored.close() }
        loading.orderFrontRegardless()

        restored.makeKeyAndOrderFront(nil)
        XCTAssertGreaterThan(loading.orderedIndex, restored.orderedIndex,
                             "the restored window's own show did not put it on top — attack is void")
        loading.orderFrontRegardless()

        XCTAssertLessThan(loading.orderedIndex, restored.orderedIndex)
    }

    func testGivesUpItsShadowSoTheTwoNeverStack() {
        // Same rect means the same ring of desktop under both shadows, and a
        // doubled shadow would visibly LIGHTEN at destruction — turning the one
        // event this design makes invisible back into a visible one.
        let loading = ReopenLoadingWindow(frame: NSRect(x: 200, y: 200, width: 600, height: 400))
        defer { loading.close() }
        XCTAssertTrue(loading.hasShadow, "a window with no shadow at all reads as pasted on")

        loading.yieldShadow()

        XCTAssertFalse(loading.hasShadow)
    }

    func testStaysOutOfTheWindowMenuAndTheCommandBacktickCycle() {
        let window = ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }

        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(window.collectionBehavior.contains(.transient))
    }

    func testNeverTakesKeyAwayFromTheWindowTheUserWillType() {
        let window = ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }

        XCTAssertFalse(window.canBecomeKey)
    }

    func testNeverBecomesTheApplicationsMainWindow() {
        // Not a duplicate of the test above: AppKit's default lets any TITLED
        // window be main whether or not it can be key, and for the first half
        // second of a reopen this is the only window on screen. Menu validation
        // and the alert presenter both fall back to `NSApp.mainWindow`.
        let window = ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }

        XCTAssertFalse(window.canBecomeMain)
    }
}

/// When the loading window may be destroyed.
///
/// It sits BELOW the restored window rather than being swapped for it, so from
/// the first frame that window paints the loading window is already hidden and
/// every later moment to remove it looks identical to the user. What is left to
/// get right is not the instant but the guarantee: the moment must arrive, and
/// it must not arrive while the restored window is still contributing no pixels
/// — measured at 538ms to 1095ms after it is ordered in, during which the
/// screen still shows whatever was there before. See
/// `ReopenLoadingHandoff.revealGrace` for why that range is so wide and for how
/// little margin the grace has over the top of it.
final class ReopenLoadingHandoffTests: XCTestCase {
    private let started = Date(timeIntervalSinceReferenceDate: 1_000)

    private func handoff() -> ReopenLoadingHandoff {
        ReopenLoadingHandoff(startedAt: started)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        started.addingTimeInterval(seconds)
    }

    private func waitSeconds(_ outcome: ReopenLoadingHandoff.Outcome) -> TimeInterval? {
        guard case .wait(let seconds) = outcome else { return nil }
        return seconds
    }

    private let grace = ReopenLoadingHandoff.revealGrace

    func testWaitsWhileTheRestoreIsStillRunning() {
        // A window is up, but Chromium is still replaying: more windows may
        // still be coming, and the run is not over.
        let handoff = handoff()
        XCTAssertNotEqual(handoff.record(.restoredWindowRegistered, at: at(0.3)), .tearDown)
        XCTAssertNotEqual(handoff.reconsider(at: at(3.0)), .tearDown)
    }

    func testHoldsTheLoadingWindowAGraceAfterTheOneThatReplacesIt() {
        // The one case where the loading window can be pulled out from under a
        // window that has not drawn yet: a restore that settles almost
        // immediately. The window registers before it is on screen, so settling
        // is not on its own evidence that anything has been painted.
        let handoff = handoff()
        _ = handoff.record(.restoredWindowRegistered, at: at(0.2))

        XCTAssertNotEqual(handoff.record(.restoreSettled, at: at(0.3)), .tearDown)
        XCTAssertNotEqual(handoff.reconsider(at: at(0.2 + grace - 0.1)), .tearDown)
        XCTAssertEqual(handoff.reconsider(at: at(0.2 + grace + 0.1)), .tearDown)
    }

    func testTearsDownOnSettleOnceTheGraceIsLongGone() {
        // The ordinary six-Space reopen: the window registers at +0.26s, the
        // restore settles at +2.0s, and the loading window has been invisible
        // under the restored window since +0.77s.
        let handoff = handoff()
        _ = handoff.record(.restoredWindowRegistered, at: at(0.26))

        XCTAssertEqual(handoff.record(.restoreSettled, at: at(0.26 + grace + 0.25)), .tearDown)
    }

    func testStillWaitsWhenTheRestoreBroughtNoWindowBack() {
        // "Nothing restored" does NOT mean nothing is coming: the reopen
        // answers it by spawning a plain window instead, which needs the same
        // cover a restored one gets. Tearing down on the settle here would put
        // bare desktop between the loading window and that window — the two-hop
        // the whole feature exists to remove.
        let handoff = handoff()

        XCTAssertNotEqual(handoff.record(.restoreSettled, at: at(0.5)), .tearDown)
        XCTAssertEqual(handoff.reconsider(at: at(0.5 + grace + 0.1)), .tearDown)
    }

    func testTheFallbackWindowGetsItsOwnGraceWhenItArrives() {
        // ...and if that spawned window registers inside the settle's grace,
        // the grace restarts from it, because it is the window that has to
        // paint before the loading window may go.
        let handoff = handoff()
        _ = handoff.record(.restoreSettled, at: at(0.5))
        _ = handoff.record(.restoredWindowRegistered, at: at(0.9))

        XCTAssertNotEqual(handoff.reconsider(at: at(0.5 + grace + 0.1)), .tearDown)
        XCTAssertEqual(handoff.reconsider(at: at(0.9 + grace + 0.1)), .tearDown)
    }

    func testTearsDownAtTheBackstopWhenTheRestoreNeverSettles() {
        // The liveness guarantee: a restore that never reports back — a crash
        // page, a profile that never settles — must not leave a loading window
        // up for the rest of the session. It is also the only deadline in play
        // before the settle arrives, so the armed-timer chain runs on it
        // throughout.
        let handoff = handoff()
        _ = handoff.record(.restoredWindowRegistered, at: at(0.3))

        XCTAssertEqual(handoff.reconsider(at: at(ReopenLoadingHandoff.backstop)), .tearDown)
    }

    func testNeverWaitsPastTheBackstop() throws {
        // A wait handed back to the caller is a timer; none of them may be
        // armed for later than the backstop, or the backstop stops being one.
        // Here the grace alone would run past it.
        let handoff = handoff()
        _ = handoff.record(.restoredWindowRegistered, at: at(ReopenLoadingHandoff.backstop - 0.5))

        let outcome = handoff.record(.restoreSettled, at: at(ReopenLoadingHandoff.backstop - 0.4))

        XCTAssertEqual(try XCTUnwrap(waitSeconds(outcome)), 0.4, accuracy: 0.001)
    }

    func testASecondSettleChangesNothing() {
        // Both halves of "arrives twice": a duplicate before the deadline must
        // not restart the clock, and one after it must not restart the run.
        let handoff = handoff()
        _ = handoff.record(.restoreSettled, at: at(0.5))
        _ = handoff.record(.restoreSettled, at: at(1.0))

        XCTAssertEqual(handoff.reconsider(at: at(0.5 + grace + 0.1)), .tearDown)
        XCTAssertEqual(handoff.record(.restoreSettled, at: at(0.5 + grace + 0.2)),
                       .alreadyTornDown)
    }

    func testALaterWindowDoesNotPushTheGraceOut() {
        // Sibling Space windows keep registering for the rest of the restore.
        // The grace covers the FIRST one — the one the user is looking at —
        // and a tail of later arrivals must not keep extending it.
        let handoff = handoff()
        _ = handoff.record(.restoredWindowRegistered, at: at(0.2))
        _ = handoff.record(.restoredWindowRegistered, at: at(0.2 + grace - 0.2))
        _ = handoff.record(.restoreSettled, at: at(0.2 + grace - 0.1))

        XCTAssertEqual(handoff.reconsider(at: at(0.2 + grace + 0.01)), .tearDown)
    }

    func testAWindowRegisteringAfterTheTeardownIsIgnored() {
        // The loading window is gone; a late window cannot bring it back.
        let handoff = handoff()
        _ = handoff.record(.restoreSettled, at: at(0.5))
        XCTAssertEqual(handoff.reconsider(at: at(0.5 + grace + 0.1)), .tearDown)

        XCTAssertEqual(handoff.record(.restoredWindowRegistered, at: at(0.5 + grace + 0.3)),
                       .alreadyTornDown)
    }

    func testAsksToBeCalledBackBeforeItHasAnythingToGoOn() {
        // Nothing has happened yet, so the only deadline is the backstop.
        XCTAssertEqual(handoff().reconsider(at: started),
                       .wait(ReopenLoadingHandoff.backstop))
    }
}

/// What the loading window shows, and — the point of this group — what it must
/// never show.
///
/// The first version of this window turned a ring in the middle. Measured
/// against the same scene with the feature off, it put the first thing on
/// screen ~780ms sooner and the page's own first frame ~450ms LATER; freezing
/// just the ring's animation and changing nothing else took roughly two thirds
/// of that second number away (n=3 per group, so the size is indicative and the
/// direction is not). A 32pt ring had been making the window server recomposite
/// this rect at 60fps for two seconds, to report that the main thread was too
/// busy to draw.
///
/// The bill is per recomposition, not per second the window is up, so what came
/// back is the same message at a rate that can be afforded: three dots lighting
/// in turn three times a second, ~6 recompositions over the same span against
/// the ring's ~120. The rate is not a guess — still / 3 steps a second / 15 /
/// interpolated-per-display-refresh were swept on the real reopen, and the
/// table of what each one cost is in `ReopenLoadingWindow`'s own class comment.
/// `testTheIndicatorAdvancesInDiscreteStepsAtTheSettledRate` holds it there and
/// `testTheIndicatorIsTheOnlyThingThatAnimates` stops anything else joining in.
///
/// What it draws besides is one flat band down the left, the width the slot's
/// sidebar had — enough for the rect to read as a browser window rather than a
/// blank one, which three 14pt traffic lights (about 0.05% of the rect) were
/// not. Every number the band and the lights need comes off the snapshot,
/// measured from the very window it is standing in for: a guessed width would
/// put the boundary somewhere the restored window's is not, and the whole route
/// exists to stop the user seeing anything move at the hand-off. The indicator
/// is the exception that proves that rule — it corresponds to nothing in the
/// restored window, so it needs no stored number and is simply covered when
/// that window paints.
final class ReopenLoadingWindowContentTests: XCTestCase {
    /// The sidebar's own fill, resolved the way `SidebarViewController` resolves
    /// it. The value is not what these tests are about — that it is a theme
    /// role rather than a colour picked to look close is.
    private let tint = ThemedColor(role: .windowOverlayBackground).resolved()

    private func window(sidebarWidth: CGFloat? = nil) -> ReopenLoadingWindow {
        ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 1180, height: 742),
                            sidebarWidth: sidebarWidth,
                            sidebarTint: tint)
    }

    // MARK: - Whether there is a band at all

    func testDrawsNoBandForASnapshotThatRememberedNoSidebarWidth() {
        // The first reopen after this field was added, and every snapshot
        // written by a build without it. A default would be a guess, and a band
        // whose edge does not land where the restored window's sidebar ends
        // moves at the hand-off — worse than no band, which is why this returns
        // nil rather than `leftItemMinWidth`.
        XCTAssertNil(ReopenLoadingWindow.sidebarBandWidth(remembered: nil,
                                                          inWindowOfWidth: 1180))
    }

    func testDrawsNoBandForACollapsedSidebar() {
        // Zero is the snapshot's word for collapsed, and `.comfortable` records
        // itself the same way because it keeps the sidebar collapsed
        // permanently. One number therefore answers "how wide" and "at all" and
        // "which layouts" together, and no `LayoutMode` is read anywhere here.
        XCTAssertNil(ReopenLoadingWindow.sidebarBandWidth(remembered: 0,
                                                          inWindowOfWidth: 1180))
    }

    func testDrawsABandAtExactlyTheRememberedWidth() {
        XCTAssertEqual(ReopenLoadingWindow.sidebarBandWidth(remembered: 193,
                                                            inWindowOfWidth: 1180),
                       193)
    }

    func testDrawsNoBandForAWidthThatDoesNotFitTheWindow() {
        // The frame is clamped to the screens attached now, so a slot saved on
        // a wide display could in principle come back narrower than its own
        // sidebar was. Clamping to the window would make the band the whole
        // rect in one colour — a solid block rather than a browser window, and
        // nowhere near where the restored sidebar will end — so this falls
        // under the same rule as every other unusable width: draw nothing.
        XCTAssertNil(ReopenLoadingWindow.sidebarBandWidth(remembered: 500,
                                                          inWindowOfWidth: 400))
        // Exactly filling it is still a width, not an overflow.
        XCTAssertEqual(ReopenLoadingWindow.sidebarBandWidth(remembered: 400,
                                                            inWindowOfWidth: 400),
                       400)
    }

    // MARK: - The band itself

    func testTheBandRunsDownTheLeadingEdgeForTheFullHeight() throws {
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let band = try XCTUnwrap(window.sidebarBand, "no band was drawn")

        // In the content view's coordinates, which for a full-size-content
        // window are the frame's — so this rect IS the boundary the restored
        // window's sidebar has to end on.
        XCTAssertEqual(band.frame, NSRect(x: 0, y: 0, width: 193, height: 742))
    }

    func testTheBandIsFilledWithTheColourItWasGiven() throws {
        // Only that the initializer paints with what it is handed. That the
        // colour handed in is the sidebar's own theme role is a different
        // claim and belongs to `SpaceManager.sidebarTint(forSpaceId:)`, which
        // this cannot see — a version of this test that resolved the role
        // itself and compared would stay green if that function returned pink.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let band = try XCTUnwrap(window.sidebarBand)

        XCTAssertEqual(band.backgroundColor, tint)
        // The other half of the recipe, and the half that does the work: a
        // flat fill of this colour is invisible on the default theme, and the
        // separation the eye reads comes from the material.
        XCTAssertEqual(band.material, .fullScreenUI)
        XCTAssertEqual(band.state, .active,
                       "a window that can never be key would render the inactive material")
    }

    func testTheTintIsTheRoleTheSidebarGivesItsOwnRootView() {
        // The other half, and the 🔴 requirement: not a colour picked to look
        // close, the role itself. `SidebarViewController.loadView` sets
        // `themedBackgroundColor = .windowOverlayBackground`; this asserts the
        // loading window's supplier resolves the same role against the same
        // app-wide theme. Only the uncustomized branch is reachable from here
        // — the customized one needs a bound account and a Space id — and that
        // gap is recorded in the ticket.
        let expected = ThemedColor(role: .windowOverlayBackground).resolved()

        XCTAssertEqual(SpaceManager.shared.sidebarTint(forSpaceId: nil), expected)
    }

    func testNoBandMeansNoBandLayerAtAll() {
        // Not a zero-width layer, not a transparent one: nothing for the
        // compositor to carry, so a reopen with no remembered width costs
        // exactly what a bandless one cost before this existed. The indicator
        // is a separate decision and is still there — `.comfortable` is the
        // layout with no band and the user asked for it in every layout.
        let window = self.window(sidebarWidth: nil)
        defer { window.close() }

        XCTAssertNil(window.sidebarBand)
        XCTAssertEqual(window.contentView?.subviews.count ?? 0, 1,
                       "something other than the indicator is in the content view")
        XCTAssertEqual(window.contentView?.subviews.first, window.activityDots)
    }

    func testNothingIsDrawnBesidesTheBandAndTheIndicator() throws {
        // The rule the band had to be argued past: nothing here reads a
        // preference, and nothing here draws data. No tabs, no Space chips, no
        // `+ New Tab` row — the row has no resting fill of its own to
        // reproduce (`NewTabButtonCellView` sets its background clear and only
        // fills on hover), so any shape drawn at it would be invented.
        //
        // The indicator is the one thing here that copies nothing, and that is
        // allowed for the opposite reason: it corresponds to no part of the
        // restored window, so it cannot be drawn in the wrong place relative to
        // one. It is covered rather than replaced at the hand-off.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let expected = [window.sidebarBand as NSView?, window.activityDots]
            .compactMap { $0 }
            .map(ObjectIdentifier.init)

        XCTAssertEqual(expected.count, 2, "one of the two was never built")
        XCTAssertEqual(Set(content.subviews.map(ObjectIdentifier.init)), Set(expected))
        XCTAssertEqual(content.subviews.count, 2)
    }

    // MARK: - The activity indicator

    func testCentresTheIndicatorInTheContentAreaBesideTheBand() {
        // In `.performance` and `.balanced` the blank area the user is looking
        // at is what is left of the rect once the band has taken the leading
        // 193 points, so the group is centred in 193...1180 rather than in the
        // window: 987 wide, so a 66pt group starts at 193 + 460.5.
        XCTAssertEqual(ReopenLoadingWindow.activityDotsFrame(
                           besideBandOfWidth: 193,
                           inWindowOfSize: NSSize(width: 1180, height: 742)),
                       NSRect(x: 653.5, y: 364, width: 66, height: 14))
    }

    func testCentresTheIndicatorInTheWholeWindowWhenThereIsNoBand() {
        // 🔴 `.comfortable` draws no band, and the user was explicit that every
        // layout needs this. With nothing to sit beside, the content area is
        // the whole rect — which is exactly what is blank there, since that
        // layout's loading window is a plain rect with three lights in it.
        XCTAssertEqual(ReopenLoadingWindow.activityDotsFrame(
                           besideBandOfWidth: nil,
                           inWindowOfSize: NSSize(width: 1180, height: 742)),
                       NSRect(x: 557, y: 364, width: 66, height: 14))
    }

    func testDrawsNoIndicatorWhereItWouldNotFit() {
        // Same rule the band is under, for the same reason: refuse rather than
        // squeeze. A group crushed against the band's edge or clipped by the
        // window is not a loading indicator, it is a defect the user gets to
        // see for a second.
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(
            besideBandOfWidth: 193, inWindowOfSize: NSSize(width: 220, height: 742)))
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(
            besideBandOfWidth: nil, inWindowOfSize: NSSize(width: 1180, height: 8)))
        // Exactly filling the content area is a fit, not an overflow.
        XCTAssertEqual(ReopenLoadingWindow.activityDotsFrame(
                           besideBandOfWidth: 193,
                           inWindowOfSize: NSSize(width: 259, height: 14)),
                       NSRect(x: 193, y: 0, width: 66, height: 14))
    }

    func testDrawsNoIndicatorFromANumberThatIsNotOne() {
        // Unreachable through either caller — both sides of the snapshot are
        // finite-checked before they get here — but an infinity would otherwise
        // come back out as an infinite ORIGIN rather than as a refusal, and
        // this campaign has already been caught out once by a non-finite number
        // travelling further than anyone expected it to.
        let size = NSSize(width: 1180, height: 742)
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(besideBandOfWidth: .nan,
                                                           inWindowOfSize: size))
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(besideBandOfWidth: .infinity,
                                                           inWindowOfSize: size))
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(
            besideBandOfWidth: nil,
            inWindowOfSize: NSSize(width: CGFloat.infinity, height: 742)))
        XCTAssertNil(ReopenLoadingWindow.activityDotsFrame(
            besideBandOfWidth: nil,
            inWindowOfSize: NSSize(width: 1180, height: CGFloat.nan)))
    }

    func testEveryLayoutGetsTheIndicator() {
        // 🔴 The user's words: every layout. Nothing in this class reads
        // `LayoutMode` — the band's one number stands in for all three — so
        // this is the whole requirement, expressed the way the code expresses
        // it. All three inputs are real: 193 is the two vertical-tab layouts,
        // **0 is `.comfortable`**, which keeps the sidebar collapsed and
        // records itself that way (`band=0.0->none` in its own log line), and
        // nil is a snapshot written before the field existed. 0 and nil reach
        // the same branch, but only one of them is the layout the requirement
        // names, so both are passed rather than one standing in for the other.
        for width: CGFloat? in [193, 0, nil] {
            let window = self.window(sidebarWidth: width)
            defer { window.close() }

            XCTAssertNotNil(window.activityDots,
                            "no indicator for sidebarWidth \(String(describing: width))")
        }
    }

    func testTheIndicatorIsInstalledOnTheRectItWasGiven() throws {
        // The pure function is well covered above and "there is an indicator"
        // is covered beside it; nothing joined the two. Building the group at
        // `.zero`, or handing the wrong rect in, would pass both.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let expected = try XCTUnwrap(ReopenLoadingWindow.activityDotsFrame(
            besideBandOfWidth: 193, inWindowOfSize: window.frame.size))

        XCTAssertEqual(window.activityDots?.frame, expected)
    }

    func testTheIndicatorIsThreeEvenlySpacedDots() throws {
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let dots = try XCTUnwrap(window.activityDots?.layer?.sublayers,
                                 "the indicator carries no layers")

        XCTAssertEqual(dots.count, ReopenLoadingWindow.activityDotCount)
        let diameter = ReopenLoadingWindow.activityDotDiameter
        let pitch = diameter + ReopenLoadingWindow.activityDotGap
        for (step, dot) in dots.enumerated() {
            XCTAssertEqual(dot.frame, NSRect(x: CGFloat(step) * pitch, y: 0,
                                             width: diameter, height: diameter))
            XCTAssertEqual(dot.cornerRadius, diameter / 2, "dot \(step) is not round")
        }
    }

    func testTheDotsAreInkedInTheAppearanceTheWindowWillBeSeenIn() throws {
        // The subtlest line in the whole indicator, and the one with no visible
        // symptom until someone runs a dark theme. `NSAppearance.currentDrawing()`
        // is Aqua outside a drawing context even when `NSApp.appearance` is
        // darkAqua, so resolving `secondaryLabelColor` without pushing this
        // window's own appearance gives the LIGHT variant — black ink on a dark
        // window. Asserted against the role resolved the same way rather than
        // against a literal, so it says "the right variant" and not "this
        // colour".
        // Driven through `NSApp.appearance` and not `window.appearance`,
        // because the ink is chosen inside `init` off `effectiveAppearance` —
        // assigning to the window afterwards would be testing a later state
        // than the one that mattered. That is also how the app itself does it
        // (`ThemeManager` sets `NSApp.appearance`), so this is the production
        // configuration rather than a contrived one.
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            NSApp.appearance = appearance
            let window = ReopenLoadingWindow(frame: NSRect(x: 0, y: 0, width: 1180, height: 742))
            defer { window.close() }
            var wanted: CGColor?
            appearance.performAsCurrentDrawingAppearance {
                wanted = NSColor.secondaryLabelColor.cgColor
            }
            let dots = try XCTUnwrap(window.activityDots?.layer?.sublayers)

            for (step, dot) in dots.enumerated() {
                XCTAssertEqual(dot.backgroundColor, wanted,
                               "dot \(step) is inked for the wrong appearance under \(name.rawValue)")
            }
        }
    }

    func testExactlyOneDotIsLitPerStep() throws {
        // What makes it read as "working" rather than as a blinking warning:
        // each dot is lit for one step of three and each takes a different
        // one, so the light travels.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let dots = try XCTUnwrap(window.activityDots?.layer?.sublayers)
        var litSteps: [Int] = []

        for dot in dots {
            let animation = try XCTUnwrap(
                dot.animation(forKey: ReopenLoadingWindow.activityAnimationKey)
                    as? CAKeyframeAnimation, "a dot is not animating")
            let values = try XCTUnwrap(animation.values as? [Float])
            XCTAssertEqual(values.count, 3)
            let lit = values.indices.filter {
                values[$0] == ReopenLoadingWindow.activityDotLitOpacity
            }
            XCTAssertEqual(lit.count, 1, "\(values) does not light exactly once")
            litSteps.append(lit[0])
            XCTAssertEqual(Set(values).subtracting([ReopenLoadingWindow.activityDotLitOpacity]),
                           [ReopenLoadingWindow.activityDotRestingOpacity],
                           "an unlit step is not the resting opacity")
        }

        XCTAssertEqual(litSteps, [0, 1, 2], "the dots do not light in sequence")
    }

    func testTheIndicatorAdvancesInDiscreteStepsAtTheSettledRate() throws {
        // 🔴 The gate the ring failed, and the whole reason this shape was
        // picked. The cost of an animation on this window is paid per
        // recomposition, not per second it is up: a ring at 60fps for two
        // seconds is ~120 of them and cost 300ms of the page's first frame.
        // Discrete keyframes hold each value until the next key time, so three
        // steps a second is ~6 over the same span.
        //
        // An interpolated animation at this same duration would be back to one
        // per display refresh, which is why the calculation mode is asserted
        // and not just the duration.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        // Ordered in, because that is what `showReopenLoadingWindows` does one
        // line after building this, and it is the first thing that commits the
        // layer tree. Stage 1 shipped a traffic-light correction that was
        // silently undone at order-in and had no test that would have seen it.
        window.orderFrontRegardless()
        let dots = try XCTUnwrap(window.activityDots?.layer?.sublayers)

        for (step, dot) in dots.enumerated() {
            let animation = try XCTUnwrap(
                dot.animation(forKey: ReopenLoadingWindow.activityAnimationKey)
                    as? CAKeyframeAnimation)
            XCTAssertEqual(animation.calculationMode, .discrete,
                           "an interpolated animation recomposites every display frame")
            XCTAssertEqual(Double(animation.values?.count ?? 0) / animation.duration,
                           ReopenLoadingWindow.activityStepsPerSecond, accuracy: 0.0001)
            XCTAssertEqual(animation.repeatCount, .infinity,
                           "a finite indicator would stop while the restore had not")
            // 🔴 The assertion here that is not a formality. Discrete mode
            // wants one more key time than value, and getting it wrong is
            // SILENT on the object: measured against a live render server,
            // three key times for three values makes the last dot never light
            // at all and drops the realized rate to two steps a second, while
            // `calculationMode`, `values` and `duration` all still read
            // exactly as they do above.
            XCTAssertEqual(animation.keyTimes?.map(\.doubleValue),
                           [0, 1.0 / 3.0, 2.0 / 3.0, 1],
                           "dot \(step)'s key times do not bracket its three values")
            // The dots stay in step only because the three animations share a
            // time base. An offset on one would light two at once and leave
            // every other assertion in this file green.
            XCTAssertEqual(animation.beginTime, 0, "dot \(step) starts on its own clock")
            XCTAssertEqual(animation.timeOffset, 0, "dot \(step) is phase-shifted")
            // The whole cost argument is "one animation per dot and no others".
            // Comparing sets of animating LAYERS, as the test below does,
            // cannot see a second animation on a layer that is already expected
            // to have one.
            XCTAssertEqual(dot.animationKeys(), [ReopenLoadingWindow.activityAnimationKey],
                           "dot \(step) carries something besides its rhythm")
        }

        XCTAssertEqual(ReopenLoadingWindow.activityStepsPerSecond, 3,
                       "the rate was settled by a measured sweep; raising it needs another one")
    }

    // MARK: - Nothing else may move

    /// Every distinct layer in `view`'s tree, itself included, that has an
    /// animation attached. Run over the content view AND over the frame view
    /// that contains it: the traffic lights are AppKit's, but this window asked
    /// for them, so an animation on one costs the restore just as much as one
    /// this file added itself.
    private func animatedLayers(under view: NSView) -> [CALayer] {
        var animated: [CALayer] = []
        var seen: Set<ObjectIdentifier> = []
        func visitLayer(_ layer: CALayer) {
            guard seen.insert(ObjectIdentifier(layer)).inserted else { return }
            if !(layer.animationKeys() ?? []).isEmpty { animated.append(layer) }
            for sublayer in layer.sublayers ?? [] { visitLayer(sublayer) }
        }
        func visitView(_ view: NSView) {
            // The two walks overlap and both are needed: a layer-backed
            // subview's layer is already a sublayer of its ancestor's, but a
            // subview of a view with no layer at all is reachable only this
            // way. Hence `seen`.
            if let layer = view.layer { visitLayer(layer) }
            for subview in view.subviews { visitView(subview) }
        }
        visitView(view)
        return animated
    }

    func testTheIndicatorIsTheOnlyThingThatAnimates() throws {
        // This used to assert zero, and the zero was the gate that kept the
        // ring out. It is now an equality against the three dots instead,
        // which keeps the gate: anything else that starts animating in here —
        // an implicit action on the band's layer, an AppKit fade, a second
        // indicator — fails this just as a ring would.
        //
        // Built WITH a band on purpose: a bare `CALayer` given a frame and a
        // colour animates both by default, so the dots and the band each had
        // to be built in a way that leaves nothing implicit attached.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let dots = try XCTUnwrap(window.activityDots?.layer?.sublayers)

        XCTAssertEqual(Set(animatedLayers(under: content).map(ObjectIdentifier.init)),
                       Set(dots.map(ObjectIdentifier.init)),
                       "something other than the indicator's dots is animating")
        // The other half of "nothing else moves": AppKit's default fade-in
        // would spend the first frames of the one opportunity this window has
        // being invisible.
        XCTAssertEqual(window.animationBehavior, .none)
    }

    func testNothingInItsTitlebarAnimatesEither() throws {
        // The traffic lights live in AppKit's frame view, which the test above
        // never visits. An earlier version of this called the frame view a
        // SIBLING of the content view and asserted a flat zero on it; it is
        // the content view's PARENT, so the walk is a superset and the
        // indicator's own dots came back through it the moment they existed.
        // The titlebar's own contribution is what is left once they are taken
        // out, and that is what has to be zero.
        //
        // Not evidence that drawing the lights is free: that is a whole-system
        // question, answered by an interleaved A/B on the real reopen and
        // recorded in the ticket. This only says nothing up there is animating.
        let window = self.window(sidebarWidth: 193)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(content.superview,
                                      "no frame view: the titlebar is not there to check")
        let inFrame = Set(animatedLayers(under: frameView).map(ObjectIdentifier.init))
        let inContent = Set(animatedLayers(under: content).map(ObjectIdentifier.init))

        XCTAssertFalse(inContent.isEmpty,
                       "nothing was animating at all, so the subtraction proves nothing")
        XCTAssertEqual(inFrame.subtracting(inContent), [],
                       "an animation here costs the restore it is covering")
    }

    func testFillsWithTheBackgroundTheBrowserWindowGivesItself() {
        // The other half of the two-tone split: the band covers the sidebar,
        // and everything to the right of it is this colour, which is the
        // literal value `SpaceSessionController.setupWindow` assigns —
        // shared so that the rect the loading window holds is already the
        // colour the restored window arrives in. Light and dark cannot diverge
        // between the two: both resolve it against one app-wide preference
        // (`ThemeManager.userAppearanceChoice`, which sets `NSApp.appearance`
        // and is also what the browser window's own `window.appearance` is
        // built from). The one window that overrides it — Incognito, forced
        // dark — is never a reopen target, because Incognito Spaces are dropped
        // from the restore snapshot wholesale.
        let window = self.window()
        defer { window.close() }

        XCTAssertEqual(window.backgroundColor, NSColor.windowBackgroundColor)
        XCTAssertTrue(window.isOpaque, "a translucent cover would show the app underneath")
    }
}

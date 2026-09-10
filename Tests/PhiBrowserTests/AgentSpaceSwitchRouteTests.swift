// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// An agent task operates one Chromium window, spawned hidden into the slot
/// (user-perceived window) that was key when the task started. That slot
/// alone presents the agent Space — its strip, picker, menu rows and
/// ⌃-cycling offer the pip; every other window's do not — and a switch that
/// resolves against another slot (the handoff prompt, autoview, a CDP or
/// AppleScript activate) surfaces the Space in its own window rather than
/// moving the window there.
///
/// The rule used to be an inline adoption: the other slot evicted the window
/// and registered it as its own, which — once the user had surfaced the agent
/// Space in the hosting window — left that window with nothing on screen and
/// a stale slot back-pointer. Pinning the route by table keeps a later
/// "just adopt it" from creeping back in.
///
/// What the table cannot reach: that `SpaceWindowSlot.activate` consults it
/// ahead of every side effect, that `presents` reads the same answer, and that
/// `slotHostingWindow` counts an in-flight spawn as hosting. Those rest on the
/// comments at each site; building a `SpaceManager` here is not something this
/// suite can do (`SlotRestoreFrameTests` draws the same line).
final class AgentSpaceSwitchRouteTests: XCTestCase {
    private func route(
        hostsWindowHere: Bool = false,
        anotherSlotHostsWindow: Bool = false,
        anotherSlotIsSpawning: Bool = false
    ) -> SpaceManager.AgentSpaceSwitchRoute {
        SpaceManager.agentSpaceSwitchRoute(
            hostsWindowHere: hostsWindowHere,
            anotherSlotHostsWindow: anotherSlotHostsWindow,
            anotherSlotIsSpawning: anotherSlotIsSpawning
        )
    }

    func testHostingSlotSwitchesLocally() {
        XCTAssertEqual(route(hostsWindowHere: true), .local)
    }

    func testHostingSlotWinsEvenIfAnotherSlotClaimsTheWindow() {
        // Two hosts cannot happen — a window registers into one map — but the
        // asking slot's own claim must never be redirected away from itself.
        XCTAssertEqual(
            route(hostsWindowHere: true, anotherSlotHostsWindow: true),
            .local
        )
    }

    func testWindowHostedElsewhereSurfacesInThatSlot() {
        XCTAssertEqual(route(anotherSlotHostsWindow: true), .surfaceInHost)
    }

    func testSpawnInFlightElsewhereIsDropped() {
        XCTAssertEqual(route(anotherSlotIsSpawning: true), .dropWhileSpawning)
    }

    func testRegisteredWindowOutranksSpawnClaim() {
        XCTAssertEqual(
            route(anotherSlotHostsWindow: true, anotherSlotIsSpawning: true),
            .surfaceInHost
        )
    }

    func testUnhostedAgentSpaceSpawnsLocally() {
        // A persistent agent Space between tasks: no window anywhere, so the
        // slot that activates it spawns one, exactly as before.
        XCTAssertEqual(route(), .local)
    }
}

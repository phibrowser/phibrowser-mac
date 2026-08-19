// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The slot restore snapshot remembers where a slot's window sat, so a reopen
/// has a position on hand before Chromium reports the restored window's bounds.
/// The display that frame was saved against may be gone, smaller, or rearranged
/// by then, so it is read back through a clamp — and the same clamp repairs a
/// live slot after a screen-layout change, which is what keeps the two agreeing.
///
/// These pin the clamp's rule down by table. It is deliberately far weaker than
/// AppKit's own constraint: a frame the user dragged half off an edge stays
/// there, and only the states they cannot get out of are corrected. The last
/// section covers what the remembered geometry is FOR on the spawn side: a slot
/// minted for a saved entry opens its first window itself, and takes that
/// window's sidebar from what the record kept rather than from a window it does
/// not have.
final class SlotRestoreFrameTests: XCTestCase {
    // A 1440x900 laptop display at the origin, menu bar removed.
    private let primary = SpaceManager.ScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 862)
    )
    // A larger display placed to the right of the primary.
    private let secondary = SpaceManager.ScreenGeometry(
        frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )

    // MARK: - Frames that must survive untouched

    func testLeavesAFrameThatStillFitsItsWorkAreaExactlyWhereItIs() {
        let frame = NSRect(x: 200, y: 100, width: 900, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            frame
        )
    }

    func testKeepsAFrameStraddlingTwoDisplaysWhereTheUserPutIt() {
        // 100pt on the primary, 700pt on the secondary: the secondary hosts it,
        // and it fits there, so straddling the seam is not a state to repair.
        let frame = NSRect(x: 1340, y: 100, width: 800, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            frame
        )
    }

    func testLeavesAScreenSizedFrameAlone() {
        // A frame covering a whole display is a fullscreen frame — macOS
        // resizes those itself, and pulling it into the work area would drag a
        // fullscreen window down by the height of the menu bar.
        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(primary.frame, toScreens: [primary, secondary]),
            primary.frame
        )
    }

    func testReturnsTheFrameUnchangedWhenNoDisplayIsAttached() {
        // Clamshell, or every display asleep. There is nothing to clamp to, and
        // the clamp must still answer with a frame.
        let frame = NSRect(x: 200, y: 100, width: 900, height: 600)

        XCTAssertEqual(SpaceManager.clampedSlotFrame(frame, toScreens: []), frame)
    }

    // MARK: - Frames that have to be brought back

    func testPullsAFrameBackToTheRemainingDisplayWhenItsOwnIsUnplugged() {
        // Saved on the secondary; only the primary is attached now.
        let frame = NSRect(x: 1800, y: 200, width: 900, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary]),
            // Top-left of the surviving work area, at its saved size.
            NSRect(x: 0, y: 262, width: 900, height: 600)
        )
    }

    func testShrinksAFrameTooLargeForTheDisplayItComesBackOn() {
        let smallDisplay = SpaceManager.ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 700)
        )
        let frame = NSRect(x: 50, y: 400, width: 1600, height: 1000)

        // Shrunk to the work area and dropped until its top edge fits. The x
        // origin is deliberately NOT pulled in: 50 + 1280 overhangs the right
        // edge, and an overhang the user can still grab is not a state to
        // repair.
        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [smallDisplay]),
            NSRect(x: 50, y: 0, width: 1280, height: 700)
        )
    }

    func testRehomesAFrameThatLandsOnNoDisplayAtAll() {
        // Off to the left and below everything — no work area to grab.
        let frame = NSRect(x: -3000, y: -2000, width: 800, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            // The first listed display is the primary, so a homeless frame
            // always lands there rather than on whichever display sorts first.
            NSRect(x: 0, y: 262, width: 800, height: 600)
        )
    }

    // MARK: - Reading a stored frame back

    func testReadsNoFrameFromASnapshotEntryWrittenBeforeTheFieldExisted() {
        XCTAssertNil(SpaceManager.decodedSlotFrame(nil))
        // And nothing usable from an entry whose value is not even a string.
        XCTAssertNil(SpaceManager.decodedSlotFrame(42))
    }

    func testReadsNoFrameFromAnUnparseableValue() {
        XCTAssertNil(SpaceManager.decodedSlotFrame("not a rect"))
        // A zero rect is what an unreadable string decodes to, and is not a
        // frame any window ever had.
        XCTAssertNil(SpaceManager.decodedSlotFrame(NSStringFromRect(.zero)))
    }

    func testRoundTripsAFrameThroughItsStoredForm() {
        let frame = NSRect(x: 320, y: 148, width: 1180, height: 742)

        XCTAssertEqual(SpaceManager.decodedSlotFrame(NSStringFromRect(frame)), frame)
    }

    // MARK: - The rest of what the loading window is drawn from

    // The frame says where the window goes; these two say what it looks like.
    // Both are measured off the live window at persist time rather than derived
    // from anything on this side, which is the point: the sidebar's width is a
    // user setting no reopen can ask for with no window open, and the traffic
    // lights' origin belongs to the Chromium fork's own frame view.

    /// `value` after a real trip through the property list the snapshot is
    /// stored in.
    ///
    /// Boxing a literal into `Any` is NOT the same thing, and the first version
    /// of these tests found that out: a Swift `Int` in an `Any` fails
    /// `as? Double`, while the `NSNumber` a plist hands back does not. That
    /// made the collapsed case red for a real reason — the decoder would have
    /// answered "no remembered width" for every collapsed sidebar — and made
    /// the negative case green for a wrong one.
    private func throughAPropertyList(_ value: Any) throws -> Any {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["v": value], format: .binary, options: 0)
        let read = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        return try XCTUnwrap(read?["v"], "the value did not survive the plist")
    }

    func testReadsNoSidebarWidthFromASnapshotWrittenBeforeTheFieldExisted() throws {
        XCTAssertNil(SpaceManager.decodedSidebarWidth(nil))
        // Or from a value that is not a number at all.
        XCTAssertNil(SpaceManager.decodedSidebarWidth(try throughAPropertyList("193")))
    }

    func testReadsNoSidebarWidthFromAnImpossibleValue() throws {
        XCTAssertNil(SpaceManager.decodedSidebarWidth(try throughAPropertyList(-1)))
        // Non-finite doubles DO survive a plist, measured — the write side
        // refuses them too, and this is the other end of that.
        XCTAssertNil(SpaceManager.decodedSidebarWidth(try throughAPropertyList(Double.nan)))
        XCTAssertNil(SpaceManager.decodedSidebarWidth(try throughAPropertyList(Double.infinity)))
    }

    func testReadsACollapsedSidebarBackAsZeroRatherThanAsAbsent() throws {
        // Zero is a value, not a gap: it is how a collapsed sidebar is
        // recorded, and how `.comfortable` — which keeps it collapsed — is
        // recorded too. Absent means "this snapshot predates the field", which
        // is a different thing and only one of the two may invent a width
        // later (neither does).
        XCTAssertEqual(SpaceManager.decodedSidebarWidth(try throughAPropertyList(Double(0))), 0)
    }

    func testRoundTripsASidebarWidthThroughItsStoredForm() throws {
        XCTAssertEqual(
            SpaceManager.decodedSidebarWidth(try throughAPropertyList(Double(193.5))),
            193.5)
    }

    func testReadsNoTrafficLightOriginFromASnapshotWrittenBeforeTheFieldExisted() throws {
        XCTAssertNil(SpaceManager.decodedTrafficLightOrigin(nil))
        XCTAssertNil(SpaceManager.decodedTrafficLightOrigin(try throughAPropertyList(13)))
    }

    func testReadsNoTrafficLightOriginFromAnUnparseableValue() throws {
        XCTAssertNil(SpaceManager.decodedTrafficLightOrigin(
            try throughAPropertyList("not a point")))
        // The zero point is what an unreadable string decodes to, and no
        // window's leading light has ever sat on its own frame corner.
        XCTAssertNil(SpaceManager.decodedTrafficLightOrigin(
            try throughAPropertyList(NSStringFromPoint(.zero))))
    }

    func testReadsNoTrafficLightOriginFromAHalfReadableOne() throws {
        // `NSPointFromString` does not fail — it fills in what it managed and
        // zeroes the rest, or overflows to an infinity. Both were measured
        // going straight through to the lights: `{inf, 0}` puts the close
        // button at x = 1.7e13, and `{13, 0}` puts the group 13.5pt above the
        // restored window's, which is the hand-off jump this route exists to
        // remove. Neither is "unparseable" by any test the decoder can make on
        // the string, so the filter is on the value.
        for junk in ["{13, junk}", "{1e400, 0}", "{-5000, -5000}", "{13, 5000}"] {
            XCTAssertNil(SpaceManager.decodedTrafficLightOrigin(
                try throughAPropertyList(junk)), "accepted \(junk)")
        }
    }

    func testRoundTripsATrafficLightOriginThroughItsStoredForm() throws {
        let origin = NSPoint(x: 13, y: 13.5)

        XCTAssertEqual(
            SpaceManager.decodedTrafficLightOrigin(
                try throughAPropertyList(NSStringFromPoint(origin))),
            origin)
    }

    // MARK: - What a spawn inherits when the slot has no window to read

    /// The remembered geometry above is not only what a loading window is
    /// drawn from: a slot minted for a saved entry SPAWNS its first window,
    /// and a spawn takes its frame and its sidebar from the slot rather than
    /// from the record (`SpaceWindowSlot.seedRememberedGeometry` seeds the one
    /// from the other). With nothing seeded the window landed on Chromium's
    /// own `browser.window_placement` instead of where the user left it.
    ///
    /// The frame half is a pass-through of a value already pinned above. The
    /// sidebar half is a rule: the record stores one number, and that number
    /// has to settle the width AND the collapsed state, with a third answer
    /// for a record that stores nothing.

    func testALiveWindowStillAnswersForTheSpawnsSidebar() {
        // Unchanged behaviour: while the slot has a window to leave, what it
        // is showing wins over anything the record remembers.
        XCTAssertEqual(
            SpaceWindowSlot.spawnSidebarShape(liveWidth: 240,
                                              liveCollapsed: false,
                                              rememberedWidth: 300),
            SpaceWindowSlot.SpawnSidebarShape(width: 240, collapsed: false))
    }

    func testALiveCollapsedSidebarIsNotReopenedByARememberedWidth() {
        XCTAssertEqual(
            SpaceWindowSlot.spawnSidebarShape(liveWidth: 0,
                                              liveCollapsed: true,
                                              rememberedWidth: 300),
            SpaceWindowSlot.SpawnSidebarShape(width: 0, collapsed: true))
    }

    func testARememberedWidthAnswersWhenNoWindowIsLeaving() {
        XCTAssertEqual(
            SpaceWindowSlot.spawnSidebarShape(liveWidth: nil,
                                              liveCollapsed: nil,
                                              rememberedWidth: 300),
            SpaceWindowSlot.SpawnSidebarShape(width: 300, collapsed: false))
    }

    func testARememberedZeroIsACollapsedSidebarAndNotAMissingOne() {
        // Same distinction the decoder makes above, carried through to the
        // window: a collapsed sidebar comes back collapsed rather than at some
        // invented width.
        XCTAssertEqual(
            SpaceWindowSlot.spawnSidebarShape(liveWidth: nil,
                                              liveCollapsed: nil,
                                              rememberedWidth: 0),
            SpaceWindowSlot.SpawnSidebarShape(width: 0, collapsed: true))
    }

    func testRememberingNothingLeavesTheNewWindowsSidebarAlone() {
        // A record written before the width existed. `registerWindow` syncs
        // nothing without a collapsed answer, so nil is what keeps such a
        // reopen behaving exactly as it did.
        XCTAssertEqual(
            SpaceWindowSlot.spawnSidebarShape(liveWidth: nil,
                                              liveCollapsed: nil,
                                              rememberedWidth: nil),
            SpaceWindowSlot.SpawnSidebarShape(width: 0, collapsed: nil))
    }
}

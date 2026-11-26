// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The sidebar toggle's state: what a request changes, what a reversal
/// starts from, and which flight still counts when it lands.
final class SidebarTransitionsTests: XCTestCase {
    private let duration = SidebarToggleAnimation.duration

    func testAnImmediateRequestChangesTheStateWithNoFlight() {
        var transitions = SidebarTransitions(isCollapsed: false)
        let outcome = transitions.request(collapsed: true, duration: nil, shownFraction: 1)
        XCTAssertTrue(outcome.changed)
        XCTAssertNil(outcome.flight)
        XCTAssertNil(outcome.ended)
        XCTAssertTrue(transitions.isCollapsed)
        XCTAssertNil(transitions.flight)
        XCTAssertFalse(transitions.columnTakesPageSpace)
    }

    func testARequestForTheCurrentStateChangesNothing() {
        var transitions = SidebarTransitions(isCollapsed: true)
        XCTAssertEqual(transitions.request(collapsed: true, duration: duration, shownFraction: 0),
                       SidebarTransitions.Outcome())
        XCTAssertEqual(transitions.request(collapsed: true, duration: nil, shownFraction: 0),
                       SidebarTransitions.Outcome())
    }

    /// The state changes when the flight starts; the page area keeps the
    /// whole container until an expansion lands.
    func testAnAnimatedExpansionIsAFlightUntilItLands() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        let outcome = transitions.request(collapsed: false, duration: duration, shownFraction: 0)
        let flight = try XCTUnwrap(outcome.flight)
        XCTAssertTrue(outcome.changed)
        XCTAssertFalse(flight.collapsing)
        XCTAssertEqual(flight.startFraction, 0)
        XCTAssertEqual(flight.endFraction, 1)
        XCTAssertEqual(flight.duration, duration, accuracy: 0.0001)
        XCTAssertFalse(transitions.isCollapsed)
        XCTAssertTrue(transitions.isExpanding)
        XCTAssertFalse(transitions.columnTakesPageSpace)

        XCTAssertEqual(transitions.land(flight.id), flight)
        XCTAssertFalse(transitions.isExpanding)
        XCTAssertTrue(transitions.columnTakesPageSpace)
        XCTAssertNil(transitions.land(flight.id), "it lands once")
    }

    func testAnAnimatedCollapseGivesThePageTheContainerAtItsStart() throws {
        var transitions = SidebarTransitions(isCollapsed: false)
        XCTAssertTrue(transitions.columnTakesPageSpace)
        let flight = try XCTUnwrap(transitions.request(collapsed: true, duration: duration, shownFraction: 1).flight)
        XCTAssertTrue(flight.collapsing)
        XCTAssertFalse(transitions.isExpanding)
        XCTAssertFalse(transitions.columnTakesPageSpace)
        XCTAssertNotNil(transitions.land(flight.id))
        XCTAssertFalse(transitions.columnTakesPageSpace)
    }

    /// A reversal starts from wherever the column shows, takes the share of
    /// the duration that distance is of the whole, and needs no page layout:
    /// the page area has the container throughout.
    func testAReversalStartsFromWhereTheColumnIs() throws {
        for shown: CGFloat in [0.1, 0.25, 0.5, 0.9] {
            var transitions = SidebarTransitions(isCollapsed: false)
            let collapse = try XCTUnwrap(
                transitions.request(collapsed: true, duration: duration, shownFraction: 1).flight)

            let outcome = transitions.request(collapsed: false, duration: duration, shownFraction: shown)
            let expansion = try XCTUnwrap(outcome.flight)
            XCTAssertEqual(outcome.ended, collapse)
            XCTAssertFalse(outcome.endedAtItsTarget, "the collapse was cut short")
            XCTAssertEqual(expansion.startFraction, shown, "no jump at \(shown)")
            XCTAssertEqual(expansion.duration, duration * TimeInterval(1 - shown), accuracy: 0.0001)
            XCTAssertFalse(transitions.isCollapsed)
            XCTAssertTrue(transitions.isExpanding)
            XCTAssertFalse(transitions.columnTakesPageSpace)

            XCTAssertNil(transitions.land(collapse.id), "the superseded flight's end changes nothing")
            XCTAssertTrue(transitions.isExpanding)

            let back = transitions.request(collapsed: true, duration: duration, shownFraction: shown)
            XCTAssertEqual(back.ended, expansion)
            XCTAssertEqual(try XCTUnwrap(back.flight).duration, duration * TimeInterval(shown), accuracy: 0.0001)
            XCTAssertFalse(transitions.isExpanding, "a superseded expansion is over")
            XCTAssertNil(transitions.land(expansion.id))
            XCTAssertFalse(transitions.columnTakesPageSpace)
        }
    }

    /// Any number of toggles ends in the state the last one asked for, with
    /// one flight up: the last.
    func testRapidTogglesEndInTheLastStateAsked() throws {
        for count in [1, 2, 3, 8, 9] {
            var transitions = SidebarTransitions(isCollapsed: false)
            var flights: [SidebarTransitions.Flight] = []
            var ended: [SidebarTransitions.Flight] = []
            for index in 0..<count {
                let outcome = transitions.request(collapsed: index.isMultiple(of: 2), duration: duration,
                                                  shownFraction: 0.5)
                XCTAssertTrue(outcome.changed)
                XCTAssertFalse(outcome.endedAtItsTarget)
                flights.append(try XCTUnwrap(outcome.flight))
                if let flight = outcome.ended { ended.append(flight) }
            }
            XCTAssertEqual(ended, Array(flights.dropLast()), "\(count): each flight but the last was cut short once")
            XCTAssertEqual(Set(flights.map(\.id)).count, count)
            XCTAssertEqual(transitions.isCollapsed, !count.isMultiple(of: 2))
            XCTAssertEqual(transitions.flight, flights.last)

            for flight in flights.dropLast() {
                XCTAssertNil(transitions.land(flight.id))
            }
            XCTAssertEqual(transitions.land(try XCTUnwrap(flights.last).id), flights.last)
            XCTAssertNil(transitions.flight)
            XCTAssertEqual(transitions.columnTakesPageSpace, count.isMultiple(of: 2))
        }
    }

    /// An immediate request for the state a flight is heading to lands it.
    func testAnImmediateRequestForTheSameStateLandsTheFlight() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        let flight = try XCTUnwrap(transitions.request(collapsed: false, duration: duration, shownFraction: 0).flight)
        let outcome = transitions.request(collapsed: false, duration: nil, shownFraction: 0.4)
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(outcome.ended, flight)
        XCTAssertTrue(outcome.endedAtItsTarget)
        XCTAssertNil(transitions.flight)
        XCTAssertTrue(transitions.columnTakesPageSpace)
    }

    /// An animated request for that state leaves the flight alone.
    func testAnAnimatedRequestForTheSameStateLeavesTheFlightUp() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        let flight = try XCTUnwrap(transitions.request(collapsed: false, duration: duration, shownFraction: 0).flight)
        XCTAssertEqual(transitions.request(collapsed: false, duration: duration, shownFraction: 0.4),
                       SidebarTransitions.Outcome())
        XCTAssertEqual(transitions.flight, flight)
    }

    func testAnImmediateRequestForTheOtherStateCutsTheFlightShort() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        let flight = try XCTUnwrap(transitions.request(collapsed: false, duration: duration, shownFraction: 0).flight)
        let outcome = transitions.request(collapsed: true, duration: nil, shownFraction: 0.4)
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.ended, flight)
        XCTAssertFalse(outcome.endedAtItsTarget)
        XCTAssertNil(outcome.flight)
        XCTAssertTrue(transitions.isCollapsed)
        XCTAssertFalse(transitions.isExpanding)
    }

    func testSettlingLandsWhateverIsUp() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        XCTAssertNil(transitions.settle())
        let flight = try XCTUnwrap(transitions.request(collapsed: false, duration: duration, shownFraction: 0).flight)
        XCTAssertEqual(transitions.settle(), flight)
        XCTAssertNil(transitions.flight)
        XCTAssertFalse(transitions.isCollapsed)
        XCTAssertTrue(transitions.columnTakesPageSpace)
    }

    func testAFractionOutOfRangeIsTakenAsTheNearestEnd() throws {
        var transitions = SidebarTransitions(isCollapsed: true)
        let flight = try XCTUnwrap(transitions.request(collapsed: false, duration: duration, shownFraction: 1.3).flight)
        XCTAssertEqual(flight.startFraction, 1)
        XCTAssertEqual(flight.duration, 0)
    }
}

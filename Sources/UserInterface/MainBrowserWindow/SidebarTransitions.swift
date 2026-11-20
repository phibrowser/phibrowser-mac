// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The sidebar column's collapsed state and the toggle on its way there.
///
/// The collapsed state is the one last asked for: it changes when a toggle
/// starts, not when it lands. An animated toggle is a flight, which lasts
/// until its owner lands it. A request for the other state while a flight is
/// up supersedes it: the new flight starts from wherever the column is
/// showing, so any number of rapid toggles ends in the state the last one
/// asked for, with the column never jumping.
struct SidebarTransitions {
    struct Flight: Equatable {
        let id: Int
        let collapsing: Bool
        /// How much of the column showed when the flight began: 1 for all
        /// of it, 0 for none.
        let startFraction: CGFloat
        /// The toggle's duration scaled to the distance left to cover.
        let duration: TimeInterval

        var endFraction: CGFloat { collapsing ? 0 : 1 }
    }

    struct Outcome: Equatable {
        /// Whether the collapsed state changed.
        var changed = false
        /// The flight this request ended early.
        var ended: Flight?
        /// Whether `ended` got where it was going: true when it was cut
        /// short by a request for the same state, false when superseded by
        /// one for the other.
        var endedAtItsTarget = false
        /// The flight to run now, if the request was animated.
        var flight: Flight?
    }

    private(set) var isCollapsed: Bool
    private(set) var flight: Flight?
    private var lastFlightID = 0

    init(isCollapsed: Bool) {
        self.isCollapsed = isCollapsed
    }

    /// An animated expansion has started and not landed.
    var isExpanding: Bool { flight?.collapsing == false }

    /// Whether the column takes its width from the page area. The page area
    /// keeps the container's full width while the column is collapsed and
    /// for the whole of a flight in either direction, so a toggle changes
    /// the page area's size once, a collapse when it starts and an expansion
    /// when it lands, and a reversal not at all.
    var columnTakesPageSpace: Bool { !isCollapsed && flight == nil }

    /// Asks for `collapsed`. `duration` is a whole toggle's, nil for a
    /// change that applies at once; `shownFraction` is how much of the
    /// column shows right now.
    mutating func request(collapsed: Bool, duration: TimeInterval?, shownFraction: CGFloat) -> Outcome {
        var outcome = Outcome()
        guard collapsed != isCollapsed else {
            // Already heading there; only an immediate request changes
            // anything, by landing the flight now.
            if duration == nil, let flight {
                self.flight = nil
                outcome.ended = flight
                outcome.endedAtItsTarget = true
            }
            return outcome
        }
        outcome.changed = true
        outcome.ended = flight
        isCollapsed = collapsed
        guard let duration else {
            flight = nil
            return outcome
        }
        lastFlightID += 1
        let start = min(max(shownFraction, 0), 1)
        let end: CGFloat = collapsed ? 0 : 1
        let next = Flight(id: lastFlightID, collapsing: collapsed, startFraction: start,
                          duration: duration * TimeInterval(abs(end - start)))
        flight = next
        outcome.flight = next
        return outcome
    }

    /// Lands the flight `id`. Returns nil when it is no longer the one up:
    /// a superseded flight's end changes nothing.
    mutating func land(_ id: Int) -> Flight? {
        guard let flight, flight.id == id else { return nil }
        self.flight = nil
        return flight
    }

    /// Lands whatever flight is up, now.
    mutating func settle() -> Flight? {
        defer { flight = nil }
        return flight
    }
}

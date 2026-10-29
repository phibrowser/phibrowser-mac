// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins the gate in front of a windowless open the user aimed at a Space
/// (`SpaceManager.windowlessOpenGate`, chromium ADR 0020). Which entries go
/// through the gate, and the three exits that release what it holds, rest on
/// the call sites.
final class WindowlessOpenRestoreGateTests: XCTestCase {
    func testEveryInputCombination() {
        typealias Gate = SpaceManager.WindowlessOpenGate
        let table: [(inFlight: Bool, windowless: Bool, switchOn: Bool,
                     expected: Gate)] = [
            // A restore in flight holds the open whatever else is true, even
            // once a restored window has arrived: the target Space's window
            // can come after the first one, and an armed lazy restore drops
            // Space switches until it settles.
            (true, true, true, .waitForRestore),
            (true, true, false, .waitForRestore),
            (true, false, true, .waitForRestore),
            (true, false, false, .waitForRestore),
            // The defect: windowless with the switch on, the open spawned a
            // bare window and the user's windows did not come back.
            (false, true, true, .beginRestoreAndWait),
            // The switch off: a plain window, as a Dock click opens.
            (false, true, false, .runNow),
            // A window is open: nothing to restore.
            (false, false, true, .runNow),
            (false, false, false, .runNow),
        ]
        for row in table {
            XCTAssertEqual(
                SpaceManager.windowlessOpenGate(
                    isSessionRestoreInFlight: row.inFlight,
                    isWindowlessWithHostedSlots: row.windowless,
                    isRestoreSwitchOn: row.switchOn),
                row.expected,
                "inFlight=\(row.inFlight) windowless=\(row.windowless) "
                    + "switchOn=\(row.switchOn)")
        }
    }
}

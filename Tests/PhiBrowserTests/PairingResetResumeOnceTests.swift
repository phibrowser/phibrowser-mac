// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// `PairingResetResumeOnce`, the timeout guard of the pairing reset's Space deletion
/// (docs/sync.md, "Replacing this Mac's data at pairing"): a timeout before the commit abandons the
/// operation, a commit claimed first keeps it alive, and a normal resume cancels the timer.
@MainActor
final class PairingResetResumeOnceTests: XCTestCase {
    func testATimeoutBeforeTheCommitAbandonsTheOperation() async {
        let once = PairingResetResumeOnce<String>()
        var abandoned = 0
        let value = await withCheckedContinuation { continuation in
            once.arm(continuation, timeout: .milliseconds(20), timeoutValue: "timedOut",
                     onAbandon: { abandoned += 1 })
        }
        XCTAssertEqual(value, "timedOut")
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(once.isAbandoned)
        XCTAssertFalse(once.beginCommit(), "a late callback must not commit")
        once.resume("late")   // ignored: the caller was already resumed
        XCTAssertEqual(abandoned, 1)
    }

    func testACommitClaimedBeforeTheTimeoutIsNotAbandoned() async {
        let once = PairingResetResumeOnce<String>()
        var abandoned = 0
        let value = await withCheckedContinuation { continuation in
            once.arm(continuation, timeout: .milliseconds(20), timeoutValue: "timedOut",
                     onAbandon: { abandoned += 1 })
            XCTAssertTrue(once.beginCommit())
        }
        XCTAssertEqual(value, "timedOut", "the caller still gets the timeout value")
        XCTAssertEqual(abandoned, 0, "a committing operation keeps its pending mark")
        XCTAssertFalse(once.isAbandoned)
    }

    func testANormalResumeCancelsTheTimer() async throws {
        let once = PairingResetResumeOnce<String>()
        var abandoned = 0
        let value = await withCheckedContinuation { continuation in
            once.arm(continuation, timeout: .milliseconds(20), timeoutValue: "timedOut",
                     onAbandon: { abandoned += 1 })
            once.resume("deleted")
        }
        XCTAssertEqual(value, "deleted")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(abandoned, 0, "the cancelled timer never abandons")
        XCTAssertFalse(once.isAbandoned)
    }
}

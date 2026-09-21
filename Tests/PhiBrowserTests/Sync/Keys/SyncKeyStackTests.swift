import XCTest
@testable import Phi

/// PR #145 review P1 ("bind key API requests to the stack's account identity"). The stack's
/// token provider is bound to the account it was built for: a key flow suspended across a
/// sign-out of A and a sign-in as B must not resume with B's bearer token and A's key
/// material. The binding compares account ids, so a renewed token for the same account still
/// passes, and a stack built with no account (the signed-out Devices pane) is unbound.
final class SyncKeyStackTests: XCTestCase {
    func testABoundStackGetsTheTokenOnlyWhileItsAccountIsSignedIn() {
        XCTAssertEqual(SyncKeyStack.boundToken(stackAccountId: "auth0|alice", currentAccountId: "auth0|alice",
                                               token: "t1"), "t1")
        XCTAssertEqual(SyncKeyStack.boundToken(stackAccountId: "auth0|alice", currentAccountId: "auth0|alice",
                                               token: "t2-renewed"), "t2-renewed",
                       "token renewal within the same account passes")
        XCTAssertNil(SyncKeyStack.boundToken(stackAccountId: "auth0|alice", currentAccountId: "auth0|bob",
                                             token: "bobs-token"),
                     "another account's token never rides a stack built for alice")
        XCTAssertNil(SyncKeyStack.boundToken(stackAccountId: "auth0|alice", currentAccountId: nil,
                                             token: "stale"),
                     "signed out: nothing may be sent for alice's stack")
    }

    func testAnUnboundStackPassesTheTokenThrough() {
        XCTAssertEqual(SyncKeyStack.boundToken(stackAccountId: nil, currentAccountId: "auth0|alice",
                                               token: "t1"), "t1")
        XCTAssertNil(SyncKeyStack.boundToken(stackAccountId: nil, currentAccountId: nil, token: nil))
    }
}

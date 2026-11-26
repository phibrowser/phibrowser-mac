import CryptoKit
import XCTest
@testable import Phi

/// PHI-2002 C1: starting sync over from a Mac that is not set up for sync (docs/sync.md,
/// "Starting over from a Mac that is not set up for sync"). The setup model against an in-memory
/// key API, journal and sign-in; no network, Auth0 or account defaults.
@MainActor
final class KeyLayerResetRequestTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI

    /// The account-defaults journal, in memory.
    final class MemoryJournal {
        var data: Data?
        var failWrites = false
        lazy var store = SyncResetRequestJournalStore(
            readData: { [unowned self] in self.data },
            writeData: { [unowned self] value in
                guard !self.failWrites else { return false }
                self.data = value
                return true
            })
    }

    /// Scripted fresh sign-ins, consumed in order; every call is counted.
    final class SignIns {
        var results: [InteractiveReauthenticationResult]
        var calls = 0
        var cancels = 0
        init(_ results: [InteractiveReauthenticationResult]) { self.results = results }
        func next() -> InteractiveReauthenticationResult {
            calls += 1
            return results.isEmpty ? .signedIn : results.removeFirst()
        }
    }

    struct Fixture {
        let api: FakeAPI
        let provider: AccountKeyManagerTests.FakeDeviceKeyProvider
        let manager: AccountKeyManager
        let journal: MemoryJournal
        let signIns: SignIns
        let model: KeyLayerViewModel
    }

    private func pending(_ operation: UUID, executeAfter: Date = Date().addingTimeInterval(48 * 3600),
                         status: String = "pending") -> ResetRequestDTO {
        ResetRequestDTO(operationId: operation.uuidString.lowercased(), status: status,
                        createdAt: Date(), executeAfter: executeAfter, joinRequestId: "reset-join")
    }

    /// An account that exists on the server while this Mac holds no envelope (`.needsJoin`).
    private func makeFixture(signIns: [InteractiveReauthenticationResult] = [],
                             journal: MemoryJournal = MemoryJournal(),
                             accountExists: Bool = true,
                             api: FakeAPI = FakeAPI(),
                             provider: AccountKeyManagerTests.FakeDeviceKeyProvider = .init()) async throws -> Fixture {
        if accountExists, api.account == nil {
            _ = try await api.putAccount(salt: Data(count: 16), kdfVersion: "v1",
                                         kdfParams: Data("{}".utf8), recoveryEnvelope: Data([1]))
        }
        let manager = AccountKeyManager(api: api, deviceKeyProvider: provider,
                                        pendingRegistrations: AccountKeyManagerTests.MemoryPendingRegistrations())
        let log = SignIns(signIns)
        let model = KeyLayerViewModel(manager: manager, beginEnrollment: {},
                                      recoveryConfirmationRequired: { false },
                                      setRecoveryConfirmationRequired: { _ in },
                                      resetJournal: journal.store,
                                      reauthenticate: { log.next() },
                                      cancelReauthentication: { log.cancels += 1 })
        return Fixture(api: api, provider: provider, manager: manager, journal: journal, signIns: log, model: model)
    }

    /// From the join-method page through the explanation's Continue.
    private func requestStartOver(_ f: Fixture) async {
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .chooseJoinMethod)
        f.model.showStartOver()
        XCTAssertEqual(f.model.phase, .resetExplanation)
        await f.model.continueStartOver()
    }

    // MARK: Journal

    func testJournalRoundTripConfirmationAndClear() throws {
        let memory = MemoryJournal()
        let store = memory.store
        XCTAssertNil(store.load())
        XCTAssertTrue(store.clear(), "clearing an absent journal is a no-op success")
        let operation = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000.123)
        let journal = SyncResetRequestJournal(operationId: operation, deviceKeyID: "dev-1", createdAt: created)
        try store.save(journal)
        XCTAssertEqual(store.load(), journal)
        XCTAssertNil(store.load()?.executeAfter)
        let after = created.addingTimeInterval(48 * 3600)
        try store.save(journal.confirmed(executeAfter: after, joinRequestId: "jr-1"))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.operationId, operation)
        XCTAssertEqual(loaded.deviceKeyID, "dev-1")
        XCTAssertEqual(loaded.joinRequestId, "jr-1")
        XCTAssertEqual(loaded.executeAfter!.timeIntervalSince1970, after.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)

        memory.data = Data("not json".utf8)
        XCTAssertNil(store.load(), "a malformed journal reads as none")
        memory.data = Data(#"{"v":2,"operationId":"\#(operation.uuidString)","deviceKeyID":"d","createdAtMs":1}"#.utf8)
        XCTAssertNil(store.load(), "an unknown version reads as none")
        XCTAssertTrue(store.clear())
        XCTAssertNil(memory.data)
        memory.failWrites = true
        XCTAssertThrowsError(try store.save(journal))
    }

    // MARK: Entry

    func testThirdChoiceAppearsOnlyWhenTheAccountExistsWithoutAnEnvelope() async throws {
        let f = try await makeFixture()
        XCTAssertFalse(f.model.canStartOver, "nothing is known before the account probe")
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .chooseJoinMethod)
        XCTAssertTrue(f.model.canStartOver)

        let empty = try await makeFixture(accountExists: false)
        await empty.model.beginSetup()
        XCTAssertEqual(empty.model.phase, .introduction)
        XCTAssertFalse(empty.model.canStartOver, "an empty account has nothing to start over from")
        empty.model.showStartOver()
        XCTAssertEqual(empty.model.phase, .introduction)

        let unwired = KeyLayerViewModel(manager: f.manager, beginEnrollment: {},
                                        recoveryConfirmationRequired: { false })
        await unwired.beginSetup()
        XCTAssertFalse(unwired.canStartOver, "without a journal store the choice is hidden")
    }

    func testCancelledSignInReturnsToTheExplanationAndSendsNothing() async throws {
        let f = try await makeFixture(signIns: [.cancelled])
        await requestStartOver(f)
        XCTAssertEqual(f.model.phase, .resetExplanation)
        XCTAssertNil(f.model.inputError)
        XCTAssertTrue(f.api.resetRequestPuts.isEmpty)
        XCTAssertNil(f.journal.data)

        let wrong = try await makeFixture(signIns: [.wrongAccount])
        await requestStartOver(wrong)
        XCTAssertEqual(wrong.model.phase, .resetExplanation)
        XCTAssertEqual(wrong.model.inputError, ResetRequestStrings.signInWrongAccount)
        XCTAssertTrue(wrong.api.resetRequestPuts.isEmpty)
    }

    // MARK: Request answers

    func testPendingAnswerJournalsFirstWithdrawsTicketsAndWaits() async throws {
        let f = try await makeFixture()
        let ownKey = try f.provider.loadOrCreatePrivateKey().publicKey.rawRepresentation
        f.api.pendingSummaries = [
            JoinRequestSummaryDTO(requestId: "own-ticket", requestingPublicKey: ownKey, name: "Mac",
                                  platform: "macos", status: "pending", createdAt: Date()),
            JoinRequestSummaryDTO(requestId: "other-ticket", requestingPublicKey: Data([7]), name: "Mac",
                                  platform: "macos", status: "pending", createdAt: Date())]
        var journalAtPut: SyncResetRequestJournal?
        f.api.beforeResetRequestPut = { journalAtPut = f.journal.store.load() }

        await requestStartOver(f)

        XCTAssertEqual(f.signIns.calls, 1)
        XCTAssertEqual(f.api.denyCalls, ["own-ticket"], "only this device's ticket is withdrawn, before the request")
        let put = try XCTUnwrap(f.api.resetRequestPuts.first)
        let atPut = try XCTUnwrap(journalAtPut, "the journal is written before the PUT")
        XCTAssertEqual(atPut.operationId, put.operationId)
        XCTAssertEqual(put.deviceKeyId, try f.provider.deviceKeyId())
        XCTAssertEqual(put.publicKey, ownKey)
        guard case .waitingForReset(let executeAfter) = f.model.phase else {
            return XCTFail("expected the waiting page, got \(f.model.phase)")
        }
        let saved = try XCTUnwrap(f.journal.store.load())
        XCTAssertEqual(saved.operationId, put.operationId)
        XCTAssertEqual(saved.joinRequestId, "reset-join")
        XCTAssertEqual(saved.executeAfter!.timeIntervalSince1970, executeAfter.timeIntervalSince1970, accuracy: 0.001)
        f.model.stopPolling()
    }

    func testDevicesActiveAndRequestExistsClearTheJournal() async throws {
        let lastActive = Date(timeIntervalSince1970: 1_800_000_000)
        let f = try await makeFixture()
        f.api.resetRequestPutResults = [.failure(ResetRequestError.devicesActive(lastActiveAt: lastActive, deviceName: "Old"))]
        await requestStartOver(f)
        XCTAssertEqual(f.model.phase, .resetRefused(.devicesActive(lastActiveAt: lastActive)))
        XCTAssertNil(f.journal.data)
        f.model.leaveStartOver()
        XCTAssertEqual(f.model.phase, .chooseJoinMethod)

        let other = try await makeFixture()
        let executeAfter = Date().addingTimeInterval(3600)
        other.api.resetRequestPutResults = [.failure(ResetRequestError.requestExists(executeAfter: executeAfter))]
        await requestStartOver(other)
        XCTAssertEqual(other.model.phase, .resetRefused(.requestExists(executeAfter: executeAfter)))
        XCTAssertNil(other.journal.data)
    }

    func testStaleAuthenticationSignsInOnceMoreThenShowsTheFixedError() async throws {
        let f = try await makeFixture()
        f.api.resetRequestPutResults = [.failure(ResetRequestError.staleAuthentication)]
        await requestStartOver(f)
        XCTAssertEqual(f.signIns.calls, 2, "a stale sign-in reruns the fresh sign-in once")
        XCTAssertEqual(f.api.resetRequestPuts.count, 2)
        guard case .waitingForReset = f.model.phase else { return XCTFail("the second attempt succeeds") }
        f.model.stopPolling()

        let twice = try await makeFixture()
        twice.api.resetRequestPutResults = [.failure(ResetRequestError.staleAuthentication),
                                            .failure(ResetRequestError.staleAuthentication)]
        await requestStartOver(twice)
        XCTAssertEqual(twice.signIns.calls, 2, "only once more")
        XCTAssertEqual(twice.model.phase, .resetError(ResetRequestStrings.staleSignIn))
        XCTAssertNil(twice.journal.data, "nothing was created, so nothing stays journaled")
    }

    func testAccountNotFoundRoutesToFirstDeviceSetup() async throws {
        let f = try await makeFixture()
        f.api.resetRequestPutResults = [.failure(ResetRequestError.accountNotFound)]
        await requestStartOver(f)
        XCTAssertEqual(f.model.phase, .introduction)
        XCTAssertNil(f.journal.data)
        XCTAssertFalse(f.model.canStartOver)
    }

    func testTransportFailureKeepsTheJournalAndRetryReplaysTheOperation() async throws {
        let f = try await makeFixture()
        f.api.resetRequestPutResults = [.failure(KeyAPIError.transport(URLError(.notConnectedToInternet)))]
        await requestStartOver(f)
        XCTAssertEqual(f.model.phase, .resetError(ResetRequestStrings.requestFailed))
        let kept = try XCTUnwrap(f.journal.store.load())
        XCTAssertNil(kept.executeAfter)

        // The lost PUT may have created the request: its join row is now this key's pending ticket.
        let ownKey = try f.provider.loadOrCreatePrivateKey().publicKey.rawRepresentation
        f.api.pendingSummaries = [JoinRequestSummaryDTO(requestId: "reset-join", requestingPublicKey: ownKey, name: "Mac",
                                                        platform: "macos", status: "pending", createdAt: Date())]
        await f.model.retryReset()
        XCTAssertEqual(f.signIns.calls, 1, "a replay needs no second sign-in while it is fresh")
        XCTAssertEqual(f.api.denyCalls, [], "a replay withdraws nothing: the request's own join row must survive")
        XCTAssertEqual(f.api.resetRequestPuts.map(\.operationId), [kept.operationId, kept.operationId])
        guard case .waitingForReset = f.model.phase else { return XCTFail("Retry reaches the waiting page") }
        f.model.stopPolling()
    }

    func testDefinitiveRefusalDropsTheJournal() async throws {
        let f = try await makeFixture()
        f.api.resetRequestPutResults = [.failure(ResetRequestError.deviceKnown)]
        await requestStartOver(f)
        XCTAssertEqual(f.model.phase, .resetError(ResetRequestStrings.requestFailed))
        XCTAssertNil(f.journal.data)
        await f.model.retryReset()
        XCTAssertEqual(f.model.phase, .resetExplanation, "with nothing journaled, Retry starts from the explanation")
    }

    // MARK: Poll answers

    /// A journaled request, confirmed by the server, as a reopened window finds it.
    private func journaled(executeAfter: Date = Date().addingTimeInterval(48 * 3600))
        async throws -> (Fixture, UUID) {
        let journal = MemoryJournal()
        let operation = UUID()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        try journal.store.save(SyncResetRequestJournal(operationId: operation, deviceKeyID: try provider.deviceKeyId(),
                                                       createdAt: Date()).confirmed(executeAfter: executeAfter,
                                                                                    joinRequestId: "reset-join"))
        return (try await makeFixture(journal: journal, provider: provider), operation)
    }

    func testReopenedWindowLandsOnTheWaitingPage() async throws {
        let executeAfter = Date().addingTimeInterval(3600)
        let (f, operation) = try await journaled(executeAfter: executeAfter)
        f.api.resetRequestGetResults = [.success(pending(operation, executeAfter: executeAfter))]
        await f.model.beginSetup()
        XCTAssertEqual(f.api.resetRequestGets, [operation], "each (re)open asks the server")
        guard case .waitingForReset(let shown) = f.model.phase else {
            return XCTFail("expected the waiting page, got \(f.model.phase)")
        }
        XCTAssertEqual(shown.timeIntervalSince1970, executeAfter.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(f.model.canStartOver)

        // Offline on reopen: still the waiting page from the journal, with the error.
        let (offline, _) = try await journaled(executeAfter: executeAfter)
        offline.api.resetRequestGetResults = [.failure(KeyAPIError.transport(URLError(.notConnectedToInternet)))]
        await offline.model.beginSetup()
        guard case .waitingForReset = offline.model.phase else { return XCTFail("the journal's date is shown") }
        XCTAssertEqual(offline.model.inputError, KeyLayerStrings.connectionFailed)
        XCTAssertNotNil(offline.journal.data, "a transport error keeps the journal")
        f.model.stopPolling()
        offline.model.stopPolling()
    }

    func testApprovedContinuesThroughTheApprovedJoin() async throws {
        let (f, operation) = try await journaled()
        let ark = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let envelope = try PhiKeyCrypto.sealToPublicKey(ark, recipient: try f.provider.loadOrCreatePrivateKey().publicKey)
        f.api.joinRequests["reset-join"] = JoinRequestDTO(requestId: "reset-join", requestingPublicKey: Data(),
            name: "Mac", platform: "macos", status: "approved", grantedArkEnvelope: envelope,
            createdAt: Date(), resolvedByDeviceKeyId: "dev-old")
        f.api.resetRequestGetResults = [.success(pending(operation, status: "approved"))]
        var verified = 0
        f.model.onVerified = { verified += 1 }
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .readyToPair)
        XCTAssertEqual(verified, 1)
        XCTAssertNotNil(f.manager.currentARK)
        XCTAssertEqual(f.api.postDeviceCalls, 1, "this Mac registers as an ordinary approved join")
        XCTAssertNil(f.journal.data)
        XCTAssertTrue(f.api.resetRequestExecutes.isEmpty, "nothing is deleted")
    }

    func testDeniedBlockedExpiredAndCancelledEndTheRequest() async throws {
        let cases: [(String, KeyLayerPhase)] = [
            ("denied", .resetRefused(.denied)),
            ("blocked", .resetRefused(.devicesActive(lastActiveAt: nil))),
            ("expired", .resetRefused(.expired)),
            ("cancelled", .chooseJoinMethod)]
        for (status, phase) in cases {
            let (f, operation) = try await journaled()
            f.api.resetRequestGetResults = [.success(pending(operation, status: status))]
            await f.model.beginSetup()
            XCTAssertEqual(f.model.phase, phase, status)
            XCTAssertNil(f.journal.data, "\(status) clears the journal")
        }
        let (expired, operation) = try await journaled()
        expired.api.resetRequestGetResults = [.success(pending(operation, status: "expired"))]
        await expired.model.beginSetup()
        expired.model.startOverAgain()
        XCTAssertEqual(expired.model.phase, .resetExplanation, "an expired request offers to start over again")
    }

    func testRequestGoneOnTheServerRerunsTheAccountProbe() async throws {
        let (f, _) = try await journaled()
        f.api.resetRequestGetResults = []  // 404 reset_request_not_found
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .chooseJoinMethod, "the account still exists: back to the join choice")
        XCTAssertNil(f.journal.data)
    }

    // MARK: Execution

    func testPendingPastTheDateExecutesAndRoutesToFirstDeviceSetup() async throws {
        let past = Date().addingTimeInterval(-60)
        let (f, operation) = try await journaled(executeAfter: past)
        f.api.resetRequestGetResults = [.success(pending(operation, executeAfter: past))]
        await f.model.beginSetup()
        XCTAssertEqual(f.api.resetRequestExecutes.map(\.operationId), [operation])
        XCTAssertEqual(f.api.resetRequestExecutes.first?.deviceKeyId, try f.provider.deviceKeyId())
        XCTAssertNil(f.journal.data)
        XCTAssertEqual(f.model.phase, .introduction, "the emptied account sends setup to first-device bootstrap")
    }

    func testExecuteNotFoundCountsAsDone() async throws {
        let past = Date().addingTimeInterval(-60)
        let (f, operation) = try await journaled(executeAfter: past)
        f.api.resetRequestGetResults = [.success(pending(operation, executeAfter: past))]
        f.api.resetRequestExecuteErrors = [ResetRequestError.notFound]
        f.api.account = nil  // the row went with the account
        f.api.initialized = false
        await f.model.beginSetup()
        XCTAssertNil(f.journal.data)
        XCTAssertEqual(f.model.phase, .introduction)
    }

    func testExecuteTooEarlyKeepsWaitingWithTheServersDate() async throws {
        let past = Date().addingTimeInterval(-60)
        let serverDate = Date().addingTimeInterval(600)
        let (f, operation) = try await journaled(executeAfter: past)
        f.api.resetRequestGetResults = [.success(pending(operation, executeAfter: past))]
        f.api.resetRequestExecuteErrors = [ResetRequestError.tooEarly(executeAfter: serverDate)]
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .waitingForReset(executeAfter: serverDate))
        XCTAssertNotNil(f.journal.data, "still pending")
        XCTAssertEqual(f.journal.store.load()!.executeAfter!.timeIntervalSince1970,
                       serverDate.timeIntervalSince1970, accuracy: 0.001)
        f.model.stopPolling()
    }

    func testExecuteDevicesActiveAndOtherFailures() async throws {
        let past = Date().addingTimeInterval(-60)
        let lastActive = Date(timeIntervalSince1970: 1_800_000_000)
        let (f, operation) = try await journaled(executeAfter: past)
        f.api.resetRequestGetResults = [.success(pending(operation, executeAfter: past))]
        f.api.resetRequestExecuteErrors = [ResetRequestError.devicesActive(lastActiveAt: lastActive, deviceName: nil)]
        await f.model.beginSetup()
        XCTAssertEqual(f.model.phase, .resetRefused(.devicesActive(lastActiveAt: lastActive)))
        XCTAssertNil(f.journal.data)

        let (g, op2) = try await journaled(executeAfter: past)
        g.api.resetRequestGetResults = [.success(pending(op2, executeAfter: past)), .success(pending(op2, executeAfter: past))]
        g.api.resetRequestExecuteErrors = [KeyAPIError.http(500, "")]
        await g.model.beginSetup()
        XCTAssertEqual(g.model.phase, .resetError(ResetRequestStrings.executeFailed))
        XCTAssertNotNil(g.journal.data, "an unknown outcome keeps the journal")
        await g.model.retryReset()
        XCTAssertEqual(g.api.resetRequestExecutes.count, 2, "Retry asks again and executes")
        XCTAssertEqual(g.model.phase, .introduction)
        XCTAssertNil(g.journal.data)
    }

    // MARK: Cancel

    func testCancelRequestWithdrawsAndClearsOrKeepsOnTransportFailure() async throws {
        let (f, operation) = try await journaled()
        f.api.resetRequestGetResults = [.success(pending(operation))]
        await f.model.beginSetup()
        f.api.resetRequestCancelError = KeyAPIError.transport(URLError(.notConnectedToInternet))
        await f.model.cancelResetRequest()
        guard case .waitingForReset = f.model.phase else { return XCTFail("a failed cancel stays on the waiting page") }
        XCTAssertEqual(f.model.inputError, ResetRequestStrings.cancelFailed)
        XCTAssertNotNil(f.journal.data)

        f.api.resetRequestCancelError = nil
        await f.model.cancelResetRequest()
        XCTAssertEqual(f.model.phase, .chooseJoinMethod)
        XCTAssertNil(f.journal.data)
        XCTAssertEqual(f.api.resetRequestCancels.map(\.operationId), [operation, operation])

        // Already resolved on the server: nothing left to withdraw, which counts as done.
        let (g, op2) = try await journaled()
        g.api.resetRequestGetResults = [.success(pending(op2))]
        await g.model.beginSetup()
        g.api.resetRequestCancelError = ResetRequestError.notPending(status: "denied")
        await g.model.cancelResetRequest()
        XCTAssertEqual(g.model.phase, .chooseJoinMethod)
        XCTAssertNil(g.journal.data)
    }

    func testClosingTheWindowKeepsTheRequest() async throws {
        let (f, operation) = try await journaled()
        f.api.resetRequestGetResults = [.success(pending(operation))]
        await f.model.beginSetup()
        f.model.cancelFlow()
        XCTAssertNotNil(f.journal.data, "Close keeps the request")
        XCTAssertTrue(f.api.resetRequestCancels.isEmpty)
    }

    func testClosingDuringSignInCancelsTheSignIn() async throws {
        let f = try await makeFixture()
        // A sign-in that waits in the browser until it is cancelled.
        let model = KeyLayerViewModel(manager: f.manager, beginEnrollment: {},
                                      recoveryConfirmationRequired: { false },
                                      resetJournal: f.journal.store,
                                      reauthenticate: {
                                          try? await Task.sleep(for: .seconds(30))
                                          return .cancelled
                                      },
                                      cancelReauthentication: { f.signIns.cancels += 1 })
        await model.beginSetup()
        model.showStartOver()
        let signIn = Task { await model.continueStartOver() }
        for _ in 0..<200 where model.phase != .resetSigningIn { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.phase, .resetSigningIn)
        model.cancelStartOverSignIn()
        XCTAssertEqual(model.phase, .resetExplanation)
        XCTAssertEqual(f.signIns.cancels, 1)
        signIn.cancel()
        await signIn.value
        XCTAssertEqual(model.phase, .resetExplanation, "the abandoned sign-in result is ignored")
        XCTAssertTrue(f.api.resetRequestPuts.isEmpty)
    }

    // MARK: Leftovers

    func testAnEnrolledMacDropsALeftoverJournal() async throws {
        let api = FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let owner = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await owner.bootstrap()
        let journal = MemoryJournal()
        try journal.store.save(SyncResetRequestJournal(operationId: UUID(), deviceKeyID: try provider.deviceKeyId(),
                                                       createdAt: Date()))
        let f = try await makeFixture(journal: journal, api: api, provider: provider)
        await f.model.beginSetup()
        XCTAssertNil(journal.data, "an unlocked Mac has no request to wait for")
        for _ in 0..<200 where api.resetRequestCancels.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(api.resetRequestCancels.count, 1, "the leftover is withdrawn best effort")
    }
}

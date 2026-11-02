// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Sentry
import XCTest
@testable import Phi

/// The reporter's dedupe rules (docs/sync.md, "Sync status contract") with an injected clock, store
/// and capture closures. Nothing here touches PostHog or Sentry.
@MainActor
final class SyncAttentionReporterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var events: [(name: String, properties: [String: Any])] = []
    private var sentry: [(SyncAttentionProblem, SyncAttentionObservation)] = []
    private let start = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "SyncAttentionReporterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        events = []
        sentry = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func reporter(version: String = "1.0") -> SyncAttentionReporter {
        SyncAttentionReporter(defaults: defaults, appVersion: version,
                              postHogCapture: { [weak self] in self?.events.append(($0, $1)) },
                              sentryCapture: { [weak self] in self?.sentry.append(($0, $1)) })
    }

    private func report(phi phase: SyncContextPhase = .needsAttention,
                        kinds: [SyncKind: SyncKindStatus] = [:],
                        problem: SyncProblemCategory? = nil, problemKind: SyncKind? = nil,
                        profiles: [SyncContextPhase] = []) -> SyncHelper.Report {
        var detail = SyncNativeDetail(kinds: kinds)
        detail.lastProblem = problem.map { SyncErrorSummary(category: $0, kind: problemKind, at: start) }
        var report = SyncHelper.Report()
        report.snapshots["phi"] = SyncContextSnapshot(id: "phi", phase: phase, lastSuccess: nil, revision: 1,
                                                      detail: detail)
        for (index, profilePhase) in profiles.enumerated() {
            report.snapshots["profile-\(index)"] = SyncContextSnapshot(
                id: "profile-\(index)", phase: profilePhase, lastSuccess: nil, revision: 1)
        }
        let phases = report.snapshots.values.map(\.phase)
        report.summary = SyncStatusSummary(
            phase: phases.contains(.needsAttention) ? .needsAttention
                : phases.allSatisfy { $0 == .upToDate } ? .upToDate : .checking,
            lastSuccess: nil)
        return report
    }

    /// Six pins held for an unmapped Profile.
    private func heldPins(_ count: Int = 6) -> SyncHelper.Report {
        report(kinds: [.pinnedTabs: SyncKindStatus(held: count, heldByReason: [.unmappedProfileOwner: count])])
    }

    private var healthy: SyncHelper.Report { report(phi: .upToDate) }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func names() -> [String] { events.map(\.name) }

    /// Observes `report` every three seconds over `[from, to]`, as the helper's poll would.
    private func poll(_ reporter: SyncAttentionReporter, _ report: SyncHelper.Report,
                      from: TimeInterval, to: TimeInterval, persistenceFailure: Bool = false) {
        var time = from
        while time <= to {
            reporter.observe(report, persistenceFailure: persistenceFailure, now: at(time))
            time += 3
        }
    }

    // MARK: - Entry

    func testATransientProblemUnderSixtySecondsReportsNothing() {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 57)
        poll(subject, healthy, from: 60, to: 300)
        poll(subject, heldPins(), from: 303, to: 360)
        XCTAssertEqual(names(), [], "The second episode also restarts its debounce")
        XCTAssertTrue(sentry.isEmpty)
    }

    func testAProblemEntersOnceAcrossManyObservationsAndCountChanges() throws {
        let subject = reporter()
        poll(subject, heldPins(6), from: 0, to: 600)
        poll(subject, heldPins(9), from: 603, to: 1200)
        XCTAssertEqual(names(), ["sync_attention_entered"])
        let properties = try XCTUnwrap(events.first?.properties)
        XCTAssertEqual(properties["sync_context"] as? String, "phi")
        XCTAssertEqual(properties["sync_kind"] as? String, "pinnedTabs")
        XCTAssertEqual(properties["sync_reason"] as? String, "heldUnmappedProfileOwner")
        XCTAssertEqual(properties["held_count"] as? Int, 6)
    }

    func testANewReporterOverTheSameDefaultsDoesNotEnterAgain() {
        poll(reporter(), heldPins(), from: 0, to: 120)
        XCTAssertEqual(names(), ["sync_attention_entered"])
        let relaunched = reporter()
        // The relaunched engine reports Checking before its first round; that proves nothing.
        poll(relaunched, report(phi: .checking), from: 400, to: 600)
        poll(relaunched, heldPins(), from: 603, to: 900)
        XCTAssertEqual(names(), ["sync_attention_entered"])
    }

    // MARK: - Snapshot

    func testASnapshotFollowsOncePerDay() throws {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 60)
        subject.observe(heldPins(), persistenceFailure: false, now: at(60 + 23 * 3600))
        XCTAssertEqual(names(), ["sync_attention_entered"], "No snapshot within 24 hours of entry")
        subject.observe(heldPins(), persistenceFailure: false, now: at(60 + 24 * 3600))
        subject.observe(heldPins(), persistenceFailure: false, now: at(63 + 24 * 3600))
        subject.observe(heldPins(), persistenceFailure: false, now: at(60 + 47 * 3600))
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_snapshot"])
        XCTAssertEqual(events.last?.properties["age_seconds"] as? Int, 24 * 3600)
        subject.observe(heldPins(), persistenceFailure: false, now: at(60 + 48 * 3600))
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_snapshot", "sync_attention_snapshot"])
    }

    // MARK: - Clear

    func testAbsenceWithinTheGraceIsSilentAndBeyondItClearsOnce() throws {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 120)
        poll(subject, healthy, from: 123, to: 180)
        poll(subject, heldPins(), from: 183, to: 240)
        XCTAssertEqual(names(), ["sync_attention_entered"], "57 seconds of absence is within the grace")
        poll(subject, healthy, from: 243, to: 400)
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_cleared"])
        let properties = try XCTUnwrap(events.last?.properties)
        XCTAssertEqual(properties["cleared_by"] as? String, "resolved")
        XCTAssertEqual(properties["duration_seconds"] as? Int, 303 - 60)
    }

    func testCheckingAndOfflineDoNotCountAsAbsence() {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 120)
        poll(subject, report(phi: .offline), from: 123, to: 600)
        poll(subject, report(phi: .syncing), from: 603, to: 900)
        XCTAssertEqual(names(), ["sync_attention_entered"])
    }

    func testAnAppVersionChangeClearsAsUpgrade() {
        poll(reporter(version: "1.0"), heldPins(), from: 0, to: 120)
        poll(reporter(version: "1.1"), healthy, from: 200, to: 300)
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_cleared"])
        XCTAssertEqual(events.last?.properties["cleared_by"] as? String, "upgrade")
    }

    // MARK: - Sentry

    func testOnlyUnexpectedReasonsReachSentryOncePerWeek() {
        let subject = reporter()
        let lineage = report(kinds: [.pinnedTabs: SyncKindStatus(held: 2, heldByReason: [.lineageExists: 2])])
        poll(subject, heldPins(), from: 0, to: 120)
        XCTAssertTrue(sentry.isEmpty, "An unmapped Profile is expected, so PostHog only")

        poll(subject, lineage, from: 200, to: 400)
        XCTAssertEqual(sentry.count, 1)
        XCTAssertEqual(sentry.first?.0.reason, .heldLineageExists)
        XCTAssertEqual(sentry.first?.0.kind, .pinnedTabs)
        XCTAssertEqual(sentry.first?.1.heldCount, 2)

        // Clear and re-enter within the week: PostHog sees both entries, Sentry only the first.
        poll(subject, healthy, from: 403, to: 600)
        poll(subject, lineage, from: 603, to: 800)
        XCTAssertEqual(names().filter { $0 == "sync_attention_entered" }.count, 3)
        XCTAssertEqual(sentry.count, 1)

        // A week later the same problem may reach Sentry again.
        let week = SyncAttentionReporter.sentryInterval
        poll(subject, healthy, from: 803, to: 1000)
        poll(subject, lineage, from: 1000 + week, to: 1100 + week)
        XCTAssertEqual(sentry.count, 2)
    }

    func testHelperAndCategoryProblemsAreSeparateProblems() {
        let subject = reporter()
        var combined = report(kinds: [.bookmarks: SyncKindStatus(held: 1, heldByReason: [.landingFailed: 1])],
                              problem: .readFailedOnThisMac, problemKind: .bookmarks)
        combined.pinScopeMigrationFailure = SyncPinScopeMigrationFailure(attempts: 3, lastKind: .writeFailed)
        poll(subject, combined, from: 0, to: 120, persistenceFailure: true)
        let reasons = Set(events.compactMap { $0.properties["sync_reason"] as? String })
        XCTAssertEqual(reasons, ["heldLandingFailed", "readFailedOnThisMac", "pinScopeMigrationFailed", "persistenceFailure"])
        XCTAssertEqual(sentry.count, 4, "All four are unexpected reasons")
    }

    func testOfflineIsNeverAProblemAndChromiumProfilesShareOne() {
        let subject = reporter()
        var offline = report(phi: .upToDate, problem: .offline, profiles: [.needsAttention, .needsAttention])
        offline.summary = SyncStatusSummary(phase: .needsAttention, lastSuccess: nil)
        poll(subject, offline, from: 0, to: 120)
        XCTAssertEqual(names(), ["sync_attention_entered"])
        XCTAssertEqual(events.first?.properties["sync_context"] as? String, "chromium")
        XCTAssertEqual(events.first?.properties["sync_reason"] as? String, "unknown")
    }

    // MARK: - Sync off

    /// A launch before unlock, or a transient key discard, reports Not started briefly. That neither
    /// clears nor re-enters a problem, and does not advance the clear grace.
    func testABriefNotStartedRunKeepsStateAndPausesTheGrace() {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 120)
        poll(subject, SyncHelper.Report(), from: 123, to: 153)
        poll(reporter(), heldPins(), from: 156, to: 400)
        XCTAssertEqual(names(), ["sync_attention_entered"], "No second entry after 30 s of Not started")

        let relaunched = reporter()
        relaunched.observe(healthy, persistenceFailure: false, now: at(403))
        poll(relaunched, SyncHelper.Report(), from: 406, to: 600)
        relaunched.observe(healthy, persistenceFailure: false, now: at(603))
        XCTAssertEqual(names(), ["sync_attention_entered"], "Not started time does not count toward the grace")
        poll(relaunched, healthy, from: 606, to: 663)
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_cleared"])
    }

    func testTenMinutesOfNotStartedDropsStateSilently() {
        let subject = reporter()
        poll(subject, heldPins(), from: 0, to: 120)
        poll(subject, SyncHelper.Report(), from: 123, to: 123 + 11 * 60)
        XCTAssertEqual(names(), ["sync_attention_entered"], "Not started emits no cleared event")
        XCTAssertEqual(subject.feedbackMetadata(now: at(900)), ["sync_phase": "notStarted"])
        poll(reporter(), heldPins(), from: 1000, to: 1120)
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_entered"],
                       "After sync restarts the problem is a new episode")
    }

    // MARK: - Settled contexts

    func testUnreadableSettingsAreOneProblem() {
        let subject = reporter()
        poll(subject, report(kinds: [.settings: SyncKindStatus(held: 1)],
                             problem: .unreadableRemoteData, problemKind: .settings),
             from: 0, to: 120)
        XCTAssertEqual(events.compactMap { $0.properties["sync_reason"] as? String }, ["unreadableRemoteData"])
        XCTAssertEqual(sentry.count, 1)
    }

    func testAChromiumProblemClearsWhileAnotherProfileStaysSyncing() {
        let subject = reporter()
        poll(subject, report(phi: .upToDate, profiles: [.needsAttention, .syncing]), from: 0, to: 120)
        poll(subject, report(phi: .upToDate, profiles: [.upToDate, .syncing]), from: 123, to: 183)
        XCTAssertEqual(names(), ["sync_attention_entered", "sync_attention_cleared"])
        XCTAssertNil(subject.feedbackMetadata(now: at(183))["sync_attention_problems"])
    }

    // MARK: - Sentry scope

    /// The event drops the global user and carries only the expected tags, context and fingerprint.
    /// Sentry Cocoa keeps the scope's attachments private and out of `serialize()`, so
    /// `clearAttachments()` is exercised but cannot be asserted here.
    func testTheSentryScopeCarriesNoUserAndOnlyTheExpectedKeys() throws {
        let scope = Scope()
        scope.setUser(User(userId: "auth0|someone"))
        scope.addAttachment(Attachment(data: Data("log".utf8), filename: "logs.txt"))
        SentryService.configureSyncAttentionScope(scope, kind: "pinnedTabs", reason: "heldLineageExists",
                                                  context: "phi", details: ["held_count": 2, "age_seconds": 0])
        let serialized = scope.serialize()
        XCTAssertNil(serialized["user"])
        let tags = try XCTUnwrap(serialized["tags"] as? [String: String])
        XCTAssertEqual(tags, ["area": "sync", "sync_kind": "pinnedTabs", "sync_reason": "heldLineageExists",
                              "sync_context": "phi"])
        let contexts = try XCTUnwrap(serialized["context"] as? [String: Any])
        XCTAssertEqual(Set(contexts.keys), ["sync_attention"])
        XCTAssertEqual(serialized["fingerprint"] as? [String], ["sync-attention", "phi", "pinnedTabs", "heldLineageExists"])
    }

    // MARK: - Payload

    func testPropertiesHoldOnlyStringsAndIntegers() {
        let subject = reporter(version: "1.0")
        let landing = report(kinds: [.pinnedTabs: SyncKindStatus(held: 2, heldByReason: [.landingFailed: 2])])
        poll(subject, landing, from: 0, to: 120)
        subject.observe(landing, persistenceFailure: false, now: at(24 * 3600 + 60))
        poll(reporter(version: "2.0"), healthy, from: 24 * 3600 + 123, to: 24 * 3600 + 300)
        XCTAssertEqual(Set(names()), ["sync_attention_entered", "sync_attention_snapshot", "sync_attention_cleared"])
        for event in events {
            for (key, value) in event.properties {
                XCTAssertTrue(value is String || value is Int, "\(event.name).\(key) is \(type(of: value))")
                if let string = value as? String {
                    XCTAssertNil(string.range(of: "[^A-Za-z0-9_]", options: .regularExpression),
                                 "\(event.name).\(key) must be an enum raw value")
                }
            }
        }
    }

    func testFeedbackMetadataListsTrackedProblems() {
        let subject = reporter()
        poll(subject, heldPins(6), from: 0, to: 120)
        let metadata = subject.feedbackMetadata(now: at(180))
        XCTAssertEqual(metadata["sync_phase"], "needsAttention")
        XCTAssertEqual(metadata["sync_attention_problems"], "phi:pinnedTabs:heldUnmappedProfileOwner=6")
        XCTAssertEqual(metadata["sync_attention_oldest_age_seconds"], "120")
        XCTAssertEqual(metadata["sync_attention_entered_count"], "1")
    }
}

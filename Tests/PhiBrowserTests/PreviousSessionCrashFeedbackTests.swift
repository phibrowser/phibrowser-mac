// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class PreviousSessionCrashFeedbackTests: XCTestCase {
    private func crash() -> PreviousSessionCrashContext {
        PreviousSessionCrashContext(
            eventID: "0123456789abcdef0123456789abcdef",
            timestamp: Date(timeIntervalSince1970: 100),
            logSnapshot: Data("previous logs".utf8)
        )
    }

    func testLogSnapshotUsesNewestTailsWithinByteLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let newest = root.appendingPathComponent("newest.log")
        let older = root.appendingPathComponent("older.log")
        try Data("6789".utf8).write(to: newest)
        try Data("012345".utf8).write(to: older)
        XCTAssertEqual(
            PhiLogging.logSnapshot(paths: [newest.path, root.appendingPathComponent("missing").path, older.path], maxBytes: 7),
            Data("3456789".utf8)
        )
        XCTAssertEqual(PhiLogging.logSnapshot(paths: [newest.path], maxBytes: 2), Data("89".utf8))
        XCTAssertNil(PhiLogging.logSnapshot(paths: [newest.path], maxBytes: 0))
    }

    func testCrashMetadataPreservesFeedbackJobIdentity() throws {
        let draft = FeedbackDraft(
            description: "I was opening settings", pageURL: "", pageTitle: nil,
            contactEmail: nil, components: [], chromiumSystemLogsText: nil, attachments: [],
            previousSessionCrash: crash()
        )
        let metadata = FeedbackOutbox.makeMetadata(jobID: "feedback-job", draft: draft)
        XCTAssertEqual(metadata.clientContext.traceID, "feedback-job")
        XCTAssertEqual(metadata.clientContext.category, "previous_session_crash")
        XCTAssertNil(metadata.extra["feedback_source"])
        XCTAssertEqual(metadata.extra["sentry_event_id"], crash().eventID)
        XCTAssertNil(metadata.extra["crash_release"])
        XCTAssertNil(metadata.extra["crash_environment"])
        XCTAssertNil(metadata.extra["system_logs_session"])
        XCTAssertEqual(metadata.extra["crash_timestamp"], "1970-01-01T00:01:40Z")
        XCTAssertNil(metadata.page?.url)

        let manifest = FeedbackOutboxManifest(
            id: "feedback-job", createdAt: Date(), description: draft.description, contactEmail: nil,
            metadata: metadata, sourceImages: [], sourceFiles: [], chromiumSystemLogs: nil,
            preparedAttachments: [], status: .queued, retryCount: 0
        )
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(FeedbackOutboxManifest.self, from: encoded)
        XCTAssertEqual(decoded.metadata.extra["sentry_event_id"], crash().eventID)
        XCTAssertEqual(decoded.metadata.clientContext.category, "previous_session_crash")
        XCTAssertNil(decoded.metadata.extra["feedback_source"])
        // Legacy manifests omit the new optional snapshot reference.
        XCTAssertNil(decoded.previousSessionCrashLog)

        var regularDraft = draft
        regularDraft.previousSessionCrash = nil
        let regularMetadata = FeedbackOutbox.makeMetadata(jobID: "regular-job", draft: regularDraft)
        XCTAssertEqual(regularMetadata.clientContext.category, "issue-report")
        XCTAssertNil(regularMetadata.extra["feedback_source"])
        XCTAssertNil(regularMetadata.extra["sentry_event_id"])
    }

    func testSyncStatusMetadataJoinsExtra() {
        var draft = FeedbackDraft(
            description: "Pinned tabs missing", pageURL: "", pageTitle: nil,
            contactEmail: nil, components: [], chromiumSystemLogsText: nil, attachments: []
        )
        XCTAssertNil(FeedbackOutbox.makeMetadata(jobID: "job", draft: draft).extra["sync_phase"])
        draft.syncStatusMetadata = [
            "sync_phase": "needsAttention",
            "sync_attention_problems": "phi:pinnedTabs:heldUnmappedProfileOwner=6",
            "sync_attention_oldest_age_seconds": "120",
            "sync_attention_entered_count": "1",
        ]
        let extra = FeedbackOutbox.makeMetadata(jobID: "job", draft: draft).extra
        XCTAssertEqual(extra["sync_phase"], "needsAttention")
        XCTAssertEqual(extra["sync_attention_problems"], "phi:pinnedTabs:heldUnmappedProfileOwner=6")
        XCTAssertEqual(extra["sync_attention_oldest_age_seconds"], "120")
        XCTAssertEqual(extra["sync_attention_entered_count"], "1")
        XCTAssertNotNil(extra["build_number"], "The fixed keys stay")
    }

    @MainActor
    func testCrashDraftClearsRestoredPageAndDismissalReleasesContext() {
        let model = FeedbackViewModel()
        model.urlString = "https://restored.example"
        model.pageTitle = "Restored page"
        model.setPreviousSessionCrash(crash())
        XCTAssertEqual(model.urlString, "")
        XCTAssertNil(model.pageTitle)
        XCTAssertFalse(model.canSend)
        model.descriptionText = "I was opening settings"
        XCTAssertTrue(model.canSend)
        model.clearPreviousSessionCrash()
        XCTAssertNil(model.previousSessionCrash)
        XCTAssertEqual(model.descriptionText, "")
        XCTAssertFalse(model.canSend)
    }

    @MainActor
    func testAutomaticCrashContextDoesNotOverwriteManualDraftOrSubmission() {
        let model = FeedbackViewModel()
        model.descriptionText = "Unsent feedback"
        model.urlString = "https://manual.example"
        model.setPreviousSessionCrash(crash())
        XCTAssertNil(model.previousSessionCrash)
        XCTAssertEqual(model.descriptionText, "Unsent feedback")
        XCTAssertEqual(model.urlString, "https://manual.example")
        model.clearPreviousSessionCrash()
        XCTAssertEqual(model.descriptionText, "Unsent feedback")
        model.descriptionText = ""
        model.isSubmitting = true
        model.setPreviousSessionCrash(crash())
        XCTAssertNil(model.previousSessionCrash)
    }
}

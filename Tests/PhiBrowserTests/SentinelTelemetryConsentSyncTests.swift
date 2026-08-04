// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelTelemetryConsentSyncTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testChannelSeparatesStableCanaryAndDev() {
        let stable = SentinelTelemetryConsentChannel.make(
            browserBundleIdentifier: "com.phibrowser.Mac"
        )
        XCTAssertEqual(stable.filename, "telemetry-consent.plist")
        XCTAssertEqual(
            stable.notificationName.rawValue,
            "com.phibrowser.telemetryConsentDidChange"
        )

        let canary = SentinelTelemetryConsentChannel.make(
            browserBundleIdentifier: "com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(canary.filename, "telemetry-consent-canary.plist")
        XCTAssertEqual(
            canary.notificationName.rawValue,
            "com.phibrowser.canary.telemetryConsentDidChange"
        )

        let dev = SentinelTelemetryConsentChannel.make(
            browserBundleIdentifier: "com.phibrowser.dev.Mac"
        )
        XCTAssertEqual(dev.filename, "telemetry-consent-dev.plist")
        XCTAssertEqual(
            dev.notificationName.rawValue,
            "com.phibrowser.dev.telemetryConsentDidChange"
        )
    }

    func testStoreWritesVersionedPropertyListContract() throws {
        let fileURL = temporaryDirectoryURL
            .appendingPathComponent("telemetry-consent.plist")
        let store = SharedTelemetryConsentStore(fileURL: fileURL)
        let revision = try XCTUnwrap(
            UUID(uuidString: "73F0BCBB-9134-46AB-A70B-40F13FA87B06")
        )

        let result = try store.synchronize(
            enabled: true,
            makeRevision: { revision },
            now: { Date(timeIntervalSince1970: 1_725_456_789.123) }
        )

        XCTAssertTrue(result.didWrite)
        XCTAssertEqual(result.consent.schemaVersion, 1)
        XCTAssertTrue(result.consent.enabled)
        XCTAssertEqual(result.consent.revision, revision.uuidString)
        XCTAssertEqual(result.consent.updatedAtMillis, 1_725_456_789_123)
        XCTAssertEqual(try store.read(), result.consent)

        let data = try Data(contentsOf: fileURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(propertyList["SchemaVersion"] as? Int, 1)
        XCTAssertEqual(propertyList["Enabled"] as? Bool, true)
        XCTAssertEqual(propertyList["Revision"] as? String, revision.uuidString)
        XCTAssertEqual(
            propertyList["UpdatedAtMillis"] as? Int64,
            1_725_456_789_123
        )
        XCTAssertEqual(Set(propertyList.keys), [
            "SchemaVersion",
            "Enabled",
            "Revision",
            "UpdatedAtMillis",
        ])
    }

    func testStorePreservesRevisionAndBytesUntilStateChanges() throws {
        let fileURL = temporaryDirectoryURL
            .appendingPathComponent("telemetry-consent.plist")
        let store = SharedTelemetryConsentStore(fileURL: fileURL)
        let firstRevision = try XCTUnwrap(
            UUID(uuidString: "B2A86A97-B538-4E7E-BDB7-74333B391210")
        )
        let secondRevision = try XCTUnwrap(
            UUID(uuidString: "84E79081-42F5-4D87-BE14-9E4C10463225")
        )

        let first = try store.synchronize(
            enabled: true,
            makeRevision: { firstRevision },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let firstBytes = try Data(contentsOf: fileURL)
        let unchanged = try store.synchronize(
            enabled: true,
            makeRevision: { secondRevision },
            now: { Date(timeIntervalSince1970: 200) }
        )

        XCTAssertTrue(first.didWrite)
        XCTAssertFalse(unchanged.didWrite)
        XCTAssertEqual(unchanged.consent.revision, firstRevision.uuidString)
        XCTAssertEqual(unchanged.consent.updatedAtMillis, 100_000)
        XCTAssertEqual(try Data(contentsOf: fileURL), firstBytes)

        let changed = try store.synchronize(
            enabled: false,
            makeRevision: { secondRevision },
            now: { Date(timeIntervalSince1970: 200) }
        )

        XCTAssertTrue(changed.didWrite)
        XCTAssertFalse(changed.consent.enabled)
        XCTAssertEqual(changed.consent.revision, secondRevision.uuidString)
        XCTAssertEqual(changed.consent.updatedAtMillis, 200_000)
        XCTAssertNotEqual(try Data(contentsOf: fileURL), firstBytes)
    }

    func testPublisherWaitsForBridgeAndNotifiesOnlyAfterDurableChanges() throws {
        let fileURL = temporaryDirectoryURL
            .appendingPathComponent("telemetry-consent.plist")
        let store = SharedTelemetryConsentStore(fileURL: fileURL)
        let revisions = [
            try XCTUnwrap(UUID(uuidString: "500D38D3-67D7-44CA-A2AD-C1D03CB119E5")),
            try XCTUnwrap(UUID(uuidString: "03764757-9594-433B-87F7-519077714FD6")),
        ]
        var revisionIndex = 0
        var enabled: Bool?
        var notifications: [Notification.Name] = []
        let channel = SentinelTelemetryConsentChannel.make(
            browserBundleIdentifier: "com.phibrowser.Mac"
        )
        let publisher = SentinelTelemetryConsentPublisher(
            store: store,
            channel: channel,
            readMetricsReportingEnabled: { enabled },
            makeRevision: {
                defer { revisionIndex += 1 }
                return revisions[revisionIndex]
            },
            now: { Date(timeIntervalSince1970: TimeInterval(revisionIndex + 1)) },
            postNotification: { notifications.append($0) }
        )

        XCTAssertFalse(publisher.refreshNow())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(notifications.isEmpty)

        enabled = true
        XCTAssertTrue(publisher.refreshNow())
        let firstConsent = try store.read()
        let firstBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(notifications, [channel.notificationName])

        XCTAssertFalse(publisher.refreshNow())
        XCTAssertEqual(try store.read(), firstConsent)
        XCTAssertEqual(try Data(contentsOf: fileURL), firstBytes)
        XCTAssertEqual(notifications, [channel.notificationName])

        enabled = false
        XCTAssertTrue(publisher.refreshNow())
        XCTAssertFalse(try store.read().enabled)
        XCTAssertNotEqual(try store.read().revision, firstConsent.revision)
        XCTAssertEqual(
            notifications,
            [channel.notificationName, channel.notificationName]
        )
    }

    func testPublisherStopPersistsAChangeFromTheFinalPollingInterval() throws {
        let fileURL = temporaryDirectoryURL
            .appendingPathComponent("telemetry-consent.plist")
        let store = SharedTelemetryConsentStore(fileURL: fileURL)
        var enabled: Bool? = true
        var notificationCount = 0
        let publisher = SentinelTelemetryConsentPublisher(
            store: store,
            channel: .make(browserBundleIdentifier: "com.phibrowser.Mac"),
            pollInterval: 3_600,
            readMetricsReportingEnabled: { enabled },
            postNotification: { _ in notificationCount += 1 }
        )

        publisher.start()
        XCTAssertTrue(try store.read().enabled)

        enabled = false
        publisher.stop()

        XCTAssertFalse(try store.read().enabled)
        XCTAssertEqual(notificationCount, 2)
    }
}

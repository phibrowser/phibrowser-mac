// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SentinelTelemetryConsentChannel: Equatable {
    let filename: String
    let notificationName: Notification.Name

    static let current = make(
        browserBundleIdentifier: Bundle.main.bundleIdentifier
    )

    static func make(browserBundleIdentifier: String?) -> Self {
        let bundleIdentifier = browserBundleIdentifier?.lowercased() ?? ""

        if bundleIdentifier.contains(".canary.") {
            return Self(
                filename: "telemetry-consent-canary.plist",
                notificationName: Notification.Name(
                    "com.phibrowser.canary.telemetryConsentDidChange"
                )
            )
        }

        if bundleIdentifier.contains(".dev.") {
            return Self(
                filename: "telemetry-consent-dev.plist",
                notificationName: Notification.Name(
                    "com.phibrowser.dev.telemetryConsentDidChange"
                )
            )
        }

        return Self(
            filename: "telemetry-consent.plist",
            notificationName: Notification.Name(
                "com.phibrowser.telemetryConsentDidChange"
            )
        )
    }
}

/// The device-scoped Chromium telemetry setting shared with Sentinel.
///
/// `revision` changes only when `enabled` changes or an invalid snapshot is
/// repaired. Sentinel uses it to ensure telemetry queued under an older
/// consent state cannot be delivered after a transition.
struct SharedTelemetryConsent: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let enabled: Bool
    let revision: String
    let updatedAtMillis: Int64

    init(enabled: Bool, revision: UUID, updatedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.enabled = enabled
        self.revision = revision.uuidString
        updatedAtMillis = Int64(
            (updatedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        )
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && UUID(uuidString: revision) != nil
            && updatedAtMillis >= 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion"
        case enabled = "Enabled"
        case revision = "Revision"
        case updatedAtMillis = "UpdatedAtMillis"
    }
}

final class SharedTelemetryConsentStore {
    static let appGroupIdentifier = "group.com.phibrowser.shared"

    struct SynchronizationResult: Equatable {
        let consent: SharedTelemetryConsent
        let didWrite: Bool
    }

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func read() throws -> SharedTelemetryConsent {
        guard let fileURL else {
            throw SharedTelemetryConsentStoreError.appGroupUnavailable
        }

        let data = try Data(contentsOf: fileURL)
        return try PropertyListDecoder().decode(
            SharedTelemetryConsent.self,
            from: data
        )
    }

    /// Persists a new revision only when the effective state changes.
    /// Existing valid bytes are left untouched so the revision survives a
    /// normal browser restart.
    func synchronize(
        enabled: Bool,
        makeRevision: () -> UUID = UUID.init,
        now: () -> Date = Date.init
    ) throws -> SynchronizationResult {
        if let current = try? read(), current.isValid, current.enabled == enabled {
            return SynchronizationResult(consent: current, didWrite: false)
        }

        guard let fileURL else {
            throw SharedTelemetryConsentStoreError.appGroupUnavailable
        }

        let consent = SharedTelemetryConsent(
            enabled: enabled,
            revision: makeRevision(),
            updatedAt: now()
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(consent)
        try data.write(to: fileURL, options: .atomic)
        return SynchronizationResult(consent: consent, didWrite: true)
    }
}

private enum SharedTelemetryConsentStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "App Group '\(SharedTelemetryConsentStore.appGroupIdentifier)' is unavailable"
    }
}

/// Publishes Chromium's live metrics setting for Sentinel without becoming a
/// second owner of the preference.
final class SentinelTelemetryConsentPublisher {
    static let shared: SentinelTelemetryConsentPublisher = {
        let channel = SentinelTelemetryConsentChannel.current
        let fileURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                SharedTelemetryConsentStore.appGroupIdentifier
        )?.appendingPathComponent(channel.filename)

        return SentinelTelemetryConsentPublisher(
            store: SharedTelemetryConsentStore(fileURL: fileURL),
            channel: channel,
            readMetricsReportingEnabled: {
                guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                    return nil
                }
                return bridge.isMetricsReportingEnabled()
            },
            postNotification: { notificationName in
                DistributedNotificationCenter.default().postNotificationName(
                    notificationName,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        )
    }()

    private let store: SharedTelemetryConsentStore
    private let channel: SentinelTelemetryConsentChannel
    private let pollInterval: TimeInterval
    private let readMetricsReportingEnabled: () -> Bool?
    private let makeRevision: () -> UUID
    private let now: () -> Date
    private let postNotification: (Notification.Name) -> Void

    private var timer: Timer?
    private var lastPersistenceError: String?

    init(
        store: SharedTelemetryConsentStore,
        channel: SentinelTelemetryConsentChannel,
        pollInterval: TimeInterval = 1,
        readMetricsReportingEnabled: @escaping () -> Bool?,
        makeRevision: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        postNotification: @escaping (Notification.Name) -> Void
    ) {
        self.store = store
        self.channel = channel
        self.pollInterval = pollInterval
        self.readMetricsReportingEnabled = readMetricsReportingEnabled
        self.makeRevision = makeRevision
        self.now = now
        self.postNotification = postNotification
    }

    func start() {
        guard timer == nil else { return }

        refreshNow()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        // Capture a setting change made during the final polling interval while
        // Chromium's bridge is still alive. Sentinel can outlive the browser,
        // so leaving the previous enabled revision behind would violate opt-out.
        refreshNow()
        timer?.invalidate()
        timer = nil
    }

    /// Returns whether this refresh durably changed the shared snapshot.
    /// A temporarily unavailable bridge produces no write: an absent file is
    /// fail-closed for consumers, while an existing revision remains intact.
    @discardableResult
    func refreshNow() -> Bool {
        guard let enabled = readMetricsReportingEnabled() else { return false }

        do {
            let result = try store.synchronize(
                enabled: enabled,
                makeRevision: makeRevision,
                now: now
            )
            lastPersistenceError = nil
            guard result.didWrite else { return false }

            postNotification(channel.notificationName)
            return true
        } catch {
            let description = error.localizedDescription
            if description != lastPersistenceError {
                AppLogError(
                    "Failed to persist shared telemetry consent: \(description)"
                )
                lastPersistenceError = description
            }
            return false
        }
    }
}

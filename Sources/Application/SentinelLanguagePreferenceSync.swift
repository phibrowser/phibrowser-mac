// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SentinelLanguagePreferenceChannel: Equatable {
    let filename: String
    let notificationName: Notification.Name

    static let current = make(
        browserBundleIdentifier: Bundle.main.bundleIdentifier
    )

    static func make(browserBundleIdentifier: String?) -> Self {
        if browserBundleIdentifier?.lowercased().contains("canary") == true {
            return Self(
                filename: "app-language-preference-canary.plist",
                notificationName: Notification.Name(
                    "com.phibrowser.canary.appLanguagePreferenceDidChange"
                )
            )
        }

        return Self(
            filename: "app-language-preference.plist",
            notificationName: Notification.Name(
                "com.phibrowser.appLanguagePreferenceDidChange"
            )
        )
    }
}

/// The language contract shared between Phi and Sentinel.
///
/// `selection` preserves whether the user follows macOS, while
/// `resolvedLanguage` gives Sentinel the canonical language to apply without
/// trying to resolve Phi's per-app language preference in Sentinel's process.
struct SharedAppLanguagePreference: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selection: String
    let resolvedLanguage: String

    init(
        preference: AppLanguagePreference,
        resolvedLanguage: SupportedAppLanguage
    ) {
        schemaVersion = Self.currentSchemaVersion
        selection = preference.storageValue
        self.resolvedLanguage = resolvedLanguage.rawValue
    }

    var userInfo: [String: Any] {
        [
            CodingKeys.schemaVersion.rawValue: schemaVersion,
            CodingKeys.selection.rawValue: selection,
            CodingKeys.resolvedLanguage.rawValue: resolvedLanguage,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion"
        case selection = "Selection"
        case resolvedLanguage = "ResolvedLanguage"
    }
}

final class SharedAppLanguagePreferenceStore {
    static let appGroupIdentifier = "group.com.phibrowser.shared"

    static let shared = SharedAppLanguagePreferenceStore(fileURL: sharedFileURL)

    private static let sharedFileURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )?.appendingPathComponent(SentinelLanguagePreferenceChannel.current.filename)

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func write(_ preference: SharedAppLanguagePreference) throws {
        guard let fileURL else {
            throw SharedAppLanguagePreferenceStoreError.appGroupUnavailable
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(preference)
        try data.write(to: fileURL, options: .atomic)
    }

    func read() throws -> SharedAppLanguagePreference {
        guard let fileURL else {
            throw SharedAppLanguagePreferenceStoreError.appGroupUnavailable
        }

        let data = try Data(contentsOf: fileURL)
        return try PropertyListDecoder().decode(
            SharedAppLanguagePreference.self,
            from: data
        )
    }
}

private enum SharedAppLanguagePreferenceStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "App Group '\(SharedAppLanguagePreferenceStore.appGroupIdentifier)' is unavailable"
    }
}

enum SentinelLanguagePreferenceSync {
    enum TerminationSyncResult: Equatable {
        case unchanged
        case metadataChanged
        case languageChanged
        case failed
    }

    /// Keeps a durable snapshot for Sentinel and emits a change event. The
    /// startup event covers language changes made in macOS System Settings,
    /// which do not pass through Phi's settings picker.
    static func persistCurrentPreference() {
        synchronize(
            PhiPreferences.GeneralSettings.loadAppLanguagePreference(),
            notifySentinel: true
        )
    }

    /// Reconciles the current language with the last snapshot before Phi
    /// terminates. Sentinel is restarted only when its resolved language has
    /// changed; a selection-only change does not require a UI restart.
    @discardableResult
    static func synchronizeCurrentPreferenceBeforeTermination(
        store: SharedAppLanguagePreferenceStore = .shared,
        defaults: UserDefaults = .standard,
        applicationDomainName: String? = nil,
        systemPreferredLanguages: [String] = Locale.preferredLanguages
    ) -> TerminationSyncResult {
        guard !PhiBuildCapabilities.usesAthenaCanary else { return .unchanged }
        let preference = PhiPreferences.GeneralSettings.loadAppLanguagePreference(
            from: defaults
        )
        let current = makeSharedPreference(
            for: preference,
            from: defaults,
            applicationDomainName: applicationDomainName,
            systemPreferredLanguages: systemPreferredLanguages
        )

        do {
            let persisted = try store.read()
            guard persisted != current else { return .unchanged }

            try store.write(current)
            return persisted.resolvedLanguage == current.resolvedLanguage
                ? .metadataChanged
                : .languageChanged
        } catch {
            AppLogWarn(
                "Failed to synchronize shared app language preference before termination: " +
                    error.localizedDescription
            )
            return .failed
        }
    }

    /// Writes the new value and notifies the matching Sentinel channel. The
    /// notification carries the same payload so either transport can recover
    /// independently if the other is unavailable.
    static func publish(_ preference: AppLanguagePreference) {
        synchronize(preference, notifySentinel: true)
    }

    private static func synchronize(
        _ preference: AppLanguagePreference,
        notifySentinel: Bool
    ) {
        guard !PhiBuildCapabilities.usesAthenaCanary else { return }
        let sharedPreference = makeSharedPreference(for: preference)

        do {
            try SharedAppLanguagePreferenceStore.shared.write(sharedPreference)
        } catch {
            AppLogError(
                "Failed to persist shared app language preference: \(error.localizedDescription)"
            )
        }

        guard notifySentinel else { return }

        DistributedNotificationCenter.default().postNotificationName(
            SentinelLanguagePreferenceChannel.current.notificationName,
            object: nil,
            userInfo: sharedPreference.userInfo,
            deliverImmediately: true
        )
    }

    private static func makeSharedPreference(
        for preference: AppLanguagePreference,
        from defaults: UserDefaults = .standard,
        applicationDomainName: String? = nil,
        systemPreferredLanguages: [String] = Locale.preferredLanguages
    ) -> SharedAppLanguagePreference {
        let resolvedLanguage = PhiPreferences.GeneralSettings.resolvedAppLanguage(
            for: preference,
            from: defaults,
            applicationDomainName: applicationDomainName,
            systemPreferredLanguages: systemPreferredLanguages
        )

        return SharedAppLanguagePreference(
            preference: preference,
            resolvedLanguage: resolvedLanguage
        )
    }
}

@MainActor
enum SentinelLanguagePreferenceTerminationCoordinator {
    @discardableResult
    static func prepareForPhiTermination() -> SentinelLanguagePreferenceSync.TerminationSyncResult {
        prepareForPhiTermination(
            synchronizePreference: {
                SentinelLanguagePreferenceSync.synchronizeCurrentPreferenceBeforeTermination()
            },
            stopSentinelWatchdog: {
                SentinelWatchdog.shared.stop()
            },
            terminateSentinel: {
                SentinelHelper.requestTerminationForBrowserUpdate()
            }
        )
    }

    @discardableResult
    static func prepareForPhiTermination(
        synchronizePreference: () -> SentinelLanguagePreferenceSync.TerminationSyncResult,
        stopSentinelWatchdog: () -> Void,
        terminateSentinel: () -> Void
    ) -> SentinelLanguagePreferenceSync.TerminationSyncResult {
        let result = synchronizePreference()
        guard result == .languageChanged else { return result }

        stopSentinelWatchdog()
        terminateSentinel()
        return result
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

// MARK: - Pure-value migration records

struct GuestDataMigrationThemeSnapshot: Codable, Equatable, Sendable {
    var themeIDs: [String: String]
    var saturations: [String: [String: Double]]
    var pureSliderValues: [String: Double]

    static let empty = GuestDataMigrationThemeSnapshot(
        themeIDs: [:],
        saturations: [:],
        pureSliderValues: [:]
    )

    init(
        themeIDs: [String: String],
        saturations: [String: [String: Double]],
        pureSliderValues: [String: Double]
    ) {
        self.themeIDs = themeIDs
        self.saturations = saturations
        self.pureSliderValues = pureSliderValues
    }

    init(userDefaults: AccountUserDefaults) {
        self = userDefaults.guestDataMigrationThemeSnapshot()
    }

    func retaining(spaceIDs: Set<String>) -> GuestDataMigrationThemeSnapshot {
        GuestDataMigrationThemeSnapshot(
            themeIDs: themeIDs.filter { spaceIDs.contains($0.key) },
            saturations: saturations.filter { spaceIDs.contains($0.key) },
            pureSliderValues: pureSliderValues.filter { spaceIDs.contains($0.key) }
        )
    }
}

struct GuestDataMigrationProfileRecord: Codable, Equatable, Sendable {
    let guid: String
    let profileID: String
    let displayName: String?
}

struct GuestDataMigrationSpaceRecord: Codable, Equatable, Sendable {
    let spaceID: String
    let profileID: String
    let name: String
    let colorHex: String
    let iconName: String
    let sortOrder: Int
    let createdDate: Date
    let updatedDate: Date
}

struct GuestDataMigrationBookmarkRecord: Codable, Equatable, Sendable {
    let guid: String
    let parentGUID: String?
    let profileID: String
    let spaceID: String
    let title: String
    let index: Int
    let url: URL
    let favicon: Data?
    let icon: String?
    let createdDate: Date
    let updatedDate: Date
    let type: Int
    let overrideTitle: String?
    let isOpened: Bool
    let isCreatedByChromium: Bool
    let needsMetadataUpdate: Bool
    let source: Int
    let secondaryURL: URL?
    let secondaryTitle: String?
    let layout: String?
    let lastSeen: Date?
}

struct GuestDataMigrationPinnedTabRecord: Codable, Equatable, Sendable {
    let guid: String
    let profileID: String?
    let spaceID: String?
    let title: String
    let index: Int
    let url: URL
    let favicon: Data?
    let icon: String?
    let createdDate: Date
    let updatedDate: Date
    let overrideTitle: String?
    let isOpened: Bool
    let isCreatedByChromium: Bool
    let needsMetadataUpdate: Bool
    let source: Int
    let secondaryURL: URL?
    let secondaryTitle: String?
    let splitPartnerGUID: String?
    let layout: String?
    let lastSeen: Date?
    let lineageID: String
    let isDormant: Bool
}

struct GuestDataMigrationURLRuleRecord: Codable, Equatable, Sendable {
    let id: String
    let spaceID: String
    let host: String
    let pathPrefix: String?
    let askBeforeRouting: Bool
    let sortOrder: Int
    let createdDate: Date
}

struct GuestDataMigrationSnapshot: Codable, Equatable, Sendable {
    let snapshotID: UUID
    let sourceUserID: String
    let capturedAt: Date
    let sourcePinnedTabScopeRawValue: String
    let profiles: [GuestDataMigrationProfileRecord]
    let spaces: [GuestDataMigrationSpaceRecord]
    let bookmarks: [GuestDataMigrationBookmarkRecord]
    let pinnedTabs: [GuestDataMigrationPinnedTabRecord]
    let urlRules: [GuestDataMigrationURLRuleRecord]
    let themes: GuestDataMigrationThemeSnapshot

    /// Snapshot identity and capture time intentionally change on every read.
    /// Cleanup safety depends on the migratable payload being unchanged, not
    /// on those two journal metadata fields.
    func hasSameMigratableContent(
        as other: GuestDataMigrationSnapshot
    ) -> Bool {
        sourceUserID == other.sourceUserID
            && sourcePinnedTabScopeRawValue
                == other.sourcePinnedTabScopeRawValue
            && profiles == other.profiles
            && spaces == other.spaces
            && bookmarks == other.bookmarks
            && pinnedTabs == other.pinnedTabs
            && urlRules == other.urlRules
            && themes == other.themes
    }
}

struct GuestDataMigrationPinnedTarget: Codable, Equatable, Sendable {
    let sourceGUID: String
    let targetGUID: String
    let targetProfileID: String?
    let targetSpaceID: String?
    let targetIndex: Int
    let targetSplitPartnerGUID: String?
    let shouldInsert: Bool
    let isDormant: Bool
}

struct GuestDataMigrationURLRuleTarget: Codable, Equatable, Sendable {
    let sourceID: String
    let targetID: String
    let targetSpaceID: String
    let targetSortOrder: Int
}

struct GuestDataMigrationSkippedURLRule: Codable, Equatable, Sendable {
    let sourceID: String
    let targetSpaceID: String
    let host: String
    let pathPrefix: String?
}

struct GuestDataMigrationIdentifierMappings: Codable, Equatable, Sendable {
    let profileIDs: [String: String]
    let spaceIDs: [String: String]
    let bookmarkGUIDs: [String: String]
    let pinnedTargets: [GuestDataMigrationPinnedTarget]
    let pinLineageIDs: [String: String]
    let urlRuleTargets: [GuestDataMigrationURLRuleTarget]
    let skippedURLRules: [GuestDataMigrationSkippedURLRule]
    let defaultImportFolderGUID: String?
    let targetPinnedTabScopeRawValue: String
    let targetSpaceProfileIDs: [String: String]
    let insertedProfileIDs: [String]
    let insertedSpaceIDs: [String]

    /// One-to-one model mappings used by bookmark and simple window replay
    /// callers. Pinned rows may fan out into more than one target owner, so
    /// consumers must use `pinnedTargets(for:)` for those.
    var modelGUIDs: [String: String] {
        var result = bookmarkGUIDs
        for mapping in pinnedTargets where result[mapping.sourceGUID] == nil {
            result[mapping.sourceGUID] = mapping.targetGUID
        }
        return result
    }

    var urlRuleIDs: [String: String] {
        Dictionary(uniqueKeysWithValues: urlRuleTargets.map {
            ($0.sourceID, $0.targetID)
        })
    }

    func pinnedTargets(for sourceGUID: String) -> [GuestDataMigrationPinnedTarget] {
        pinnedTargets.filter { $0.sourceGUID == sourceGUID }
    }

    func pinnedTarget(
        for sourceGUID: String,
        profileID: String?,
        spaceID: String?
    ) -> GuestDataMigrationPinnedTarget? {
        pinnedTargets.first {
            $0.sourceGUID == sourceGUID &&
            $0.targetProfileID == profileID &&
            $0.targetSpaceID == spaceID
        }
    }
}

struct GuestDataMigrationReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let sourceUserID: String
    let targetUserID: String
    let snapshotID: UUID
    let completedAt: Date
    let mappings: GuestDataMigrationIdentifierMappings
    let targetThemes: GuestDataMigrationThemeSnapshot

    var modelGUIDs: [String: String] { mappings.modelGUIDs }
    var spaceIDs: [String: String] { mappings.spaceIDs }
    var profileIDs: [String: String] { mappings.profileIDs }
}

enum GuestDataMigrationJournalPhase: String, Codable, Sendable {
    case prepared
    case targetImported
    case sourceDirectoryStaged
}

struct GuestDataMigrationJournal: Codable, Equatable, Sendable {
    let operationID: UUID
    let sourceUserID: String
    let targetUserID: String
    let snapshot: GuestDataMigrationSnapshot
    let mappings: GuestDataMigrationIdentifierMappings
    var phase: GuestDataMigrationJournalPhase
    var receipt: GuestDataMigrationReceipt?
}

enum GuestDataMigrationError: LocalizedError, Equatable {
    case sourceMustBeDefaultAccount
    case targetCannotBeDefaultAccount
    case pendingMigrationTargetsAnotherAccount(expected: String, actual: String)
    case pendingMigrationHasUnexpectedSource(expected: String, actual: String)
    case corruptJournal
    case corruptReceipt
    case targetStateConflict(String)
    case verificationFailed(String)
    case targetImportRequiresRecovery(String)
    case sourceDataChangedAfterSnapshot
    case sourceDataCreatedAfterStaging

    var requiresTargetRecovery: Bool {
        if case .targetImportRequiresRecovery = self {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .sourceMustBeDefaultAccount:
            return "Guest data migration must start from the default account."
        case .targetCannotBeDefaultAccount:
            return "Guest data migration requires a signed-in target account."
        case .pendingMigrationTargetsAnotherAccount(let expected, let actual):
            return "A pending Guest migration belongs to \(expected), not \(actual)."
        case .pendingMigrationHasUnexpectedSource(let expected, let actual):
            return "A pending Guest migration starts from \(expected), not \(actual)."
        case .corruptJournal:
            return "The Guest migration journal could not be decoded."
        case .corruptReceipt:
            return "The Guest migration receipt could not be decoded."
        case .targetStateConflict(let detail):
            return "The target account changed during Guest migration: \(detail)"
        case .verificationFailed(let detail):
            return "Guest migration verification failed: \(detail)"
        case .targetImportRequiresRecovery(let detail):
            return "Guest data reached the target account, but setup still needs recovery: \(detail)"
        case .sourceDataChangedAfterSnapshot:
            return "Guest data changed after it was imported. The source data was preserved and must be migrated before cleanup."
        case .sourceDataCreatedAfterStaging:
            return "New Guest data appeared after directory cleanup was staged. Resume the pending migration before finalizing it."
        }
    }
}

enum GuestDataMigrationTargetImportPresence: Equatable {
    case absent
    case complete
    case partial(String)
}

/// Whether a pending migration journal permits a writable Guest session.
///
/// Once target import starts, the original Guest directory is terminal. A
/// staged, identity-derived tombstone proves that any directory now present at
/// the normal Guest path is a later Guest session. Without that proof, Guest
/// access must stay sealed until the journal-bound account resumes recovery.
enum GuestDataMigrationGuestAccessDisposition: Equatable {
    case unrestricted
    case deferredCleanup(targetUserID: String)
    case requiresTargetRecovery(targetUserID: String?)
}

// MARK: - Durable journal and receipt stores

struct GuestDataMigrationJournalStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static var live: GuestDataMigrationJournalStore {
        GuestDataMigrationJournalStore(
            rootURL: URL(
                fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(),
                isDirectory: true
            ).appendingPathComponent("guestDataMigration", isDirectory: true)
        )
    }

    private var journalURL: URL {
        rootURL.appendingPathComponent("pending.json")
    }

    func load() throws -> GuestDataMigrationJournal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                GuestDataMigrationJournal.self,
                from: Data(contentsOf: journalURL)
            )
        } catch {
            throw GuestDataMigrationError.corruptJournal
        }
    }

    func write(_ journal: GuestDataMigrationJournal) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    func remove(operationID: UUID) throws {
        guard let existing = try load() else { return }
        guard existing.operationID == operationID else {
            throw GuestDataMigrationError.targetStateConflict(
                "the pending operation identifier no longer matches"
            )
        }
        try FileManager.default.removeItem(at: journalURL)
    }
}

struct GuestDataMigrationReceiptStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    init(targetAccount: Account) {
        self.init(
            rootURL: targetAccount.userDataStorage
                .appendingPathComponent("guestDataMigrations", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true)
        )
    }

    func load(operationID: UUID) throws -> GuestDataMigrationReceipt? {
        let url = receiptURL(operationID: operationID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                GuestDataMigrationReceipt.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw GuestDataMigrationError.corruptReceipt
        }
    }

    func write(_ receipt: GuestDataMigrationReceipt) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(
            to: receiptURL(operationID: receipt.operationID),
            options: .atomic
        )
    }

    private func receiptURL(operationID: UUID) -> URL {
        rootURL.appendingPathComponent("\(operationID.uuidString.lowercased()).json")
    }
}

// MARK: - Coordinator

enum GuestDataMigrationCoordinator {
    /// Inspects the live journal without opening the Guest LocalStore.
    ///
    /// This is used before granting browser access. Merely constructing a
    /// LocalStore at this point could recreate a directory that an interrupted
    /// migration already moved to its cleanup tombstone.
    static func pendingGuestAccessDisposition()
        throws -> GuestDataMigrationGuestAccessDisposition {
        let sourceDirectory = AccountController.defaultAccount
            .userDataStorage
            .standardizedFileURL
        return try pendingGuestAccessDisposition(
            sourceDirectory: sourceDirectory,
            journalStore: .live
        )
    }

    static func pendingGuestAccessDisposition(
        sourceDirectory: URL,
        journalStore: GuestDataMigrationJournalStore,
        fileManager: FileManager = .default
    ) throws -> GuestDataMigrationGuestAccessDisposition {
        guard let journal = try journalStore.load() else {
            return .unrestricted
        }
        guard journal.sourceUserID == Account.defaultUid else {
            return .requiresTargetRecovery(
                targetUserID: journal.targetUserID.isEmpty
                    ? nil
                    : journal.targetUserID
            )
        }

        let paths = sourceDirectoryCleanupPaths(
            sourceDirectory: sourceDirectory,
            operationID: journal.operationID
        )
        return classifyPendingGuestAccess(
            journalPhase: journal.phase,
            targetUserID: journal.targetUserID,
            sourceDirectoryExists: fileManager.fileExists(
                atPath: paths.source.path
            ),
            tombstoneExists: fileManager.fileExists(
                atPath: paths.tombstone.path
            )
        )
    }

    static func classifyPendingGuestAccess(
        journalPhase: GuestDataMigrationJournalPhase,
        targetUserID: String,
        sourceDirectoryExists: Bool,
        tombstoneExists: Bool
    ) -> GuestDataMigrationGuestAccessDisposition {
        let recoveryTarget = targetUserID.isEmpty ? nil : targetUserID

        switch journalPhase {
        case .prepared:
            return .requiresTargetRecovery(targetUserID: recoveryTarget)
        case .targetImported:
            if tombstoneExists {
                return recoveryTarget.map {
                    .deferredCleanup(targetUserID: $0)
                } ?? .requiresTargetRecovery(targetUserID: nil)
            }
            // The source-only state is the imported, terminal Guest directory.
            // If both paths are absent, filesystem state is inconsistent and
            // must also fail closed.
            if sourceDirectoryExists {
                return .requiresTargetRecovery(
                    targetUserID: recoveryTarget
                )
            }
            return .requiresTargetRecovery(targetUserID: recoveryTarget)
        case .sourceDirectoryStaged:
            return recoveryTarget.map {
                .deferredCleanup(targetUserID: $0)
            } ?? .requiresTargetRecovery(targetUserID: nil)
        }
    }

    /// Moves Native Guest data into an authenticated account without
    /// publishing that account. The source LocalStore is drained, snapshotted,
    /// and closed before target planning starts. The caller owns the
    /// surrounding UI freeze. An ordinary error guarantees that a prepared
    /// journal was discarded because the target remained untouched and a
    /// fresh writable default account is installed. A
    /// `targetImportRequiresRecovery` error means target data may already
    /// exist: keep Guest sealed and retry the same target. After success,
    /// publish and rebind `targetAccount`.
    static func migrate(
        sourceAccount: Account = AccountController.defaultAccount,
        targetAccount: Account
    ) async throws -> GuestDataMigrationReceipt {
        guard sourceAccount.userID == Account.defaultUid else {
            throw GuestDataMigrationError.sourceMustBeDefaultAccount
        }
        guard targetAccount.userID != Account.defaultUid else {
            throw GuestDataMigrationError.targetCannotBeDefaultAccount
        }

        let journalStore = GuestDataMigrationJournalStore.live
        let receiptStore = GuestDataMigrationReceiptStore(
            targetAccount: targetAccount
        )
        do {
            // Recovery inspection belongs inside the same fail-closed
            // classification boundary as snapshot/import. An unreadable
            // journal may describe a target import or a staged source
            // directory, so it must never escape as an ordinary error that
            // lets LoginController reopen editable Guest data.
            if let stagedReceipt = try await recoverStagedCleanupIfNeeded(
                sourceUserID: sourceAccount.userID,
                targetUserID: targetAccount.userID,
                targetStore: targetAccount.localStorage,
                targetDefaults: targetAccount.userDefaults,
                sourceDirectory: sourceAccount.userDataStorage,
                journalStore: journalStore,
                receiptStore: receiptStore
            ) {
                return stagedReceipt
            }

            let sourceStore = sourceAccount.localStorage
            let sourceAlreadySealed = await MainActor.run {
                sourceStore.isClosedForAccountDirectoryRemoval
            }
            let receipt = try await migrate(
                sourceStore: sourceStore,
                sourceDefaults: sourceAccount.userDefaults,
                sourceUserID: sourceAccount.userID,
                targetStore: targetAccount.localStorage,
                targetDefaults: targetAccount.userDefaults,
                targetUserID: targetAccount.userID,
                journalStore: journalStore,
                receiptStore: receiptStore,
                sourceAlreadySealed: sourceAlreadySealed
            )
            return receipt
        } catch let originalError {
            let canResumeGuest: Bool
            do {
                canResumeGuest =
                    try await discardPreparedMigrationIfTargetUntouched(
                        targetStore: targetAccount.localStorage,
                        targetUserID: targetAccount.userID,
                        journalStore: journalStore
                    )
            } catch {
                throw GuestDataMigrationError.targetImportRequiresRecovery(
                    error.localizedDescription
                )
            }

            guard canResumeGuest else {
                if let migrationError =
                    originalError as? GuestDataMigrationError,
                   migrationError.requiresTargetRecovery {
                    throw migrationError
                }
                throw GuestDataMigrationError.targetImportRequiresRecovery(
                    originalError.localizedDescription
                )
            }

            // The source store is terminal once its FIFO snapshot is taken.
            // Target absence makes it safe to abandon that snapshot and let
            // the caller rebuild Guest controllers over the intact directory.
            await MainActor.run {
                _ = refreshedGuestAccount(afterSealing: sourceAccount)
            }
            throw originalError
        }
    }

    /// Replaces a terminal Guest account only after the coordinator confirms
    /// that no target import exists. Callers must rebuild Guest controllers
    /// with the returned account before restoring interaction.
    @MainActor
    static func refreshedGuestAccount(afterSealing sourceAccount: Account)
        -> Account {
        if AccountController.defaultAccount === sourceAccount {
            AccountController.defaultAccount = Account.defaultAccount
        }
        return AccountController.defaultAccount
    }

    /// Removes a prepared snapshot only when none of its planned identifiers
    /// reached the intended target. This is the sole path that may return a
    /// failed migration to editable Guest Mode.
    ///
    /// A completed/partial import, a later journal phase, an identity
    /// mismatch, or an unreadable target all require same-target recovery and
    /// deliberately retain the journal.
    static func discardPreparedMigrationIfTargetUntouched(
        targetStore: LocalStore,
        targetUserID: String,
        journalStore: GuestDataMigrationJournalStore
    ) async throws -> Bool {
        guard let journal = try journalStore.load() else {
            // Target import is sequenced strictly after the prepared journal
            // is durable, so no journal means this attempt failed earlier.
            return true
        }
        guard targetStore.account.userID == targetUserID else {
            throw GuestDataMigrationError
                .pendingMigrationTargetsAnotherAccount(
                    expected: targetUserID,
                    actual: targetStore.account.userID
                )
        }
        guard journal.targetUserID == targetUserID,
              journal.phase == .prepared else {
            return false
        }

        switch try await targetStore.guestDataMigrationImportPresence(
            mappings: journal.mappings
        ) {
        case .absent:
            try journalStore.remove(operationID: journal.operationID)
            return true
        case .complete, .partial:
            return false
        }
    }

    /// Resolves the crash seam after the Guest directory was atomically
    /// renamed but before its tombstone and journal were removed.
    ///
    /// If no source directory exists, the verified receipt is returned so the
    /// caller can finish deleting the tombstone. If a new source directory
    /// exists, it contains post-snapshot Guest data: the old verified
    /// tombstone and journal are retired, while the new directory is left
    /// untouched for a follow-up migration.
    static func recoverStagedCleanupIfNeeded(
        sourceUserID: String,
        targetUserID: String,
        targetStore: LocalStore,
        targetDefaults: AccountUserDefaults,
        sourceDirectory: URL,
        journalStore: GuestDataMigrationJournalStore,
        receiptStore: GuestDataMigrationReceiptStore
    ) async throws -> GuestDataMigrationReceipt? {
        guard var staged = try journalStore.load(),
              staged.phase == .targetImported
                || staged.phase == .sourceDirectoryStaged else {
            return nil
        }
        guard staged.sourceUserID == sourceUserID else {
            throw GuestDataMigrationError.pendingMigrationHasUnexpectedSource(
                expected: staged.sourceUserID,
                actual: sourceUserID
            )
        }
        guard staged.targetUserID == targetUserID else {
            throw GuestDataMigrationError.pendingMigrationTargetsAnotherAccount(
                expected: staged.targetUserID,
                actual: targetUserID
            )
        }
        guard let oldReceipt = staged.receipt,
              try receiptStore.load(operationID: staged.operationID)
                == oldReceipt else {
            throw GuestDataMigrationError.corruptReceipt
        }
        try await targetStore.verifyGuestDataMigrationReceipt(
            oldReceipt,
            snapshot: staged.snapshot
        )
        try verifyThemes(
            oldReceipt.targetThemes,
            mappedSpaceIDs: Set(oldReceipt.mappings.spaceIDs.values),
            in: targetDefaults
        )

        let paths = sourceDirectoryCleanupPaths(
            sourceDirectory: sourceDirectory,
            operationID: staged.operationID
        )
        let fileManager = FileManager.default
        let sourceExists = fileManager.fileExists(atPath: paths.source.path)
        let tombstoneExists = fileManager.fileExists(
            atPath: paths.tombstone.path
        )

        if staged.phase == .targetImported,
           sourceExists,
           !tombstoneExists {
            // Cleanup has not started yet. The regular migration retry seals
            // and verifies the still-live source before returning its receipt.
            return nil
        }

        guard sourceExists else {
            // `moveItem` necessarily precedes the staged journal write. A
            // crash between those operations leaves a targetImported journal
            // and only the identity-derived tombstone. Advance the durable
            // phase before returning so finalization never opens/recreates an
            // empty Guest source directory.
            if staged.phase == .targetImported {
                staged.phase = .sourceDirectoryStaged
                try journalStore.write(staged)
            }
            return oldReceipt
        }

        // Never remove the recreated source. Only the already imported,
        // identity-bound tombstone is eligible for deletion here.
        if tombstoneExists {
            try fileManager.removeItem(at: paths.tombstone)
        }
        try journalStore.remove(operationID: staged.operationID)
        return nil
    }

    static func pendingJournal() throws -> GuestDataMigrationJournal? {
        try GuestDataMigrationJournalStore.live.load()
    }

    /// Dependency-injected entry point used by focused store tests. Keeping
    /// the orchestration here also makes the recovery boundary explicit:
    /// target verification always precedes destructive source cleanup.
    static func migrate(
        sourceStore: LocalStore,
        sourceDefaults: AccountUserDefaults,
        sourceUserID: String,
        targetStore: LocalStore,
        targetDefaults: AccountUserDefaults,
        targetUserID: String,
        journalStore: GuestDataMigrationJournalStore,
        receiptStore: GuestDataMigrationReceiptStore,
        sourceAlreadySealed: Bool = false
    ) async throws -> GuestDataMigrationReceipt {
        let journal: GuestDataMigrationJournal
        if let pending = try journalStore.load() {
            guard pending.targetUserID == targetUserID else {
                throw GuestDataMigrationError.pendingMigrationTargetsAnotherAccount(
                    expected: pending.targetUserID,
                    actual: targetUserID
                )
            }
            guard pending.sourceUserID == sourceUserID else {
                throw GuestDataMigrationError.pendingMigrationHasUnexpectedSource(
                    expected: pending.sourceUserID,
                    actual: sourceUserID
                )
            }
            if !sourceAlreadySealed {
                let currentSnapshot = try await sourceStore
                    .makeGuestDataMigrationSnapshotAndClose(
                        sourceUserID: sourceUserID,
                        themes: GuestDataMigrationThemeSnapshot(
                            userDefaults: sourceDefaults
                        )
                    )
                guard currentSnapshot.hasSameMigratableContent(
                    as: pending.snapshot
                ) else {
                    // A synchronous launch recovery gate prevents Guest access
                    // while a journal exists. A mismatch therefore signals an
                    // invariant violation or out-of-process mutation; preserve
                    // both source and journal rather than risking data loss.
                    throw GuestDataMigrationError
                        .sourceDataChangedAfterSnapshot
                }
            }
            journal = pending
        } else {
            let allThemes = GuestDataMigrationThemeSnapshot(userDefaults: sourceDefaults)
            let snapshot = try await sourceStore
                .makeGuestDataMigrationSnapshotAndClose(
                    sourceUserID: sourceUserID,
                    themes: allThemes
                )
            let operationID = UUID()
            let mappings = try await targetStore.planGuestDataImport(
                snapshot,
                operationID: operationID
            )
            journal = GuestDataMigrationJournal(
                operationID: operationID,
                sourceUserID: sourceUserID,
                targetUserID: targetUserID,
                snapshot: snapshot,
                mappings: mappings,
                phase: .prepared,
                receipt: nil
            )
            try journalStore.write(journal)
        }

        var workingJournal = journal
        let receipt: GuestDataMigrationReceipt
        if let persistedReceipt = try receiptStore.load(operationID: journal.operationID) {
            guard persistedReceipt.sourceUserID == sourceUserID,
                  persistedReceipt.targetUserID == targetUserID,
                  persistedReceipt.snapshotID == journal.snapshot.snapshotID,
                  persistedReceipt.mappings == journal.mappings else {
                throw GuestDataMigrationError.corruptReceipt
            }
            receipt = persistedReceipt
        } else {
            try await targetStore.importGuestData(
                journal.snapshot,
                operationID: journal.operationID,
                targetUserID: targetUserID,
                mappings: journal.mappings
            )
            try targetDefaults.mergeGuestSpaceThemes(
                journal.snapshot.themes,
                spaceIDMappings: journal.mappings.spaceIDs
            )
            let targetThemes = GuestDataMigrationThemeSnapshot(
                userDefaults: targetDefaults
            ).retaining(spaceIDs: Set(journal.mappings.spaceIDs.values))
            receipt = GuestDataMigrationReceipt(
                operationID: journal.operationID,
                sourceUserID: sourceUserID,
                targetUserID: targetUserID,
                snapshotID: journal.snapshot.snapshotID,
                completedAt: Date(),
                mappings: journal.mappings,
                targetThemes: targetThemes
            )
            try await targetStore.verifyGuestDataMigrationReceipt(
                receipt,
                snapshot: journal.snapshot
            )
            try verifyThemes(
                receipt.targetThemes,
                mappedSpaceIDs: Set(receipt.mappings.spaceIDs.values),
                in: targetDefaults
            )
            try receiptStore.write(receipt)
        }

        try await targetStore.verifyGuestDataMigrationReceipt(
            receipt,
            snapshot: journal.snapshot
        )
        try verifyThemes(
            receipt.targetThemes,
            mappedSpaceIDs: Set(receipt.mappings.spaceIDs.values),
            in: targetDefaults
        )

        if workingJournal.phase == .prepared {
            workingJournal.phase = .targetImported
            workingJournal.receipt = receipt
            try journalStore.write(workingJournal)
        }

        // The source directory cannot be removed while Guest windows still
        // retain their LocalStore. Keep the identity-bound journal until the
        // window manager has rebound those consumers and explicitly calls
        // `finalizeSourceDirectoryCleanup`.
        return receipt
    }

    /// Completes the destructive filesystem half of Guest migration.
    ///
    /// The caller must first rebind or destroy every controller that retains
    /// `sourceAccount.localStorage`. `migrate` has already closed the Guest
    /// store at its final FIFO snapshot barrier. This method re-verifies the
    /// target, atomically stages the exact Guest directory, and only then
    /// deletes it and the journal. A staged directory and the journal are
    /// intentionally retained when deletion fails, so retry never imports
    /// duplicate target data.
    static func finalizeSourceDirectoryCleanup(
        receipt: GuestDataMigrationReceipt,
        sourceAccount: Account = AccountController.defaultAccount,
        targetAccount: Account
    ) async throws {
        guard sourceAccount.userID == Account.defaultUid else {
            throw GuestDataMigrationError.sourceMustBeDefaultAccount
        }
        guard targetAccount.userID == receipt.targetUserID,
              targetAccount.userID != Account.defaultUid else {
            throw GuestDataMigrationError.pendingMigrationTargetsAnotherAccount(
                expected: receipt.targetUserID,
                actual: targetAccount.userID
            )
        }

        let sourceDirectory = sourceAccount.userDataStorage.standardizedFileURL
        let usersDirectory = sourceDirectory.deletingLastPathComponent()
        guard sourceDirectory.lastPathComponent == Account.defaultUid,
              usersDirectory.lastPathComponent == "users" else {
            throw GuestDataMigrationError.sourceMustBeDefaultAccount
        }

        do {
            try await finalizeSourceDirectoryCleanup(
                receipt: receipt,
                sourceUserID: sourceAccount.userID,
                sourceDirectory: sourceDirectory,
                targetStore: targetAccount.localStorage,
                targetDefaults: targetAccount.userDefaults,
                targetUserID: targetAccount.userID,
                journalStore: .live,
                receiptStore: GuestDataMigrationReceiptStore(
                    targetAccount: targetAccount
                )
            )
        } catch {
            // Cleanup may already have crossed the terminal LocalStore
            // barrier. Preserve the directory and install a fresh lazy
            // account object so a same-target recovery attempt can read it.
            await MainActor.run {
                if AccountController.defaultAccount === sourceAccount {
                    AccountController.defaultAccount = Account.defaultAccount
                }
            }
            throw error
        }

        await MainActor.run {
            if AccountController.defaultAccount === sourceAccount {
                AccountController.defaultAccount = Account.defaultAccount
            }
        }
    }

    /// Dependency-injected cleanup entry point used by filesystem recovery
    /// tests. The production wrapper above supplies the exact default-account
    /// directory and resets its stable account object after cleanup.
    static func finalizeSourceDirectoryCleanup(
        receipt: GuestDataMigrationReceipt,
        sourceUserID: String,
        sourceDirectory: URL,
        targetStore: LocalStore,
        targetDefaults: AccountUserDefaults,
        targetUserID: String,
        journalStore: GuestDataMigrationJournalStore,
        receiptStore: GuestDataMigrationReceiptStore
    ) async throws {
        guard sourceUserID == receipt.sourceUserID else {
            throw GuestDataMigrationError.pendingMigrationHasUnexpectedSource(
                expected: receipt.sourceUserID,
                actual: sourceUserID
            )
        }
        guard targetUserID == receipt.targetUserID else {
            throw GuestDataMigrationError.pendingMigrationTargetsAnotherAccount(
                expected: receipt.targetUserID,
                actual: targetUserID
            )
        }

        guard var journal = try journalStore.load(),
              journal.operationID == receipt.operationID,
              journal.sourceUserID == receipt.sourceUserID,
              journal.targetUserID == receipt.targetUserID,
              journal.snapshot.snapshotID == receipt.snapshotID,
              journal.receipt == receipt,
              journal.phase == .targetImported
                || journal.phase == .sourceDirectoryStaged else {
            throw GuestDataMigrationError.corruptJournal
        }

        guard try receiptStore.load(operationID: receipt.operationID) == receipt else {
            throw GuestDataMigrationError.corruptReceipt
        }
        try await targetStore.verifyGuestDataMigrationReceipt(
            receipt,
            snapshot: journal.snapshot
        )
        try verifyThemes(
            receipt.targetThemes,
            mappedSpaceIDs: Set(receipt.mappings.spaceIDs.values),
            in: targetDefaults
        )

        let paths = sourceDirectoryCleanupPaths(
            sourceDirectory: sourceDirectory,
            operationID: receipt.operationID
        )
        let sourceDirectory = paths.source
        let tombstone = paths.tombstone
        let fileManager = FileManager.default
        let sourceExists = fileManager.fileExists(atPath: sourceDirectory.path)
        let tombstoneExists = fileManager.fileExists(atPath: tombstone.path)
        if journal.phase == .sourceDirectoryStaged && sourceExists {
            throw GuestDataMigrationError.sourceDataCreatedAfterStaging
        }
        if sourceExists && tombstoneExists {
            throw GuestDataMigrationError.sourceDataCreatedAfterStaging
        }
        if sourceExists {
            try fileManager.moveItem(at: sourceDirectory, to: tombstone)
        }
        if journal.phase != .sourceDirectoryStaged {
            journal.phase = .sourceDirectoryStaged
            try journalStore.write(journal)
        }
        if fileManager.fileExists(atPath: tombstone.path) {
            try fileManager.removeItem(at: tombstone)
        }
        guard !fileManager.fileExists(atPath: sourceDirectory.path),
              !fileManager.fileExists(atPath: tombstone.path) else {
            throw GuestDataMigrationError.verificationFailed(
                "the staged Guest directory still exists"
            )
        }
        try journalStore.remove(operationID: receipt.operationID)
    }

    private static func verifyThemes(
        _ expected: GuestDataMigrationThemeSnapshot,
        mappedSpaceIDs: Set<String>,
        in userDefaults: AccountUserDefaults
    ) throws {
        let current = GuestDataMigrationThemeSnapshot(userDefaults: userDefaults)
            .retaining(spaceIDs: mappedSpaceIDs)
        guard current == expected else {
            throw GuestDataMigrationError.verificationFailed(
                "Space theme values do not match the durable receipt"
            )
        }
    }

    static func sourceDirectoryCleanupPaths(
        sourceDirectory: URL,
        operationID: UUID
    ) -> (source: URL, tombstone: URL) {
        let source = sourceDirectory.standardizedFileURL
        let tombstone = source.deletingLastPathComponent().appendingPathComponent(
            ".\(Account.defaultUid).guest-migration-\(operationID.uuidString.lowercased()).pending-delete",
            isDirectory: true
        )
        return (source, tombstone)
    }
}

// MARK: - LocalStore snapshot, planning, import, verification, and cleanup

private struct GuestMigrationPinnedOwner: Hashable {
    let profileID: String?
    let spaceID: String?

    var sortKey: String {
        "\(profileID ?? "")\u{0}\(spaceID ?? "")"
    }
}

private struct GuestMigrationPinnedContentSignature: Hashable {
    let title: String
    let url: URL
    let favicon: Data?
}

private struct GuestMigrationPinnedVariantSignature: Hashable {
    let content: GuestMigrationPinnedContentSignature
    let partnerLineageID: String?
    let partnerContent: GuestMigrationPinnedContentSignature?
}

private struct GuestMigrationPinnedVariantKey: Hashable {
    let lineageID: String
    let signature: GuestMigrationPinnedVariantSignature
}

private struct GuestMigrationProjectedPinKey: Hashable {
    let sourceGUID: String
    let owner: GuestMigrationPinnedOwner
}

extension LocalStore {
    func makeGuestDataMigrationSnapshot(
        sourceUserID: String,
        themes: GuestDataMigrationThemeSnapshot
    ) async throws -> GuestDataMigrationSnapshot {
        try await performBackgroundWriteAndWaitThrowing { context in
            try Self.makeGuestDataMigrationSnapshot(
                in: context,
                sourceUserID: sourceUserID,
                themes: themes
            )
        }
    }

    /// Captures the final Guest payload after every previously submitted
    /// write, then closes the source store as part of the same FIFO barrier.
    /// This removes the write race between freshness verification and the
    /// filesystem rename.
    @MainActor
    func makeGuestDataMigrationSnapshotAndClose(
        sourceUserID: String,
        themes: GuestDataMigrationThemeSnapshot
    ) async throws -> GuestDataMigrationSnapshot {
        try await performFinalBackgroundOperationAndClose { context in
            try Self.makeGuestDataMigrationSnapshot(
                in: context,
                sourceUserID: sourceUserID,
                themes: themes
            )
        }
    }

    private static func makeGuestDataMigrationSnapshot(
        in context: ModelContext,
        sourceUserID: String,
        themes: GuestDataMigrationThemeSnapshot
    ) throws -> GuestDataMigrationSnapshot {
            let storedProfiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let storedSpaces = try context.fetch(FetchDescriptor<SpaceModel>())
            let allModels = try context.fetch(FetchDescriptor<TabDataModel>())
            let allRules = try context.fetch(FetchDescriptor<SpaceURLRule>())

            let settingsID = BrowserDataSettingsModel.singletonId
            let settings = try context.fetch(
                FetchDescriptor<BrowserDataSettingsModel>(
                    predicate: #Predicate { $0.id == settingsID }
                )
            ).first
            let sourceScope = PinnedTabScope(
                rawValue: settings?.pinnedTabScopeRawValue ?? ""
            ) ?? .profile

            let bookmarkTypes = Set([
                TabDataType.bookmark.rawValue,
                TabDataType.bookmarkFolder.rawValue,
            ])
            let hiddenRootGUIDs = Set(
                storedProfiles.compactMap { $0.bookmarkRoot?.guid }
                    + storedSpaces.compactMap { $0.bookmarkRoot?.guid }
            )
            let bookmarkModels = allModels.filter {
                bookmarkTypes.contains($0.type) &&
                !hiddenRootGUIDs.contains($0.guid)
            }

            var referencedProfileIDs = Set(storedProfiles.map(\.profileId))
            var referencedSpaceIDs = Set(storedSpaces.map(\.spaceId))
            for model in allModels where bookmarkTypes.contains(model.type) || model.type == TabDataType.pinnedTab.rawValue {
                if let profileID = model.profileId ?? model.profile?.profileId {
                    referencedProfileIDs.insert(profileID)
                }
                if let spaceID = model.spaceId {
                    referencedSpaceIDs.insert(spaceID)
                } else if bookmarkTypes.contains(model.type) {
                    referencedSpaceIDs.insert(Self.defaultSpaceId)
                }
            }
            allRules.forEach { referencedSpaceIDs.insert($0.spaceId) }

            let storedSpaceIDs = Set(storedSpaces.map(\.spaceId))
            let missingCustomSpaceIDs = referencedSpaceIDs.subtracting(storedSpaceIDs)
                .subtracting([Self.defaultSpaceId])
            guard missingCustomSpaceIDs.isEmpty else {
                throw GuestDataMigrationError.targetStateConflict(
                    "Guest data references missing Spaces: \(missingCustomSpaceIDs.sorted().joined(separator: ", "))"
                )
            }

            var profiles = storedProfiles.map {
                GuestDataMigrationProfileRecord(
                    guid: $0.guid,
                    profileID: $0.profileId,
                    displayName: $0.displayName
                )
            }
            let storedProfileIDs = Set(profiles.map(\.profileID))
            for missingProfileID in referencedProfileIDs.subtracting(storedProfileIDs).sorted() {
                profiles.append(
                    GuestDataMigrationProfileRecord(
                        guid: missingProfileID,
                        profileID: missingProfileID,
                        displayName: nil
                    )
                )
            }
            profiles.sort {
                ($0.profileID, $0.guid) < ($1.profileID, $1.guid)
            }

            let spaces = storedSpaces.map {
                GuestDataMigrationSpaceRecord(
                    spaceID: $0.spaceId,
                    profileID: $0.profileId,
                    name: $0.name,
                    colorHex: $0.colorHex,
                    iconName: $0.iconName,
                    sortOrder: $0.sortOrder,
                    createdDate: $0.createdDate,
                    updatedDate: $0.updatedDate
                )
            }.sorted {
                ($0.sortOrder, $0.profileID, $0.createdDate, $0.spaceID) <
                ($1.sortOrder, $1.profileID, $1.createdDate, $1.spaceID)
            }

            let bookmarks = bookmarkModels.map { model in
                GuestDataMigrationBookmarkRecord(
                    guid: model.guid,
                    parentGUID: model.parent.flatMap {
                        hiddenRootGUIDs.contains($0.guid) ? nil : $0.guid
                    },
                    profileID: model.profileId
                        ?? model.profile?.profileId
                        ?? Self.defaultProfileId,
                    spaceID: model.spaceId ?? Self.defaultSpaceId,
                    title: model.title,
                    index: model.index,
                    url: model.url,
                    favicon: model.favicon,
                    icon: model.icon == "default" ? nil : model.icon,
                    createdDate: model.createdDate,
                    updatedDate: model.updatedDate,
                    type: model.type,
                    overrideTitle: model.overrideTitle,
                    isOpened: model.isOpenned,
                    isCreatedByChromium: model.isCreatedByChromium,
                    needsMetadataUpdate: model.needUpdateMetaData,
                    source: model.source,
                    secondaryURL: model.secondaryUrl,
                    secondaryTitle: model.secondaryTitle,
                    layout: model.layout,
                    lastSeen: model.lastSeen
                )
            }.sorted {
                ($0.spaceID, $0.profileID, $0.parentGUID ?? "", $0.index, $0.guid) <
                ($1.spaceID, $1.profileID, $1.parentGUID ?? "", $1.index, $1.guid)
            }

            let allPinned = allModels.filter {
                $0.type == TabDataType.pinnedTab.rawValue
            }
            let activePinned = allPinned.filter { model in
                Self.guestPinnedTab(model, belongsTo: sourceScope)
                    || (
                        sourceScope == .space
                        && model.isPinnedTabDormant
                        && Self.guestPinnedTab(model, belongsTo: .profile)
                    )
            }
            let pinnedTabs = activePinned.map { model in
                GuestDataMigrationPinnedTabRecord(
                    guid: model.guid,
                    profileID: model.profileId ?? model.profile?.profileId,
                    spaceID: model.spaceId,
                    title: model.title,
                    index: model.index,
                    url: model.url,
                    favicon: model.favicon,
                    icon: model.icon == "default" ? nil : model.icon,
                    createdDate: model.createdDate,
                    updatedDate: model.updatedDate,
                    overrideTitle: model.overrideTitle,
                    isOpened: model.isOpenned,
                    isCreatedByChromium: model.isCreatedByChromium,
                    needsMetadataUpdate: model.needUpdateMetaData,
                    source: model.source,
                    secondaryURL: model.secondaryUrl,
                    secondaryTitle: model.secondaryTitle,
                    splitPartnerGUID: model.splitPartnerGuid,
                    layout: model.layout,
                    lastSeen: model.lastSeen,
                    lineageID: model.pinLineageId ?? model.guid,
                    isDormant: model.isPinnedTabDormant
                )
            }.sorted {
                (
                    $0.profileID ?? "",
                    $0.spaceID ?? "",
                    $0.index,
                    $0.guid
                ) < (
                    $1.profileID ?? "",
                    $1.spaceID ?? "",
                    $1.index,
                    $1.guid
                )
            }

            let rules = allRules.map {
                GuestDataMigrationURLRuleRecord(
                    id: $0.id,
                    spaceID: $0.spaceId,
                    host: $0.host.lowercased(),
                    pathPrefix: Self.normalizedPathPrefix($0.pathPrefix),
                    askBeforeRouting: $0.askBeforeRouting,
                    sortOrder: $0.sortOrder,
                    createdDate: $0.createdDate
                )
            }.sorted {
                ($0.spaceID, $0.sortOrder, $0.createdDate, $0.id) <
                ($1.spaceID, $1.sortOrder, $1.createdDate, $1.id)
            }

            return GuestDataMigrationSnapshot(
                snapshotID: UUID(),
                sourceUserID: sourceUserID,
                capturedAt: Date(),
                sourcePinnedTabScopeRawValue: sourceScope.rawValue,
                profiles: profiles,
                spaces: spaces,
                bookmarks: bookmarks,
                pinnedTabs: pinnedTabs,
                urlRules: rules,
                themes: themes.retaining(spaceIDs: referencedSpaceIDs)
            )
    }

    func planGuestDataImport(
        _ snapshot: GuestDataMigrationSnapshot,
        operationID: UUID
    ) async throws -> GuestDataMigrationIdentifierMappings {
        try await performBackgroundWriteAndWaitThrowing { context in
            let targetProfiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let targetSpaces = try context.fetch(FetchDescriptor<SpaceModel>())
            let targetModels = try context.fetch(FetchDescriptor<TabDataModel>())
            let targetRules = try context.fetch(FetchDescriptor<SpaceURLRule>())
            let settingsID = BrowserDataSettingsModel.singletonId
            let settings = try context.fetch(
                FetchDescriptor<BrowserDataSettingsModel>(
                    predicate: #Predicate { $0.id == settingsID }
                )
            ).first
            let targetScope = PinnedTabScope(
                rawValue: settings?.pinnedTabScopeRawValue ?? ""
            ) ?? .profile

            let existingProfileIDs = Set(targetProfiles.map(\.profileId))
            var sourceProfileIDs = Set(snapshot.profiles.map(\.profileID))
            snapshot.spaces.forEach { sourceProfileIDs.insert($0.profileID) }
            snapshot.bookmarks.forEach { sourceProfileIDs.insert($0.profileID) }
            snapshot.pinnedTabs.compactMap(\.profileID).forEach {
                sourceProfileIDs.insert($0)
            }
            if sourceProfileIDs.isEmpty && !snapshot.pinnedTabs.isEmpty {
                sourceProfileIDs.insert(Self.defaultProfileId)
            }

            var profileIDs = Dictionary(
                uniqueKeysWithValues: sourceProfileIDs.sorted().map { ($0, $0) }
            )
            var insertedProfileIDs = sourceProfileIDs
                .subtracting(existingProfileIDs)
                .sorted()

            var usedSpaceIDs = Set(targetSpaces.map(\.spaceId))
            var spaceIDs: [String: String] = [:]
            var insertedSpaceIDs: [String] = []
            let orderedSourceSpaces = snapshot.spaces.sorted {
                ($0.sortOrder, $0.profileID, $0.createdDate, $0.spaceID) <
                ($1.sortOrder, $1.profileID, $1.createdDate, $1.spaceID)
            }
            for (index, space) in orderedSourceSpaces.enumerated() {
                if space.spaceID == Self.defaultSpaceId {
                    spaceIDs[space.spaceID] = Self.defaultSpaceId
                    if !usedSpaceIDs.contains(Self.defaultSpaceId) {
                        usedSpaceIDs.insert(Self.defaultSpaceId)
                        insertedSpaceIDs.append(Self.defaultSpaceId)
                    }
                    continue
                }
                let targetID: String
                if !usedSpaceIDs.contains(space.spaceID) {
                    targetID = space.spaceID
                } else {
                    targetID = Self.guestMigrationIdentifier(
                        operationID: operationID,
                        kind: "space",
                        index: index,
                        used: &usedSpaceIDs
                    )
                }
                spaceIDs[space.spaceID] = targetID
                usedSpaceIDs.insert(targetID)
                insertedSpaceIDs.append(targetID)
            }

            let needsImplicitDefaultSpace =
                snapshot.bookmarks.contains { $0.spaceID == Self.defaultSpaceId }
                || snapshot.urlRules.contains { $0.spaceID == Self.defaultSpaceId }
                || snapshot.themes.themeIDs[Self.defaultSpaceId] != nil
                || snapshot.themes.saturations[Self.defaultSpaceId] != nil
                || snapshot.themes.pureSliderValues[Self.defaultSpaceId] != nil
                || (
                    targetScope == .space
                    && !snapshot.pinnedTabs.isEmpty
                    && targetSpaces.isEmpty
                    && !spaceIDs.values.contains(Self.defaultSpaceId)
                )
            if needsImplicitDefaultSpace && spaceIDs[Self.defaultSpaceId] == nil {
                spaceIDs[Self.defaultSpaceId] = Self.defaultSpaceId
                if !usedSpaceIDs.contains(Self.defaultSpaceId) {
                    usedSpaceIDs.insert(Self.defaultSpaceId)
                    insertedSpaceIDs.append(Self.defaultSpaceId)
                }
            }

            if needsImplicitDefaultSpace,
               profileIDs[Self.defaultProfileId] == nil,
               targetSpaces.first(where: { $0.spaceId == Self.defaultSpaceId }) == nil {
                profileIDs[Self.defaultProfileId] = Self.defaultProfileId
                if !existingProfileIDs.contains(Self.defaultProfileId) {
                    insertedProfileIDs.append(Self.defaultProfileId)
                }
            }
            insertedProfileIDs = Array(Set(insertedProfileIDs)).sorted()
            var seenInsertedSpaceIDs: Set<String> = []
            insertedSpaceIDs = insertedSpaceIDs.filter {
                seenInsertedSpaceIDs.insert($0).inserted
            }

            var targetSpaceProfileIDs = Dictionary(
                uniqueKeysWithValues: targetSpaces.map {
                    ($0.spaceId, $0.profileId)
                }
            )
            let sourceSpaceByID = Dictionary(
                uniqueKeysWithValues: snapshot.spaces.map {
                    ($0.spaceID, $0)
                }
            )
            for (sourceSpaceID, targetSpaceID) in spaceIDs {
                if let existingProfileID = targetSpaceProfileIDs[targetSpaceID] {
                    targetSpaceProfileIDs[targetSpaceID] = existingProfileID
                } else if let sourceSpace = sourceSpaceByID[sourceSpaceID] {
                    targetSpaceProfileIDs[targetSpaceID] =
                        profileIDs[sourceSpace.profileID] ?? sourceSpace.profileID
                } else {
                    targetSpaceProfileIDs[targetSpaceID] =
                        profileIDs[Self.defaultProfileId] ?? Self.defaultProfileId
                }
            }

            var usedModelGUIDs = Set(targetModels.map(\.guid))
            var bookmarkGUIDs: [String: String] = [:]
            for (index, bookmark) in snapshot.bookmarks.enumerated() {
                let targetGUID: String
                if !usedModelGUIDs.contains(bookmark.guid) {
                    targetGUID = bookmark.guid
                } else {
                    targetGUID = Self.guestMigrationIdentifier(
                        operationID: operationID,
                        kind: "bookmark",
                        index: index,
                        used: &usedModelGUIDs
                    )
                }
                bookmarkGUIDs[bookmark.guid] = targetGUID
                usedModelGUIDs.insert(targetGUID)
            }

            let hasDefaultBookmarks = snapshot.bookmarks.contains {
                $0.spaceID == Self.defaultSpaceId
            }
            let defaultImportFolderGUID: String?
            if hasDefaultBookmarks {
                let guid = Self.guestMigrationIdentifier(
                    operationID: operationID,
                    kind: "default-bookmarks",
                    index: 0,
                    used: &usedModelGUIDs
                )
                usedModelGUIDs.insert(guid)
                defaultImportFolderGUID = guid
            } else {
                defaultImportFolderGUID = nil
            }

            let targetPinned = targetModels.filter {
                $0.type == TabDataType.pinnedTab.rawValue
            }
            var pinnedTargets = Self.planGuestPinnedTargets(
                source: snapshot.pinnedTabs,
                sourceScope: PinnedTabScope(
                    rawValue: snapshot.sourcePinnedTabScopeRawValue
                ) ?? .profile,
                target: targetPinned,
                targetScope: targetScope,
                profileIDs: profileIDs,
                spaceIDs: spaceIDs,
                targetProfileIDs: Set(targetProfiles.map(\.profileId))
                    .union(profileIDs.values),
                targetSpaceProfileIDs: targetSpaceProfileIDs,
                operationID: operationID,
                usedModelGUIDs: &usedModelGUIDs
            )
            pinnedTargets.sort {
                (
                    $0.targetProfileID ?? "",
                    $0.targetSpaceID ?? "",
                    $0.targetIndex,
                    $0.sourceGUID,
                    $0.targetGUID
                ) < (
                    $1.targetProfileID ?? "",
                    $1.targetSpaceID ?? "",
                    $1.targetIndex,
                    $1.sourceGUID,
                    $1.targetGUID
                )
            }

            let pinLineageIDs = Dictionary(
                snapshot.pinnedTabs.map {
                    ($0.lineageID, $0.lineageID)
                },
                uniquingKeysWith: { first, _ in first }
            )

            let existingRuleSignatures = Set(targetRules.map {
                Self.guestRuleSignature(
                    spaceID: $0.spaceId,
                    host: $0.host,
                    pathPrefix: $0.pathPrefix
                )
            })
            var nextRuleIndexBySpace: [String: Int] = [:]
            for rule in targetRules {
                nextRuleIndexBySpace[rule.spaceId] = max(
                    nextRuleIndexBySpace[rule.spaceId] ?? 0,
                    rule.sortOrder + 1
                )
            }
            var usedRuleIDs = Set(targetRules.map(\.id))
            var urlRuleTargets: [GuestDataMigrationURLRuleTarget] = []
            var skippedURLRules: [GuestDataMigrationSkippedURLRule] = []
            for (index, rule) in snapshot.urlRules.enumerated() {
                guard let targetSpaceID = spaceIDs[rule.spaceID] else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "URL rule \(rule.id) has no target Space mapping"
                    )
                }
                let signature = Self.guestRuleSignature(
                    spaceID: targetSpaceID,
                    host: rule.host,
                    pathPrefix: rule.pathPrefix
                )
                if existingRuleSignatures.contains(signature) {
                    skippedURLRules.append(
                        GuestDataMigrationSkippedURLRule(
                            sourceID: rule.id,
                            targetSpaceID: targetSpaceID,
                            host: rule.host.lowercased(),
                            pathPrefix: Self.normalizedPathPrefix(rule.pathPrefix)
                        )
                    )
                    continue
                }
                let targetID: String
                if !usedRuleIDs.contains(rule.id) {
                    targetID = rule.id
                } else {
                    targetID = Self.guestMigrationIdentifier(
                        operationID: operationID,
                        kind: "url-rule",
                        index: index,
                        used: &usedRuleIDs
                    )
                }
                let targetSortOrder = nextRuleIndexBySpace[targetSpaceID] ?? 0
                nextRuleIndexBySpace[targetSpaceID] = targetSortOrder + 1
                usedRuleIDs.insert(targetID)
                urlRuleTargets.append(
                    GuestDataMigrationURLRuleTarget(
                        sourceID: rule.id,
                        targetID: targetID,
                        targetSpaceID: targetSpaceID,
                        targetSortOrder: targetSortOrder
                    )
                )
            }

            return GuestDataMigrationIdentifierMappings(
                profileIDs: profileIDs,
                spaceIDs: spaceIDs,
                bookmarkGUIDs: bookmarkGUIDs,
                pinnedTargets: pinnedTargets,
                pinLineageIDs: pinLineageIDs,
                urlRuleTargets: urlRuleTargets,
                skippedURLRules: skippedURLRules,
                defaultImportFolderGUID: defaultImportFolderGUID,
                targetPinnedTabScopeRawValue: targetScope.rawValue,
                targetSpaceProfileIDs: targetSpaceProfileIDs,
                insertedProfileIDs: insertedProfileIDs,
                insertedSpaceIDs: insertedSpaceIDs
            )
        }
    }

    func importGuestData(
        _ snapshot: GuestDataMigrationSnapshot,
        operationID: UUID,
        targetUserID: String,
        mappings: GuestDataMigrationIdentifierMappings
    ) async throws {
        guard account.userID == targetUserID else {
            throw GuestDataMigrationError.pendingMigrationTargetsAnotherAccount(
                expected: targetUserID,
                actual: account.userID
            )
        }
        _ = operationID

        try await performBackgroundWriteAndWaitThrowing { context in
            let importState = try Self.guestImportPresence(
                mappings: mappings,
                in: context
            )
            switch importState {
            case .complete:
                return
            case .partial(let detail):
                throw GuestDataMigrationError.targetStateConflict(detail)
            case .absent:
                break
            }

            let sourceProfilesByID = Dictionary(
                uniqueKeysWithValues: snapshot.profiles.map {
                    ($0.profileID, $0)
                }
            )
            var targetProfilesByID = Dictionary(
                uniqueKeysWithValues: try context.fetch(
                    FetchDescriptor<ProfileModel>()
                ).map { ($0.profileId, $0) }
            )
            for profileID in mappings.insertedProfileIDs {
                guard targetProfilesByID[profileID] == nil else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "Profile \(profileID) appeared after the migration was planned"
                    )
                }
                let source = sourceProfilesByID.first {
                    mappings.profileIDs[$0.key] == profileID
                }?.value
                let profile = ProfileModel(
                    guid: source?.guid ?? profileID,
                    profileId: profileID,
                    displayName: source?.displayName
                )
                context.insert(profile)
                targetProfilesByID[profileID] = profile
            }

            let existingTargetSpaces = try context.fetch(
                FetchDescriptor<SpaceModel>()
            )
            var targetSpacesByID = Dictionary(
                uniqueKeysWithValues: existingTargetSpaces.map {
                    ($0.spaceId, $0)
                }
            )
            let sourceSpacesByID = Dictionary(
                uniqueKeysWithValues: snapshot.spaces.map {
                    ($0.spaceID, $0)
                }
            )
            let maxTargetSortOrder = existingTargetSpaces.map(\.sortOrder).max() ?? -1
            var appendedSpaceOffset = 0
            for targetSpaceID in mappings.insertedSpaceIDs {
                guard targetSpacesByID[targetSpaceID] == nil else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "Space \(targetSpaceID) appeared after the migration was planned"
                    )
                }
                let sourceEntry = mappings.spaceIDs.first {
                    $0.value == targetSpaceID
                }
                let sourceSpace = sourceEntry.flatMap {
                    sourceSpacesByID[$0.key]
                }
                let targetProfileID = mappings.targetSpaceProfileIDs[targetSpaceID]
                    ?? mappings.profileIDs[sourceSpace?.profileID ?? Self.defaultProfileId]
                    ?? sourceSpace?.profileID
                    ?? Self.defaultProfileId
                let profile: ProfileModel
                if let existing = targetProfilesByID[targetProfileID] {
                    profile = existing
                } else {
                    let created = ProfileModel(profileId: targetProfileID)
                    context.insert(created)
                    targetProfilesByID[targetProfileID] = created
                    profile = created
                }
                _ = profile
                let space = SpaceModel(
                    spaceId: targetSpaceID,
                    profileId: targetProfileID,
                    name: sourceSpace?.name ?? "Default",
                    colorHex: sourceSpace?.colorHex ?? "#3A6FF8",
                    iconName: sourceSpace?.iconName
                        ?? "phi:phi-icon-view-grid-add",
                    sortOrder: maxTargetSortOrder + 1 + appendedSpaceOffset,
                    createdDate: sourceSpace?.createdDate ?? snapshot.capturedAt,
                    updatedDate: sourceSpace?.updatedDate ?? snapshot.capturedAt
                )
                appendedSpaceOffset += 1
                context.insert(space)
                targetSpacesByID[targetSpaceID] = space
            }

            let existingModels = try context.fetch(FetchDescriptor<TabDataModel>())
            let existingGUIDs = Set(existingModels.map(\.guid))
            let expectedNewGUIDs = Set(mappings.bookmarkGUIDs.values)
                .union(mappings.defaultImportFolderGUID.map { [$0] } ?? [])
                .union(
                    mappings.pinnedTargets
                        .filter(\.shouldInsert)
                        .map(\.targetGUID)
                )
            let conflicts = existingGUIDs.intersection(expectedNewGUIDs)
            guard conflicts.isEmpty else {
                throw GuestDataMigrationError.targetStateConflict(
                    "model identifiers appeared after planning: \(conflicts.sorted().joined(separator: ", "))"
                )
            }

            let bookmarkFolderURL = URL(
                string: "https://bookmark.phi/folder"
            )!
            var containerByTargetSpaceID: [String: TabDataModel] = [:]
            if let folderGUID = mappings.defaultImportFolderGUID {
                let targetSpaceID = Self.defaultSpaceId
                let targetProfileID = mappings.targetSpaceProfileIDs[targetSpaceID]
                    ?? Self.defaultProfileId
                guard let root = try self.bookmarkRoot(
                    profileId: targetProfileID,
                    spaceId: targetSpaceID,
                    in: context,
                    createIfNeeded: true
                ) else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "the target default bookmark root is unavailable"
                    )
                }
                let rootGUID = root.guid
                let existingChildren = try context.fetch(
                    FetchDescriptor<TabDataModel>(
                        predicate: #Predicate {
                            $0.parent?.guid == rootGUID
                        }
                    )
                )
                let folder = TabDataModel(
                    title: NSLocalizedString(
                        "localData.bookmarks.importedFromGuestFolderTitle",
                        value: "Imported from Guest",
                        comment: "Bookmark folder - Container created when Guest bookmarks are moved into a signed-in account"
                    ),
                    guid: folderGUID,
                    index: (existingChildren.map(\.index).max() ?? -1) + 1,
                    url: bookmarkFolderURL,
                    favicon: nil,
                    createdDate: snapshot.capturedAt,
                    updatedDate: snapshot.capturedAt
                )
                folder.dataType = .bookmarkFolder
                folder.profileId = targetProfileID
                folder.profile = targetProfilesByID[targetProfileID]
                folder.spaceId = targetSpaceID
                folder.isCreatedByChromium = false
                folder.parent = root
                context.insert(folder)
                containerByTargetSpaceID[targetSpaceID] = folder
            }

            for targetSpaceID in Set(
                snapshot.bookmarks
                    .filter { $0.spaceID != Self.defaultSpaceId }
                    .compactMap { mappings.spaceIDs[$0.spaceID] }
            ) {
                guard let targetProfileID = mappings.targetSpaceProfileIDs[targetSpaceID],
                      let root = try self.bookmarkRoot(
                        profileId: targetProfileID,
                        spaceId: targetSpaceID,
                        in: context,
                        createIfNeeded: true
                      ) else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "bookmark root is unavailable for Space \(targetSpaceID)"
                    )
                }
                containerByTargetSpaceID[targetSpaceID] = root
            }

            let targetBookmarkIndexes = Self.guestBookmarkTargetIndexes(
                snapshot: snapshot,
                mappings: mappings
            )
            var importedBookmarksBySourceGUID: [String: TabDataModel] = [:]
            for source in snapshot.bookmarks {
                guard let targetGUID = mappings.bookmarkGUIDs[source.guid],
                      let targetSpaceID = mappings.spaceIDs[source.spaceID],
                      let targetProfileID = mappings.targetSpaceProfileIDs[targetSpaceID] else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "bookmark \(source.guid) has incomplete identifier mappings"
                    )
                }
                let model = TabDataModel(
                    title: source.title,
                    guid: targetGUID,
                    index: targetBookmarkIndexes[source.guid] ?? source.index,
                    url: source.url,
                    favicon: source.favicon,
                    createdDate: source.createdDate,
                    updatedDate: source.updatedDate
                )
                model.type = source.type
                model.overrideTitle = source.overrideTitle
                model.isOpenned = source.isOpened
                model.isCreatedByChromium = source.isCreatedByChromium
                model.needUpdateMetaData = source.needsMetadataUpdate
                model.profileId = targetProfileID
                model.profile = targetProfilesByID[targetProfileID]
                model.spaceId = targetSpaceID
                model.source = source.source
                model.secondaryUrl = source.secondaryURL
                model.secondaryTitle = source.secondaryTitle
                model.layout = source.layout
                model.lastSeen = source.lastSeen
                model.icon = source.icon ?? "default"
                context.insert(model)
                importedBookmarksBySourceGUID[source.guid] = model
            }
            for source in snapshot.bookmarks {
                guard let model = importedBookmarksBySourceGUID[source.guid],
                      let targetSpaceID = mappings.spaceIDs[source.spaceID] else {
                    continue
                }
                if let parentGUID = source.parentGUID,
                   let importedParent = importedBookmarksBySourceGUID[parentGUID] {
                    model.parent = importedParent
                } else {
                    model.parent = containerByTargetSpaceID[targetSpaceID]
                }
            }

            let sourcePinsByGUID = Dictionary(
                uniqueKeysWithValues: snapshot.pinnedTabs.map {
                    ($0.guid, $0)
                }
            )
            for mapping in mappings.pinnedTargets where mapping.shouldInsert {
                guard let source = sourcePinsByGUID[mapping.sourceGUID] else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "pinned source \(mapping.sourceGUID) is missing"
                    )
                }
                let model = TabDataModel(
                    title: source.title,
                    guid: mapping.targetGUID,
                    index: mapping.targetIndex,
                    url: source.url,
                    favicon: source.favicon,
                    createdDate: source.createdDate,
                    updatedDate: source.updatedDate
                )
                model.dataType = .pinnedTab
                model.overrideTitle = source.overrideTitle
                model.isOpenned = source.isOpened
                model.isCreatedByChromium = source.isCreatedByChromium
                model.needUpdateMetaData = source.needsMetadataUpdate
                model.profileId = mapping.targetProfileID
                model.profile = mapping.targetProfileID.flatMap {
                    targetProfilesByID[$0]
                }
                model.spaceId = mapping.targetSpaceID
                model.source = source.source
                model.secondaryUrl = source.secondaryURL
                model.secondaryTitle = source.secondaryTitle
                model.splitPartnerGuid = mapping.targetSplitPartnerGUID
                model.layout = source.layout
                model.lastSeen = source.lastSeen
                model.icon = source.icon ?? "default"
                model.pinLineageId =
                    mappings.pinLineageIDs[source.lineageID] ?? source.lineageID
                model.isPinnedTabDormant = mapping.isDormant
                context.insert(model)
            }

            let sourceRulesByID = Dictionary(
                uniqueKeysWithValues: snapshot.urlRules.map {
                    ($0.id, $0)
                }
            )
            for mapping in mappings.urlRuleTargets {
                guard let source = sourceRulesByID[mapping.sourceID] else {
                    throw GuestDataMigrationError.targetStateConflict(
                        "URL rule source \(mapping.sourceID) is missing"
                    )
                }
                context.insert(
                    SpaceURLRule(
                        id: mapping.targetID,
                        spaceId: mapping.targetSpaceID,
                        host: source.host.lowercased(),
                        pathPrefix: Self.normalizedPathPrefix(source.pathPrefix),
                        askBeforeRouting: source.askBeforeRouting,
                        sortOrder: mapping.targetSortOrder,
                        createdDate: source.createdDate
                    )
                )
            }
        }
    }

    func guestDataMigrationImportPresence(
        mappings: GuestDataMigrationIdentifierMappings
    ) async throws -> GuestDataMigrationTargetImportPresence {
        try await performBackgroundWriteAndWaitThrowing { context in
            try Self.guestImportPresence(
                mappings: mappings,
                in: context
            )
        }
    }

    func verifyGuestDataMigrationReceipt(
        _ receipt: GuestDataMigrationReceipt,
        snapshot: GuestDataMigrationSnapshot
    ) async throws {
        guard receipt.targetUserID == account.userID,
              receipt.sourceUserID == snapshot.sourceUserID,
              receipt.snapshotID == snapshot.snapshotID else {
            throw GuestDataMigrationError.verificationFailed(
                "receipt identity does not match the source and target stores"
            )
        }

        try await performBackgroundWriteAndWaitThrowing { context in
            let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let profileIDs = Set(profiles.map(\.profileId))
            let missingProfiles = Set(receipt.mappings.profileIDs.values)
                .subtracting(profileIDs)
            guard missingProfiles.isEmpty else {
                throw GuestDataMigrationError.verificationFailed(
                    "missing Profiles: \(missingProfiles.sorted().joined(separator: ", "))"
                )
            }

            let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
            let spacesByID = Dictionary(
                uniqueKeysWithValues: spaces.map { ($0.spaceId, $0) }
            )
            for targetSpaceID in Set(receipt.mappings.spaceIDs.values) {
                guard let space = spacesByID[targetSpaceID],
                      space.profileId
                        == receipt.mappings.targetSpaceProfileIDs[targetSpaceID] else {
                    throw GuestDataMigrationError.verificationFailed(
                        "Space \(targetSpaceID) is missing or belongs to another Profile"
                    )
                }
            }

            let models = try context.fetch(FetchDescriptor<TabDataModel>())
            let modelsByGUID = Dictionary(
                models.map { ($0.guid, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let sourceBookmarksByGUID = Dictionary(
                uniqueKeysWithValues: snapshot.bookmarks.map {
                    ($0.guid, $0)
                }
            )
            let targetBookmarkIndexes = Self.guestBookmarkTargetIndexes(
                snapshot: snapshot,
                mappings: receipt.mappings
            )
            for (sourceGUID, targetGUID) in receipt.mappings.bookmarkGUIDs {
                guard let source = sourceBookmarksByGUID[sourceGUID],
                      let target = modelsByGUID[targetGUID],
                      target.type == source.type,
                      target.title == source.title,
                      target.url == source.url,
                      target.favicon == source.favicon,
                      target.index == targetBookmarkIndexes[sourceGUID],
                      target.spaceId == receipt.mappings.spaceIDs[source.spaceID],
                      target.profileId
                        == receipt.mappings.targetSpaceProfileIDs[target.spaceId ?? ""]
                else {
                    throw GuestDataMigrationError.verificationFailed(
                        "bookmark \(sourceGUID) does not match its imported record"
                    )
                }
                if let sourceParentGUID = source.parentGUID {
                    guard target.parent?.guid
                            == receipt.mappings.bookmarkGUIDs[sourceParentGUID] else {
                        throw GuestDataMigrationError.verificationFailed(
                            "bookmark \(sourceGUID) has the wrong parent"
                        )
                    }
                } else if source.spaceID == Self.defaultSpaceId {
                    guard target.parent?.guid
                            == receipt.mappings.defaultImportFolderGUID else {
                        throw GuestDataMigrationError.verificationFailed(
                            "default-Space bookmark \(sourceGUID) is outside the import folder"
                        )
                    }
                } else {
                    let targetSpaceID = receipt.mappings.spaceIDs[source.spaceID]
                    guard let targetSpaceID,
                          target.parent?.guid
                            == spacesByID[targetSpaceID]?.bookmarkRoot?.guid else {
                        throw GuestDataMigrationError.verificationFailed(
                            "custom-Space bookmark \(sourceGUID) is outside its Space root"
                        )
                    }
                }
            }

            if let folderGUID = receipt.mappings.defaultImportFolderGUID {
                guard let folder = modelsByGUID[folderGUID],
                      folder.dataType == .bookmarkFolder,
                      folder.spaceId == Self.defaultSpaceId,
                      folder.parent?.guid
                        == spacesByID[Self.defaultSpaceId]?
                            .bookmarkRoot?.guid else {
                    throw GuestDataMigrationError.verificationFailed(
                        "the default-Space import folder is missing"
                    )
                }
            }

            let sourcePinsByGUID = Dictionary(
                uniqueKeysWithValues: snapshot.pinnedTabs.map {
                    ($0.guid, $0)
                }
            )
            for mapping in receipt.mappings.pinnedTargets {
                guard let source = sourcePinsByGUID[mapping.sourceGUID],
                      let target = modelsByGUID[mapping.targetGUID],
                      target.dataType == .pinnedTab,
                      target.title == source.title,
                      target.url == source.url,
                      target.favicon == source.favicon,
                      target.profileId == mapping.targetProfileID,
                      target.spaceId == mapping.targetSpaceID,
                      (target.pinLineageId ?? target.guid)
                        == (receipt.mappings.pinLineageIDs[source.lineageID]
                            ?? source.lineageID),
                      target.splitPartnerGuid == mapping.targetSplitPartnerGUID
                else {
                    throw GuestDataMigrationError.verificationFailed(
                        "pinned tab \(mapping.sourceGUID) does not match owner \(mapping.targetProfileID ?? "app")/\(mapping.targetSpaceID ?? "shared")"
                    )
                }
                if mapping.shouldInsert {
                    guard target.index == mapping.targetIndex,
                          target.overrideTitle == source.overrideTitle,
                          target.secondaryUrl == source.secondaryURL,
                          target.secondaryTitle == source.secondaryTitle,
                          target.layout == source.layout,
                          target.isPinnedTabDormant == mapping.isDormant else {
                        throw GuestDataMigrationError.verificationFailed(
                            "pinned tab \(mapping.targetGUID) lost persisted fields"
                        )
                    }
                }
            }

            let rules = try context.fetch(FetchDescriptor<SpaceURLRule>())
            let rulesByID = Dictionary(
                uniqueKeysWithValues: rules.map { ($0.id, $0) }
            )
            let sourceRulesByID = Dictionary(
                uniqueKeysWithValues: snapshot.urlRules.map {
                    ($0.id, $0)
                }
            )
            for mapping in receipt.mappings.urlRuleTargets {
                guard let source = sourceRulesByID[mapping.sourceID],
                      let target = rulesByID[mapping.targetID],
                      target.spaceId == mapping.targetSpaceID,
                      target.host == source.host.lowercased(),
                      target.pathPrefix
                        == Self.normalizedPathPrefix(source.pathPrefix),
                      target.askBeforeRouting == source.askBeforeRouting,
                      target.sortOrder == mapping.targetSortOrder else {
                    throw GuestDataMigrationError.verificationFailed(
                        "URL rule \(mapping.sourceID) does not match its imported record"
                    )
                }
            }
            let currentRuleSignatures = Set(rules.map {
                Self.guestRuleSignature(
                    spaceID: $0.spaceId,
                    host: $0.host,
                    pathPrefix: $0.pathPrefix
                )
            })
            for skipped in receipt.mappings.skippedURLRules {
                let signature = Self.guestRuleSignature(
                    spaceID: skipped.targetSpaceID,
                    host: skipped.host,
                    pathPrefix: skipped.pathPrefix
                )
                guard currentRuleSignatures.contains(signature) else {
                    throw GuestDataMigrationError.verificationFailed(
                        "the target-winning URL rule for \(skipped.sourceID) disappeared"
                    )
                }
            }
        }
    }

}

private extension LocalStore {
    static func guestPinnedTab(
        _ model: TabDataModel,
        belongsTo scope: PinnedTabScope
    ) -> Bool {
        switch scope {
        case .space:
            return model.spaceId != nil
        case .profile:
            return (model.profileId != nil || model.profile != nil)
                && model.spaceId == nil
        case .app:
            return model.profileId == nil && model.spaceId == nil
        }
    }

    static func guestMigrationIdentifier(
        operationID: UUID,
        kind: String,
        index: Int,
        used: inout Set<String>
    ) -> String {
        let operation = operationID.uuidString.lowercased()
        var suffix = 0
        while true {
            let collisionSuffix = suffix == 0 ? "" : "-\(suffix)"
            let candidate =
                "guest-import-\(operation)-\(kind)-\(index)\(collisionSuffix)"
            if !used.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    static func guestPinnedContentSignature(
        title: String,
        url: URL,
        favicon: Data?
    ) -> GuestMigrationPinnedContentSignature {
        GuestMigrationPinnedContentSignature(
            title: title,
            url: url,
            favicon: favicon
        )
    }

    static func guestPinnedVariantSignature(
        for source: GuestDataMigrationPinnedTabRecord,
        rowsByGUID: [String: GuestDataMigrationPinnedTabRecord]
    ) -> GuestMigrationPinnedVariantSignature {
        let partner = source.splitPartnerGUID.flatMap { rowsByGUID[$0] }
        return GuestMigrationPinnedVariantSignature(
            content: guestPinnedContentSignature(
                title: source.title,
                url: source.url,
                favicon: source.favicon
            ),
            partnerLineageID: partner?.lineageID,
            partnerContent: partner.map {
                guestPinnedContentSignature(
                    title: $0.title,
                    url: $0.url,
                    favicon: $0.favicon
                )
            }
        )
    }

    static func guestPinnedVariantSignature(
        for target: TabDataModel,
        rowsByGUID: [String: TabDataModel]
    ) -> GuestMigrationPinnedVariantSignature {
        let partner = target.splitPartnerGuid.flatMap { rowsByGUID[$0] }
        return GuestMigrationPinnedVariantSignature(
            content: guestPinnedContentSignature(
                title: target.title,
                url: target.url,
                favicon: target.favicon
            ),
            partnerLineageID: partner.map {
                $0.pinLineageId ?? $0.guid
            },
            partnerContent: partner.map {
                guestPinnedContentSignature(
                    title: $0.title,
                    url: $0.url,
                    favicon: $0.favicon
                )
            }
        )
    }

    static func guestTargetOwners(
        for source: GuestDataMigrationPinnedTabRecord,
        sourceScope: PinnedTabScope,
        targetScope: PinnedTabScope,
        profileIDs: [String: String],
        spaceIDs: [String: String],
        targetProfileIDs: Set<String>,
        targetSpaceProfileIDs: [String: String]
    ) -> [GuestMigrationPinnedOwner] {
        switch targetScope {
        case .app:
            return [GuestMigrationPinnedOwner(profileID: nil, spaceID: nil)]
        case .profile:
            if sourceScope == .app && !source.isDormant {
                return targetProfileIDs.sorted().map {
                    GuestMigrationPinnedOwner(profileID: $0, spaceID: nil)
                }
            }
            if let sourceSpaceID = source.spaceID,
               let targetSpaceID = spaceIDs[sourceSpaceID],
               let targetProfileID = targetSpaceProfileIDs[targetSpaceID] {
                return [
                    GuestMigrationPinnedOwner(
                        profileID: targetProfileID,
                        spaceID: nil
                    ),
                ]
            }
            let sourceProfileID = source.profileID ?? defaultProfileId
            return [
                GuestMigrationPinnedOwner(
                    profileID: profileIDs[sourceProfileID] ?? sourceProfileID,
                    spaceID: nil
                ),
            ]
        case .space:
            if sourceScope == .app && !source.isDormant {
                return targetSpaceProfileIDs.keys.sorted().compactMap {
                    guard let profileID = targetSpaceProfileIDs[$0] else {
                        return nil
                    }
                    return GuestMigrationPinnedOwner(
                        profileID: profileID,
                        spaceID: $0
                    )
                }
            }
            if let sourceSpaceID = source.spaceID,
               let targetSpaceID = spaceIDs[sourceSpaceID],
               let targetProfileID = targetSpaceProfileIDs[targetSpaceID] {
                return [
                    GuestMigrationPinnedOwner(
                        profileID: targetProfileID,
                        spaceID: targetSpaceID
                    ),
                ]
            }
            let sourceProfileID = source.profileID ?? defaultProfileId
            let targetProfileID =
                profileIDs[sourceProfileID] ?? sourceProfileID
            let spaces = targetSpaceProfileIDs
                .filter { $0.value == targetProfileID }
                .keys
                .sorted()
            if spaces.isEmpty {
                return [
                    GuestMigrationPinnedOwner(
                        profileID: targetProfileID,
                        spaceID: nil
                    ),
                ]
            }
            return spaces.map {
                GuestMigrationPinnedOwner(
                    profileID: targetProfileID,
                    spaceID: $0
                )
            }
        }
    }

    static func planGuestPinnedTargets(
        source: [GuestDataMigrationPinnedTabRecord],
        sourceScope: PinnedTabScope,
        target: [TabDataModel],
        targetScope: PinnedTabScope,
        profileIDs: [String: String],
        spaceIDs: [String: String],
        targetProfileIDs: Set<String>,
        targetSpaceProfileIDs: [String: String],
        operationID: UUID,
        usedModelGUIDs: inout Set<String>
    ) -> [GuestDataMigrationPinnedTarget] {
        let sourceByGUID = Dictionary(
            uniqueKeysWithValues: source.map { ($0.guid, $0) }
        )
        let targetByGUID = Dictionary(
            target.map { ($0.guid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeTarget = target.filter {
            guestPinnedTab($0, belongsTo: targetScope)
                || (
                    targetScope == .space
                    && $0.isPinnedTabDormant
                    && guestPinnedTab($0, belongsTo: .profile)
                )
        }
        let targetByOwner = Dictionary(grouping: activeTarget) { model in
            GuestMigrationPinnedOwner(
                profileID: model.profileId ?? model.profile?.profileId,
                spaceID: model.spaceId
            )
        }

        var projected: [GuestMigrationPinnedOwner: [GuestDataMigrationPinnedTabRecord]] = [:]
        for sourceRow in source {
            let owners = guestTargetOwners(
                for: sourceRow,
                sourceScope: sourceScope,
                targetScope: targetScope,
                profileIDs: profileIDs,
                spaceIDs: spaceIDs,
                targetProfileIDs: targetProfileIDs,
                targetSpaceProfileIDs: targetSpaceProfileIDs
            )
            for owner in owners {
                projected[owner, default: []].append(sourceRow)
            }
        }

        var result: [GuestDataMigrationPinnedTarget] = []
        var mappingIndexByProjectedKey: [GuestMigrationProjectedPinKey: Int] = [:]
        var generatedCounter = 0
        for owner in projected.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            let existingRows = (targetByOwner[owner] ?? []).sorted {
                ($0.index, $0.guid) < ($1.index, $1.guid)
            }
            var canonicalByVariant: [
                GuestMigrationPinnedVariantKey: (guid: String, index: Int)
            ] = [:]
            for row in existingRows {
                let key = GuestMigrationPinnedVariantKey(
                    lineageID: row.pinLineageId ?? row.guid,
                    signature: guestPinnedVariantSignature(
                        for: row,
                        rowsByGUID: targetByGUID
                    )
                )
                if canonicalByVariant[key] == nil {
                    canonicalByVariant[key] = (row.guid, row.index)
                }
            }

            var nextIndex = (existingRows.map(\.index).max() ?? -1) + 1
            let sourceRows = (projected[owner] ?? []).sorted {
                (
                    $0.profileID ?? "",
                    $0.spaceID ?? "",
                    $0.index,
                    $0.guid
                ) < (
                    $1.profileID ?? "",
                    $1.spaceID ?? "",
                    $1.index,
                    $1.guid
                )
            }
            for sourceRow in sourceRows {
                let key = GuestMigrationPinnedVariantKey(
                    lineageID: sourceRow.lineageID,
                    signature: guestPinnedVariantSignature(
                        for: sourceRow,
                        rowsByGUID: sourceByGUID
                    )
                )
                let targetGUID: String
                let targetIndex: Int
                let shouldInsert: Bool
                if let canonical = canonicalByVariant[key] {
                    targetGUID = canonical.guid
                    targetIndex = canonical.index
                    shouldInsert = false
                } else {
                    let guid: String
                    if !usedModelGUIDs.contains(sourceRow.guid) {
                        guid = sourceRow.guid
                    } else {
                        guid = guestMigrationIdentifier(
                            operationID: operationID,
                            kind: "pin",
                            index: generatedCounter,
                            used: &usedModelGUIDs
                        )
                    }
                    generatedCounter += 1
                    usedModelGUIDs.insert(guid)
                    canonicalByVariant[key] = (guid, nextIndex)
                    targetGUID = guid
                    targetIndex = nextIndex
                    nextIndex += 1
                    shouldInsert = true
                }
                let mapping = GuestDataMigrationPinnedTarget(
                    sourceGUID: sourceRow.guid,
                    targetGUID: targetGUID,
                    targetProfileID: owner.profileID,
                    targetSpaceID: owner.spaceID,
                    targetIndex: targetIndex,
                    targetSplitPartnerGUID: nil,
                    shouldInsert: shouldInsert,
                    isDormant: targetScope == .space && owner.spaceID == nil
                )
                mappingIndexByProjectedKey[
                    GuestMigrationProjectedPinKey(
                        sourceGUID: sourceRow.guid,
                        owner: owner
                    )
                ] = result.count
                result.append(mapping)
            }
        }

        for index in result.indices {
            let mapping = result[index]
            guard let sourceRow = sourceByGUID[mapping.sourceGUID],
                  let partnerSourceGUID = sourceRow.splitPartnerGUID,
                  let partnerIndex = mappingIndexByProjectedKey[
                    GuestMigrationProjectedPinKey(
                        sourceGUID: partnerSourceGUID,
                        owner: GuestMigrationPinnedOwner(
                            profileID: mapping.targetProfileID,
                            spaceID: mapping.targetSpaceID
                        )
                    )
                  ] else {
                continue
            }
            let partnerGUID = result[partnerIndex].targetGUID
            result[index] = GuestDataMigrationPinnedTarget(
                sourceGUID: mapping.sourceGUID,
                targetGUID: mapping.targetGUID,
                targetProfileID: mapping.targetProfileID,
                targetSpaceID: mapping.targetSpaceID,
                targetIndex: mapping.targetIndex,
                targetSplitPartnerGUID: partnerGUID,
                shouldInsert: mapping.shouldInsert,
                isDormant: mapping.isDormant
            )
        }
        return result
    }

    static func guestRuleSignature(
        spaceID: String,
        host: String,
        pathPrefix: String?
    ) -> String {
        "\(spaceID)\u{0}\(host.lowercased())\u{0}\(normalizedPathPrefix(pathPrefix) ?? "")"
    }

    static func guestBookmarkTargetIndexes(
        snapshot: GuestDataMigrationSnapshot,
        mappings: GuestDataMigrationIdentifierMappings
    ) -> [String: Int] {
        let recordsByGUID = Dictionary(
            uniqueKeysWithValues: snapshot.bookmarks.map {
                ($0.guid, $0)
            }
        )
        let grouped = Dictionary(grouping: snapshot.bookmarks) { record -> String in
            let targetSpaceID = mappings.spaceIDs[record.spaceID]
                ?? record.spaceID
            let targetParentGUID = record.parentGUID.flatMap {
                mappings.bookmarkGUIDs[$0]
            }
            if let targetParentGUID {
                return "\(targetSpaceID)\u{0}\(targetParentGUID)"
            }
            if record.spaceID == defaultSpaceId,
               let folderGUID = mappings.defaultImportFolderGUID {
                return "\(targetSpaceID)\u{0}\(folderGUID)"
            }
            return "\(targetSpaceID)\u{0}<root>"
        }
        var result: [String: Int] = [:]
        for records in grouped.values {
            let ordered = records.sorted {
                let lhsParent = $0.parentGUID.flatMap { recordsByGUID[$0] }
                let rhsParent = $1.parentGUID.flatMap { recordsByGUID[$0] }
                return (
                    lhsParent?.index ?? 0,
                    $0.index,
                    $0.guid
                ) < (
                    rhsParent?.index ?? 0,
                    $1.index,
                    $1.guid
                )
            }
            for (index, record) in ordered.enumerated() {
                result[record.guid] = index
            }
        }
        return result
    }

    static func guestImportPresence(
        mappings: GuestDataMigrationIdentifierMappings,
        in context: ModelContext
    ) throws -> GuestDataMigrationTargetImportPresence {
        var expected: [(String, Bool)] = []

        let profiles = Set(
            try context.fetch(FetchDescriptor<ProfileModel>()).map(\.profileId)
        )
        expected.append(
            contentsOf: mappings.insertedProfileIDs.map {
                ("profile:\($0)", profiles.contains($0))
            }
        )

        let spaces = Set(
            try context.fetch(FetchDescriptor<SpaceModel>()).map(\.spaceId)
        )
        expected.append(
            contentsOf: mappings.insertedSpaceIDs.map {
                ("space:\($0)", spaces.contains($0))
            }
        )

        let modelGUIDs = Set(
            try context.fetch(FetchDescriptor<TabDataModel>()).map(\.guid)
        )
        let expectedModelGUIDs = Set(mappings.bookmarkGUIDs.values)
            .union(mappings.defaultImportFolderGUID.map { [$0] } ?? [])
            .union(
                mappings.pinnedTargets
                    .filter(\.shouldInsert)
                    .map(\.targetGUID)
            )
        expected.append(
            contentsOf: expectedModelGUIDs.map {
                ("model:\($0)", modelGUIDs.contains($0))
            }
        )

        let ruleIDs = Set(
            try context.fetch(FetchDescriptor<SpaceURLRule>()).map(\.id)
        )
        expected.append(
            contentsOf: mappings.urlRuleTargets.map {
                ("rule:\($0.targetID)", ruleIDs.contains($0.targetID))
            }
        )

        guard !expected.isEmpty else { return .absent }
        let present = expected.filter { $0.1 }
        if present.isEmpty {
            return .absent
        }
        if present.count == expected.count {
            return .complete
        }
        let missing = expected.filter { !$0.1 }.map(\.0).sorted()
        return .partial(
            "only part of a prior import exists; missing \(missing.joined(separator: ", "))"
        )
    }
}

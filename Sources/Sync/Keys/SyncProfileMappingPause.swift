// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// How the most recent `SyncKeyController.resolveMappings()` pass ended, as far
/// as the Profile mapping pause is concerned. Published by the key layer and
/// read by `SyncProfileMappingPause` to pick a reason; it is not a second copy
/// of `SyncKeyController.MappingsOutcome`, which only says whether the two
/// pairing predicates were measured.
enum SyncProfileMappingPassResult: String, Equatable {
    /// The pass decided from a fully known picture and nothing it tried failed.
    case measured
    /// Something the pass needed failed in a way a later pass can fix without
    /// the user (transport, offline, 5xx, 401/403, still locked). The pass
    /// measured nothing about the Profiles it could not settle.
    case heldTransient
    /// The server or an envelope refused definitively (bad envelope, an
    /// unexpected 4xx). Retrying unchanged is not expected to help.
    case definitiveFailure
}

/// What the latest mapping failure looked like, for the Sync status only: it
/// lets the status say "offline" while no engine round runs to find out. It
/// carries no text and no identifiers, and it changes neither the pass result
/// nor the pause's reason. Published by the key layer beside
/// `SyncProfileMappingPassResult`; nil after a pass that succeeds.
enum SyncProfileMappingFailureCategory: String, Equatable {
    /// A transport error that means no connectivity.
    case offline
    /// 401 or 403, or no token to send.
    case signInExpired
    /// 5xx, 429 or 408.
    case serverError
    /// Anything else, including a definitive refusal.
    case other
}

/// Pure answer to "must sync pause because a syncable local Profile is not
/// mapped to an account Profile" (plan 2026-09-29, ruling R1). Foundation only:
/// every input arrives as a value, so the coordinator can evaluate it
/// synchronously from the Profile-list sink and a hostless harness can pin it.
///
/// A Profile counts as unmapped when it has no persisted mapping, or when the
/// key layer knows its mapping is absent on the server (a persisted mapping
/// whose account envelope is gone, or a measured pass that left it unmapped).
/// Profiles the key layer is creating itself are ignored
/// until their adopt step has finished or failed: they are unmapped only for
/// the moment between the bridge creating them and the adopt writing the
/// mapping, and pausing for that moment would restart every Chromium engine.
struct SyncProfileMappingPause: Equatable {
    enum Reason: String, Equatable {
        /// A mapping pass is running or due; nothing has failed yet.
        case registering
        /// The last pass failed with a transient error and will be retried.
        case retrying
        /// The last pass was refused definitively; the user has to act.
        case needsAttention
    }

    let isPaused: Bool
    /// Sorted, so two evaluations of the same state compare equal.
    let unmappedProfileIds: [String]
    /// Nil exactly when not paused.
    let reason: Reason?

    static let notPaused = SyncProfileMappingPause(isPaused: false, unmappedProfileIds: [], reason: nil)

    /// - Parameters:
    ///   - syncableProfileIds: the local Profiles the rule covers
    ///     (`ProfileManager.userAssignableProfiles`).
    ///   - persistedMappings: local Profile id -> account Profile uuid.
    ///   - knownUnmappedProfileIds: `SyncKeyController.knownUnmappedProfileIds`,
    ///     the Profiles whose mapping the key layer knows to be absent on the
    ///     server. It survives held passes and a cache clear while the account
    ///     key is still available, so a persisted mapping whose envelope is gone
    ///     keeps pausing until a pass resolves it.
    ///   - profileIdsBeingCreated: Profiles the key layer created and has not
    ///     finished adopting.
    ///   - lastPassResult: how the last pass ended; nil when none has run.
    static func evaluate(syncableProfileIds: [String],
                         persistedMappings: [String: String],
                         knownUnmappedProfileIds: Set<String>,
                         profileIdsBeingCreated: Set<String>,
                         lastPassResult: SyncProfileMappingPassResult?) -> SyncProfileMappingPause {
        let unmapped = Set(syncableProfileIds.filter { profileId in
            guard !profileIdsBeingCreated.contains(profileId) else { return false }
            return persistedMappings[profileId] == nil
                || knownUnmappedProfileIds.contains(profileId)
        })
        guard !unmapped.isEmpty else { return .notPaused }
        let reason: Reason
        switch lastPassResult {
        case .definitiveFailure: reason = .needsAttention
        case .heldTransient: reason = .retrying
        case .measured, nil: reason = .registering
        }
        return SyncProfileMappingPause(isPaused: true, unmappedProfileIds: unmapped.sorted(), reason: reason)
    }
}

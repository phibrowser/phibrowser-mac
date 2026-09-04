// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

/// A pairing decision applied by the pairing UI (a later task) to resolve an
/// ambiguous local-profile <-> remote-profile mapping. `createLocal` is
/// deferred to that UI for the actual bridge profile creation; this type
/// only records the intent.
enum PairingDecision: Equatable {
    case adopt(localProfileId: String, remoteUuid: String)
    case registerNew(localProfileId: String, displayName: String)
    case createLocal(remoteUuid: String, displayName: String)
}

/// App-scoped owner of the sync key layer: silently unlocks the ARK at
/// startup/login, resolves local-profile -> global-profile mappings, caches
/// per-profile sync info for the bridge's synchronous hot-path pull, and pings
/// Chromium when keys become available. Owned by PhiChromiumCoordinator; the
/// Devices settings pane consumes this shared instance (ownership change from
/// M2-3's per-pane factory, documented in the M2-4 design).
@MainActor
final class SyncKeyController {
    let manager: AccountKeyManager
    let approvals: DeviceApprovalService
    let profileKeys: ProfileKeyManager

    private let localProfilesProvider: () -> [(profileId: String, displayName: String)]
    private let notifyChromium: () -> Void

    private(set) var resolved: [String: (uuid: String, passphrase: String)] = [:]
    private(set) var needsPairing = false

    init(manager: AccountKeyManager, approvals: DeviceApprovalService, profileKeys: ProfileKeyManager,
         localProfilesProvider: @escaping () -> [(profileId: String, displayName: String)],
         notifyChromium: @escaping () -> Void) {
        self.manager = manager
        self.approvals = approvals
        self.profileKeys = profileKeys
        self.localProfilesProvider = localProfilesProvider
        self.notifyChromium = notifyChromium
    }

    /// Hot path: the bridge delegate calls this on every Chromium pull.
    /// Dictionary read only — no I/O, no crypto.
    func profileSyncInfo(forProfileId profileId: String) -> (uuid: String, passphrase: String)? {
        resolved[profileId]
    }

    /// Local profiles as reported by `localProfilesProvider` — the same
    /// enumeration `resolveMappings()` uses internally. Exposed read-only for
    /// the pairing UI (M2-4 Task 5), which needs to list every local profile
    /// alongside the account's remote profiles when `needsPairing` is true.
    func localProfiles() -> [(profileId: String, displayName: String)] {
        localProfilesProvider()
    }

    /// Startup/login entry: unlock without UI, then resolve mappings and ping.
    /// `.needsJoin` / `.notSignedIn` leave the cache empty — the Devices pane
    /// remains the place where joining/bootstrap UI happens.
    ///
    /// Any outcome other than `.unlocked` (including a thrown, possibly
    /// transient, failure) CLEARS the cache rather than leaving it standing.
    /// This direction is deliberately the opposite of `resolveMappings()`'s
    /// transient handling: here the unknown state fails *closed* (Chromium
    /// pulls nil and the sync gate shuts), which is always safe. In
    /// `resolveMappings()` the same uncertainty would fail *open* — minting a
    /// fresh UUID over a live mapping — so there it must be preserved instead.
    func silentUnlockAndResolve() async {
        let result: UnlockResult
        do {
            result = try await manager.unlockAtStartup()
        } catch {
            clearResolved()  // transient (offline etc.) — a later trigger retries
            return
        }
        guard result == .unlocked else {
            clearResolved()
            return
        }
        await resolveMappings()
    }

    /// Drops every cached key and pings Chromium if there was anything to drop,
    /// so a locked / signed-out / account-switched controller stops serving the
    /// previous session's passphrases across the bridge.
    func clearResolved() {
        let wasPopulated = !resolved.isEmpty
        resolved = [:]
        needsPairing = false
        if wasPopulated { notifyChromium() }
    }

    /// Re-runs resolution after external events (pairing applied, approval
    /// completed, bootstrap finished in the Devices pane).
    ///
    /// Error taxonomy (C-1). A local profile's lookup has three outcomes, and
    /// conflating the last two is what caused the silent re-registration bug:
    ///
    /// - record returned  -> mapped and readable; cache it.
    /// - nil returned     -> definitively unmapped (no mapping stored, or the
    ///                       mapping's remote is gone / 404). Eligible for the
    ///                       register / adopt decision below.
    /// - throws           -> UNKNOWN, not absent (offline, 5xx, 401, still
    ///                       locked). Keep whatever was previously resolved and
    ///                       hold this local out of the decision entirely.
    ///
    /// A single unknown local also poisons the *decision* for every other
    /// local: its remote UUID cannot be counted as claimed, so an unrelated
    /// unmapped local could auto-adopt the envelope that actually belongs to
    /// it. So when any local is unknown, the whole register/adopt/pairing
    /// decision is skipped this pass and retried on the next trigger. Likewise
    /// a failed `accountProfiles()` aborts the pass outright — the branches
    /// below are only sound with a fully known remote set.
    func resolveMappings() async {
        var next: [String: (uuid: String, passphrase: String)] = [:]
        var nextNeedsPairing = false
        let locals = localProfilesProvider()
        var unmappedLocals: [(profileId: String, displayName: String)] = []
        var hasUnknownLocal = false
        for local in locals {
            do {
                if let rec = try await profileKeys.resolvedRecord(forLocalProfile: local.profileId) {
                    next[local.profileId] = (rec.uuid, rec.passphrase)
                    probeResolve("existing", profileId: local.profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                } else {
                    // A non-nil priorMapping here means the local is mapped to a UUID
                    // whose server envelope is gone (404) — the stale-mapping wedge that
                    // then trips `alreadyMapped` on re-register. Surface it explicitly.
                    let priorMapping = profileKeys.mappedGlobalUuid(forProfileId: local.profileId)
                    AppLogInfo("[phi-sync-probe] unmapped profile=\(local.profileId) priorMapping=\(priorMapping ?? "none")")
                    unmappedLocals.append(local)
                }
            } catch {
                hasUnknownLocal = true
                AppLogInfo("[phi-sync-probe] unknown(transient) profile=\(local.profileId)")
                if let previous = resolved[local.profileId] { next[local.profileId] = previous }
            }
        }
        if unmappedLocals.isEmpty {
            nextNeedsPairing = false
        } else if hasUnknownLocal {
            // Undecidable this pass — hold the previous answer rather than
            // dropping a "needs pairing" banner because of a network blip.
            nextNeedsPairing = needsPairing
        } else {
            let remotes: [RemoteProfile]
            do {
                remotes = try await profileKeys.accountProfiles()
            } catch {
                // Unknown remote set: abort without touching the cache or
                // pinging. Never fall through to register/adopt from here.
                return
            }
            let claimedUuids = Set(next.values.map { $0.uuid })
            let unclaimedRemotes = remotes.filter { !claimedUuids.contains($0.uuid) }
            if unclaimedRemotes.isEmpty {
                // First device (or all remotes already claimed): register the rest.
                for local in unmappedLocals {
                    // `alreadyMapped` cannot normally reach here (only unmapped
                    // locals are in this list); if it does, skipping is correct
                    // — same handling as any other transient registration miss.
                    if let rec = try? await profileKeys.registerLocalProfile(
                        profileId: local.profileId, displayName: local.displayName) {
                        next[local.profileId] = (rec.uuid, rec.passphrase)
                        probeResolve("register", profileId: local.profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                    }
                }
            } else if unclaimedRemotes.count == 1, unmappedLocals.count == 1 {
                if let rec = try? await profileKeys.adoptRemoteProfile(
                    uuid: unclaimedRemotes[0].uuid, forLocalProfile: unmappedLocals[0].profileId) {
                    next[unmappedLocals[0].profileId] = (rec.uuid, rec.passphrase)
                    probeResolve("adopt", profileId: unmappedLocals[0].profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                }
            } else {
                nextNeedsPairing = true
            }
        }
        // Monotonic within a signed-in session: merge rather than replace, so a
        // partial pass can never erase a previously-good entry. The cache is
        // fully cleared only by `clearResolved()` (lock / sign-out / switch).
        resolved.merge(next) { _, new in new }
        needsPairing = nextNeedsPairing
        AppLogInfo("[phi-sync-probe] resolved=\(resolved.count) needsPairing=\(needsPairing)")
        if !resolved.isEmpty { notifyChromium() }
    }

    /// Temporary M2-5 diagnostic (issue ②, Needs-passphrase): records which key
    /// a profile resolved to, tagged by source, so a delivered passphrase can be
    /// compared across sessions — a changed hash for the same uuid is the
    /// envelope/keybag key desync we're hunting. Logs only a short SHA-256
    /// prefix, never the passphrase itself. Remove once ② is root-caused.
    private func probeResolve(_ source: String, profileId: String, uuid: String, passphrase: String) {
        let ppHash = SHA256.hash(data: Data(passphrase.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        AppLogInfo("[phi-sync-probe] resolve source=\(source) profile=\(profileId) uuid=\(uuid) ppHash=\(ppHash)")
    }
}

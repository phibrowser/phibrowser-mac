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
    func silentUnlockAndResolve() async {
        do {
            guard try await manager.unlockAtStartup() == .unlocked else { return }
        } catch {
            return // transient (offline etc.) — a later trigger retries
        }
        await resolveMappings()
    }

    /// Re-runs resolution after external events (pairing applied, approval
    /// completed, bootstrap finished in the Devices pane).
    func resolveMappings() async {
        needsPairing = false
        var next: [String: (uuid: String, passphrase: String)] = [:]
        let locals = localProfilesProvider()
        var unmappedLocals: [(profileId: String, displayName: String)] = []
        for local in locals {
            if let rec = try? await profileKeys.resolvedRecord(forLocalProfile: local.profileId) {
                next[local.profileId] = (rec.uuid, rec.passphrase)
            } else {
                unmappedLocals.append(local)
            }
        }
        if !unmappedLocals.isEmpty {
            let remotes = (try? await profileKeys.accountProfiles()) ?? []
            let claimedUuids = Set(next.values.map { $0.uuid })
            let unclaimedRemotes = remotes.filter { !claimedUuids.contains($0.uuid) }
            if unclaimedRemotes.isEmpty {
                // First device (or all remotes already claimed): register the rest.
                for local in unmappedLocals {
                    if let rec = try? await profileKeys.registerLocalProfile(
                        profileId: local.profileId, displayName: local.displayName) {
                        next[local.profileId] = (rec.uuid, rec.passphrase)
                    }
                }
            } else if unclaimedRemotes.count == 1, unmappedLocals.count == 1 {
                if let rec = try? await profileKeys.adoptRemoteProfile(
                    uuid: unclaimedRemotes[0].uuid, forLocalProfile: unmappedLocals[0].profileId) {
                    next[unmappedLocals[0].profileId] = (rec.uuid, rec.passphrase)
                }
            } else {
                needsPairing = true
            }
        }
        resolved = next
        if !resolved.isEmpty { notifyChromium() }
    }
}

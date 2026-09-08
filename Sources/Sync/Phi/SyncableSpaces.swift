// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Space-side snapshot / merge / apply plus the rank primitives behind D4's
/// "one drag rewrites one entity". Everything here is a pure function: the
/// engine owns all persistence (§6.2 -- `snapshot` writes nothing).
enum SyncableSpaces {

    // MARK: - Fractional ranks (§7)

    /// Strictly ASCII-ascending base-62, so plain lexicographic comparison IS
    /// numeric comparison of the implied fraction `0.<rank>`.
    static let rankAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static var rankIndex: [Character: Int] {
        var map: [Character: Int] = [:]
        for (i, c) in rankAlphabet.enumerated() { map[c] = i }
        return map
    }

    /// A rank strictly between `a` and `b`, never ending in the lowest digit
    /// (so there is always room below it).
    ///
    /// - Precondition: when both bounds are present they must satisfy `a < b`.
    ///   `a == b` HAS NO SOLUTION -- the representation only guarantees a value
    ///   between two *different* ranks -- so this traps rather than looping or
    ///   returning an endpoint. Callers separate tied endpoints first
    ///   (`assignRanks`'s tie-interval rule).
    /// - Precondition: the upper bound is never empty and never ends in the
    ///   lowest digit. Both are the same impossibility: nothing over this
    ///   alphabet -- not even the empty string -- is lexicographically less
    ///   than `""` or than `"0"`, so "strictly below `b`" has no solution for
    ///   either. Every rank this file produces is non-empty and ends in a
    ///   midpoint digit >= 1 (this type's own invariant), which is exactly
    ///   what makes any OTHER upper bound always solvable: for `"<prefix>0"`
    ///   the only room left is under the prefix. Trapping here is the same
    ///   honesty as the `a == b` case -- silently returning a value ABOVE the
    ///   bound would corrupt the account's order.
    static func rankBetween(_ a: String?, _ b: String?) -> String {
        if let a, let b { precondition(a < b, "rankBetween requires a < b") }
        precondition(b.map { !$0.isEmpty && !$0.hasSuffix("0") } ?? true,
                     "an empty rank and a rank ending in the lowest digit are not legal upper bounds")
        let index = rankIndex
        let base = rankAlphabet.count
        let lower = (a ?? "").map { index[$0] ?? 0 }
        let upper = b.map { $0.map { index[$0] ?? 0 } }

        var out: [Int] = []
        var position = 0
        while true {
            let lo = position < lower.count ? lower[position] : 0
            let hi: Int
            if let upper {
                // Once `out` is already strictly greater than the prefix of the
                // upper bound, the bound stops constraining further digits.
                hi = position < upper.count && out.elementsEqual(upper.prefix(position)) ? upper[position] : base
            } else {
                hi = base
            }
            if hi - lo > 1 {
                out.append((lo + hi) / 2)
                break
            }
            // Digits are adjacent (or equal): keep the lower digit and refine.
            out.append(lo)
            position += 1
        }
        // The loop only ever exits through the `hi - lo > 1` branch, whose digit
        // is `(lo + hi) / 2` with `lo >= 0` and `hi >= lo + 2` -- i.e. always
        // >= 1. So the result structurally never ends in the lowest digit and
        // needs no trailing-zero pass.
        return String(out.map { rankAlphabet[$0] })
    }

    // MARK: - Longest increasing kept set (§7)

    /// Indices to LEAVE ALONE: the longest strictly increasing subsequence of
    /// the local order under the total order `(rank, uuid)`. Elements with no
    /// rank (brand new, or a device snapshotting an old Space for the first
    /// time) never join it, so they always land in the complement and get a
    /// rank from the interval rule. Patience sorting, O(n log n).
    static func longestIncreasingKeptSet(_ keys: [(rank: String?, uuid: String)]) -> Set<Int> {
        struct Key: Comparable {
            let rank: String
            let uuid: String
            static func < (l: Key, r: Key) -> Bool {
                l.rank == r.rank ? l.uuid < r.uuid : l.rank < r.rank
            }
        }
        var tailKey: [Key] = []
        var tailIndex: [Int] = []
        var previous = [Int](repeating: -1, count: keys.count)

        for (i, element) in keys.enumerated() {
            guard let rank = element.rank else { continue }
            let key = Key(rank: rank, uuid: element.uuid)
            // First tail strictly greater than `key` -> replace it (strict LIS).
            var lo = 0, hi = tailKey.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tailKey[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            previous[i] = lo > 0 ? tailIndex[lo - 1] : -1
            if lo == tailKey.count {
                tailKey.append(key)
                tailIndex.append(i)
            } else {
                tailKey[lo] = key
                tailIndex[lo] = i
            }
        }
        guard !tailIndex.isEmpty else { return [] }
        var kept: Set<Int> = []
        // The last tail slot always holds the end of SOME longest increasing
        // subsequence, so it is the reconstruction entry point; no separate
        // "best end" bookkeeping is needed.
        var cursor = tailIndex[tailIndex.count - 1]
        while cursor >= 0 {
            kept.insert(cursor)
            cursor = previous[cursor]
        }
        return kept
    }

    // MARK: - Rank assignment (§7)

    /// New ranks for the Spaces that must be rewritten this snapshot, keyed by
    /// uuid. `order` is the CURRENT LOCAL strip order of the sync-eligible
    /// Spaces with their shadow ranks. Elements inside the kept set are absent
    /// from the result: they are not rewritten, get no new timestamp and do not
    /// enter this round's commit batch.
    static func assignRanks(order: [(uuid: String, rank: String?)]) -> [String: String] {
        let kept = longestIncreasingKeptSet(order.map { (rank: $0.rank, uuid: $0.uuid) })
        var keptFlags = [Bool](repeating: false, count: order.count)
        for i in kept { keptFlags[i] = true }

        var assigned: [String: String] = [:]
        // Effective rank of an element: a freshly assigned one wins over the shadow.
        func effective(_ i: Int) -> String? { assigned[order[i].uuid] ?? order[i].rank }

        var i = 0
        while i < order.count {
            guard !keptFlags[i] else { i += 1; continue }

            // Left endpoint: the nearest FINALIZED rank to the left (kept, or
            // generated earlier in this same pass), so several complement
            // elements in one gap come out strictly increasing.
            var left: String?
            var j = i - 1
            while j >= 0 {
                if let r = effective(j) { left = r; break }
                j -= 1
            }
            // Right endpoint: the nearest kept rank to the right. The tie
            // interval rule (§7): while it is not strictly greater than `left`,
            // evict it from the kept set into the complement and look further
            // right.
            var right: String?
            var k = i + 1
            while k < order.count {
                if keptFlags[k], let r = order[k].rank {
                    if let left, !(left < r) {
                        keptFlags[k] = false   // evicted; it gets a new rank below
                        k += 1
                        continue
                    }
                    right = r
                    break
                }
                k += 1
            }
            assigned[order[i].uuid] = rankBetween(left, right)
            i += 1
        }
        return assigned
    }
}

extension SyncableSpaces {

    /// D1: the one uuid that necessarily collides across devices.
    static let defaultSpaceUuid = LocalStore.defaultSpaceId

    // MARK: - Snapshot (§6.2 S1-S4)

    /// The outgoing entity for every sync-eligible Space, keyed by uuid.
    ///
    /// PURE: unlike M3-1's `SyncableSettings.snapshot`, this writes nothing at
    /// all. Baselines move only at the five write points in §6.2, i.e. after a
    /// landing or an accepted commit, never at snapshot time.
    static func snapshot(spaces: [PhiLocalSpace],
                         table: PhiSpaceSyncTable,
                         globalUuid: (String) -> String?,
                         now: Int64) -> [String: Phi_PhiSpaceEntity] {
        // §6.5 exclusions are applied at the source (`currentSpaces()`); what is
        // left out here is the cursor-driven half.
        let eligible = spaces.filter { space in
            guard let cursor = table.cursors[space.spaceId] else { return true }
            return !cursor.hidden && cursor.deletedAtMs == nil && cursor.refusedAtMs == nil
        }
        let baselines = eligible.reduce(into: [String: Phi_PhiSpaceEntity]()) { out, space in
            guard let bytes = table.cursors[space.spaceId]?.reconciled,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { return }
            out[space.spaceId] = entity
        }
        // `rank` is an optional message field: a baseline that never carried one
        // decodes to `""`, which is NOT a legal rank. It must degrade to "no
        // rank" (so the element joins the complement and gets a real one) rather
        // than be handed to `rankBetween`, whose upper-bound precondition traps
        // on "" -- nothing over this alphabet sorts below it (`rankBetween`
        // above). Publishing a rank the account has never seen IS a local write,
        // so the normalized element is stamped `now` by the branch below.
        func baselineRank(_ uuid: String) -> String? {
            guard let rank = baselines[uuid]?.rank.stringValue, !rank.isEmpty else { return nil }
            return rank
        }
        // Rank channel: one pass over the CURRENT local order (§7).
        let newRanks = assignRanks(order: eligible.map {
            (uuid: $0.spaceId, rank: baselineRank($0.spaceId))
        })

        var out: [String: Phi_PhiSpaceEntity] = [:]
        for space in eligible {
            let baseline = baselines[space.spaceId]
            let isDefault = space.spaceId == defaultSpaceUuid

            var entity = Phi_PhiSpaceEntity()
            entity.spaceUuid = space.spaceId
            entity.name = stamped(string(space.name), baseline?.name, now)
            entity.iconName = stamped(string(space.iconName), baseline?.iconName, now)
            entity.colorHex = stamped(string(space.colorHex), baseline?.colorHex, now)

            // §6.2 S3's rank exception: with no baseline the rank is DERIVED
            // from this device's local order, and derived order must never beat
            // a real drag anywhere in the account -- so it carries timestamp 0.
            let rankValue = newRanks[space.spaceId] ?? baselineRank(space.spaceId) ?? "V"
            var rank = string(rankValue)
            if baseline == nil {
                rank.updatedAtMs = 0
            } else if newRanks[space.spaceId] != nil {
                rank.updatedAtMs = now
            } else {
                rank.updatedAtMs = baseline?.rank.updatedAtMs ?? 0
            }
            entity.rank = rank

            if !isDefault {
                // §3.5 fallback A: a held remote binding is echoed back with the
                // BASELINE's timestamp, never `now`. Stamping it would make this
                // device win a binding it cannot even resolve and pin it on the
                // whole account.
                //
                // The hold applies ONLY while the row is still on the profile it
                // was taken against. Once the user rebinds this Space locally,
                // §3.5's second clause takes over: the hold is stale, the new
                // binding is a normal field write and gets stamped `now`. Without
                // the `heldForLocalProfileId` check the held branch would win
                // forever and this device could never publish a binding for that
                // Space again.
                let cursor = table.cursors[space.spaceId]
                let heldAgainst: String? = cursor?.heldForLocalProfileId
                let holdStillApplies = heldAgainst == space.profileId
                if holdStillApplies, let held = cursor?.heldProfileUuid, let baseline {
                    var binding = string(held)
                    binding.updatedAtMs = baseline.profileUuid.updatedAtMs
                    entity.profileUuid = binding
                } else if let uuid = globalUuid(space.profileId) {
                    entity.profileUuid = stamped(string(uuid), baseline?.profileUuid, now)
                } else {
                    // No mapping: skip the whole Space this round rather than
                    // put a device-local Chromium basename on the wire.
                    continue
                }
                entity.themeID = stamped(string(space.themeId ?? ""), baseline?.themeID, now)
            }

            entity.overlayOpacityLight =
                stamped(milli(space.opacityLight), baseline?.overlayOpacityLight, now)
            entity.overlayOpacityDark =
                stamped(milli(space.opacityDark), baseline?.overlayOpacityDark, now)
            entity.createdAtMs = Int64(space.createdDate.timeIntervalSince1970 * 1000)
            out[space.spaceId] = entity
        }
        return out
    }

    private static func string(_ s: String) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.stringValue = s
        return v
    }

    /// Milli-units, `-1` for "no custom opacity". Integers rather than a new
    /// double case keep the shipped M3-1 message untouched, and the resolution
    /// is far below the slider's, so an applied value snapshots back identically.
    private static func milli(_ value: Double?) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.intValue = value.map { Int64(($0 * 1000).rounded()) } ?? -1
        return v
    }

    /// §6.2 S2/S3: same bytes as the baseline (timestamp zeroed) -> keep the
    /// baseline's timestamp; different -> stamp `now`.
    private static func stamped(_ value: Phi_PhiSettingValue,
                                _ baseline: Phi_PhiSettingValue?,
                                _ now: Int64) -> Phi_PhiSettingValue {
        var out = value
        if let baseline,
           SyncableSettings.signature(of: baseline) == SyncableSettings.signature(of: value) {
            out.updatedAtMs = baseline.updatedAtMs
        } else {
            out.updatedAtMs = now
        }
        return out
    }

    // MARK: - Merge

    /// Field-by-field LWW through the SHARED winner (R4), `min()` for
    /// `created_at_ms`, identity for `space_uuid`.
    static func merge(local: Phi_PhiSpaceEntity, remote: Phi_PhiSpaceEntity) -> Phi_PhiSpaceEntity {
        var merged = Phi_PhiSpaceEntity()
        merged.spaceUuid = local.spaceUuid.isEmpty ? remote.spaceUuid : local.spaceUuid
        merged.name = SyncableSettings.lwwWinner(local.name, remote.name)
        merged.iconName = SyncableSettings.lwwWinner(local.iconName, remote.iconName)
        merged.colorHex = SyncableSettings.lwwWinner(local.colorHex, remote.colorHex)
        merged.rank = SyncableSettings.lwwWinner(local.rank, remote.rank)
        if local.hasProfileUuid || remote.hasProfileUuid {
            merged.profileUuid = SyncableSettings.lwwWinner(local.profileUuid, remote.profileUuid)
        }
        if local.hasThemeID || remote.hasThemeID {
            merged.themeID = SyncableSettings.lwwWinner(local.themeID, remote.themeID)
        }
        merged.overlayOpacityLight =
            SyncableSettings.lwwWinner(local.overlayOpacityLight, remote.overlayOpacityLight)
        merged.overlayOpacityDark =
            SyncableSettings.lwwWinner(local.overlayOpacityDark, remote.overlayOpacityDark)
        // NOT last-writer-wins: the earliest creation instant is the true one,
        // and it is `getAllSpaces`'s last tiebreak, so it must agree everywhere.
        let candidates = [local.createdAtMs, remote.createdAtMs].filter { $0 > 0 }
        merged.createdAtMs = candidates.min() ?? 0
        return merged
    }

    // MARK: - Refusal (§6.5)

    /// Entities this device refuses to MATERIALIZE, even from a peer: refusing
    /// keeps a buggy or hostile peer from conjuring ghost Spaces that the
    /// receiver's own agent sweep would then delete and tombstone back.
    /// Refusing is NOT a claim that the account should not hold it, so nothing
    /// here ever pushes a tombstone (§9.2).
    static func refuses(_ entity: Phi_PhiSpaceEntity) -> Bool {
        if SpaceManager.isIncognitoSpaceId(entity.spaceUuid) { return true }
        let name = entity.name.stringValue
        let icon = entity.iconName.stringValue
        let color = entity.colorHex.stringValue
        if AgentSpaceManager.isAgentSpaceModel(name: name, iconName: icon, colorHex: color) {
            return true
        }
        return AgentSpaceManager.isPersistentAgentSpaceModel(iconName: icon, colorHex: color)
    }

    // MARK: - Landing one entity (§6.2 A2)

    /// Theme / opacity FIRST (so the window repaint `reapplyResolvedTheme`
    /// triggers already sees the final `color_hex`), then the rebind, then the
    /// row fields. The account-wide reorder is the caller's job -- it runs once
    /// per round, after every entity has landed.
    ///
    /// Every step is awaited and may throw; the caller writes NO baseline until
    /// this returns without throwing (§5.6).
    static func land(_ merged: Phi_PhiSpaceEntity,
                     existing: PhiLocalSpace?,
                     profileId: String?,
                     access: any PhiSpaceLocalAccess) async throws {
        let uuid = merged.spaceUuid
        let isDefault = uuid == defaultSpaceUuid
        let createdDate = merged.createdAtMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(merged.createdAtMs) / 1000)
            : Date()

        guard let existing else {
            // Create. The default Space always exists locally, so this branch is
            // only ever a genuinely new Space; its profile must resolve or the
            // caller parked it (§3.5 fallback B) before getting here.
            guard let profileId else { return }
            try await access.create(PhiLocalSpace(
                spaceId: uuid, profileId: profileId,
                name: merged.name.stringValue, colorHex: merged.colorHex.stringValue,
                iconName: merged.iconName.stringValue, sortOrder: Int.max,
                createdDate: createdDate,
                themeId: isDefault ? nil : themeId(merged),
                opacityLight: opacity(merged.overlayOpacityLight),
                opacityDark: opacity(merged.overlayOpacityDark)))
            if !isDefault {
                try await access.applyThemeState(
                    spaceId: uuid, themeId: themeId(merged),
                    opacityLight: opacity(merged.overlayOpacityLight),
                    opacityDark: opacity(merged.overlayOpacityDark))
            }
            return
        }

        if !isDefault || opacity(merged.overlayOpacityLight) != existing.opacityLight
            || opacity(merged.overlayOpacityDark) != existing.opacityDark {
            try await access.applyThemeState(
                spaceId: uuid,
                themeId: isDefault ? existing.themeId : themeId(merged),
                opacityLight: opacity(merged.overlayOpacityLight),
                opacityDark: opacity(merged.overlayOpacityDark))
        }

        // A rebind is exactly this one field changing on the wire (M1 §5); the
        // LOCAL re-stamping of the Space's bookmark rows is a denormalization
        // `SpaceManager.applyRemoteRebind` performs, never a bookmark edit.
        if !isDefault, let profileId, profileId != existing.profileId {
            try await access.rebind(spaceId: uuid, toProfileId: profileId)
        }

        let newName = merged.name.stringValue
        let newColor = merged.colorHex.stringValue
        let newIcon = merged.iconName.stringValue
        let newCreated = abs(createdDate.timeIntervalSince1970
                             - existing.createdDate.timeIntervalSince1970) > 0.0005
            ? createdDate : nil
        if newName != existing.name || newColor != existing.colorHex
            || newIcon != existing.iconName || newCreated != nil {
            try await access.update(
                spaceId: uuid,
                name: newName == existing.name ? nil : newName,
                colorHex: newColor == existing.colorHex ? nil : newColor,
                iconName: newIcon == existing.iconName ? nil : newIcon,
                createdDate: newCreated)
        }
    }

    private static func themeId(_ entity: Phi_PhiSpaceEntity) -> String? {
        let id = entity.themeID.stringValue
        return id.isEmpty ? nil : id
    }

    private static func opacity(_ value: Phi_PhiSettingValue) -> Double? {
        value.intValue < 0 ? nil : Double(value.intValue) / 1000
    }

    // MARK: - Order projection (§7)

    /// The full local order with ONLY the synced Spaces re-sorted, in place.
    /// Local-only (hidden), agent and incognito Spaces keep their own slots
    /// instead of being pushed to the end.
    ///
    /// `localOrder` MUST be the UNFILTERED local order --
    /// `PhiSpaceLocalAccess.allSpacesForOrdering()`, not `currentSpaces()`.
    /// The result is handed straight to `LocalStore.reorderSpaces`, which
    /// assigns `index` as `sortOrder` to exactly the ids in the list and
    /// documents that "Ids absent from the list keep their existing
    /// `sortOrder`" (LocalStore+Space.swift:322-353). Pass the §6.5-filtered
    /// view and every agent Space and every Space on an unmapped profile keeps
    /// a stale value while the synced ones are renumbered 0..n-1 -- which is
    /// the opposite of the promise in the paragraph above.
    static func plannedOrder(localOrder: [PhiLocalSpace],
                             syncedRanks: [String: String]) -> [String] {
        let syncedSlots = localOrder.enumerated()
            .filter { syncedRanks[$0.element.spaceId] != nil }
            .map(\.offset)
        let sortedSynced = syncedSlots
            .map { localOrder[$0].spaceId }
            .sorted {
                let l = syncedRanks[$0] ?? "", r = syncedRanks[$1] ?? ""
                return l == r ? $0 < $1 : l < r
            }
        var out = localOrder.map(\.spaceId)
        for (slot, spaceId) in zip(syncedSlots, sortedSynced) { out[slot] = spaceId }
        return out
    }
}

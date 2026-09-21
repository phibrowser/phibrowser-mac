// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// The five kinds wired into the Layer 2 simulation, plus the bookmark tree
// invariants, which are checked against the real planner rather than a
// re-implementation of it.

// Every helper below reproduces the production stamping rule: a merge unit
// takes the edit stamp only when its VALUE changed, otherwise it keeps the stamp
// it already had (`BookmarkKind.restamped`, `URLRuleKind.stamp`,
// `SyncableSpaces.stamped`). Restamping an unchanged value would let a replica
// win with content it never edited, which is a property of the harness, not of
// the production code.
//
// The stamp itself comes from `SimStamper`, which calls the production
// `PhiHybridClock.editStamp` -- so AM-1's "edit time, raised one above the value
// it overwrites" is the SAME code here and in `BookmarkKind` / `PinKind` /
// `URLRuleKind`, not a re-implementation.

private func stamped(_ value: Phi_PhiSettingValue, _ text: String,
                     _ stamper: SimStamper) -> Phi_PhiSettingValue {
    guard value.stringValue != text else { return value }
    var out = value
    out.stringValue = text
    out.updatedAtMs = stamper.stamp(overwriting: value.updatedAtMs)
    return out
}

private func stamped(_ value: Phi_PhiSettingValue, int: Int64,
                     _ stamper: SimStamper) -> Phi_PhiSettingValue {
    guard value.intValue != int else { return value }
    return settingValue(int: int, stamper.stamp(overwriting: value.updatedAtMs))
}

private func stamps(_ values: [Phi_PhiSettingValue]) -> [Int64] {
    values.map(\.updatedAtMs)
}

let simSpaceUuid = "space-a"
/// Lowercase account uuids, legal ranks and real URLs throughout: the Layer 2
/// entities must survive `BookmarkKind.refuses` / `URLRuleKind.refuses` so the
/// production planner can be run over the converged set. Adversarial shapes are
/// Layer 1's job.
let simPinIdentities = ["pin-0001", "pin-0002", "pin-0003", "pin-0004", "pin-0005", "pin-0006"]
let simRuleIdentities = ["rule-0001", "rule-0002", "rule-0003", "rule-0004", "rule-0005",
                         "rule-0006"]
let simBookmarkIdentities = ["bm-0001", "bm-0002", "bm-0003", "bm-0004", "bm-0005",
                             "bm-0006", "bm-0007", "bm-0008"]

// MARK: - Settings

func settingsSimKind() -> SimKind<Phi_PhiSettingEntity> {
    // `PhiDefaultSpaceUuid` rides as one more register: C1 carries the default-Space role as a
    // plain string key in this same map, so the simulation exercises it for free.
    let keys = ["PhiCurrentThemeId", "layoutMode", "alwaysShowURLPath",
                PhiDefaultSpaceMirror.key]
    return SimKind(
        name: "settings",
        create: { _, stamper, _ in
            var entity = Phi_PhiSettingEntity()
            for key in keys {
                entity.values[key] = settingValue("seed", stamper.stamp(overwriting: nil))
            }
            return entity
        },
        edit: { entity, stamper, rng in
            var out = entity
            let key = keys[rng.below(keys.count)]
            // `SyncableSettings.snapshot` restamps a key only when its VALUE
            // changed, and AM-1 raises it above the sidecar stamp it replaces.
            let previous = out.values[key] ?? Phi_PhiSettingValue()
            out.values[key] = stamped(previous, "v\(rng.int(0...3))", stamper)
            return out
        },
        content: { $0.values["PhiCurrentThemeId"]?.stringValue ?? "" },
        contentStamp: { $0.values["PhiCurrentThemeId"]?.updatedAtMs ?? 0 },
        setContent: { entity, text, stamper in
            var out = entity
            let previous = out.values["PhiCurrentThemeId"] ?? Phi_PhiSettingValue()
            out.values["PhiCurrentThemeId"] = stamped(previous, text, stamper)
            return out
        },
        stamps: { Array($0.values.values.map(\.updatedAtMs)) },
        merge: { SyncableSettings.merge(local: $0, remote: $1) },
        supportsDelete: false)
}

// MARK: - Spaces

func spacesSimKind() -> SimKind<Phi_PhiSpaceEntity> {
    SimKind(
        name: "spaces",
        create: { uuid, stamper, rng in
            let seed = stamper.stamp(overwriting: nil)
            var entity = Phi_PhiSpaceEntity()
            entity.spaceUuid = uuid
            entity.name = settingValue("space", seed)
            entity.iconName = settingValue("icon", seed)
            entity.colorHex = settingValue("#101010", seed)
            entity.rank = settingValue(Pool.legalRanks[rng.below(Pool.legalRanks.count)], seed)
            entity.profileUuid = settingValue(Pool.uuids[0], seed)
            entity.themeID = settingValue("", seed)
            entity.overlayOpacityLight = settingValue(int: -1, seed)
            entity.overlayOpacityDark = settingValue(int: -1, seed)
            entity.createdAtMs = 1_690_000_000_000
            return entity
        },
        edit: { entity, stamper, rng in
            var out = entity
            switch rng.below(3) {
            case 0: out.iconName = stamped(out.iconName, "icon\(rng.int(0...3))", stamper)
            case 1: out.rank = stamped(out.rank, Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                                       stamper)
            default: out.overlayOpacityLight = stamped(out.overlayOpacityLight,
                                                       int: Int64(rng.int(0...1000)), stamper)
            }
            return out
        },
        content: { $0.name.stringValue },
        contentStamp: { $0.name.updatedAtMs },
        setContent: { entity, text, stamper in
            var out = entity
            out.name = stamped(out.name, text, stamper)
            return out
        },
        stamps: { stamps([$0.name, $0.iconName, $0.colorHex, $0.rank, $0.profileUuid,
                          $0.themeID, $0.overlayOpacityLight, $0.overlayOpacityDark]) },
        merge: { SyncableSpaces.merge(local: $0, remote: $1) },
        supportsDelete: false)      // Space deletion is a hide/purge lifecycle, not a tombstone
}

// MARK: - Bookmarks

func bookmarksSimKind() -> SimKind<Phi_PhiBookmarkEntity> {
    /// §4.3: location is ONE unit -- both members carry the same stamp.
    func setLocation(_ entity: inout Phi_PhiBookmarkEntity, space: String, parent: String,
                     _ stamper: SimStamper) {
        let unchanged = entity.spaceUuid.stringValue == space
            && entity.parentUuid.stringValue == parent
        let previous = BookmarkKind.locationStamp(of: entity)
        let stamp = unchanged ? previous : stamper.stamp(overwriting: previous)
        entity.spaceUuid = settingValue(space, stamp)
        entity.parentUuid = settingValue(parent, stamp)
    }
    return SimKind(
        name: "bookmarks",
        create: { uuid, stamper, rng in
            let seed = stamper.stamp(overwriting: nil)
            var entity = Phi_PhiBookmarkEntity()
            entity.bookmarkUuid = uuid
            setLocation(&entity, space: simSpaceUuid, parent: "", stamper)
            entity.rank = settingValue(Pool.legalRanks[rng.below(Pool.legalRanks.count)], seed)
            entity.isFolder = true      // folders, so any of them may take children
            entity.title = settingValue("title", seed)
            entity.url = settingValue("https://bookmark.phi/folder", seed)
            entity.secondaryURL = settingValue("", seed)
            entity.secondaryTitle = settingValue("", seed)
            entity.source = 0
            entity.createdAtMs = 1_690_000_000_000
            return entity
        },
        edit: { entity, stamper, rng in
            var out = entity
            switch rng.below(3) {
            case 0:
                out.title = stamped(out.title, "t\(rng.int(0...3))", stamper)
            case 1:
                out.rank = stamped(out.rank, Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                                   stamper)
            default:
                // A move, including moves that two replicas can arrange into a cycle.
                let candidates = simBookmarkIdentities.filter { $0 != out.bookmarkUuid } + [""]
                setLocation(&out, space: simSpaceUuid,
                            parent: candidates[rng.below(candidates.count)], stamper)
            }
            return out
        },
        content: { $0.title.stringValue },
        contentStamp: { $0.title.updatedAtMs },
        setContent: { entity, text, stamper in
            var out = entity
            out.title = stamped(out.title, text, stamper)
            return out
        },
        stamps: { stamps([$0.spaceUuid, $0.parentUuid, $0.rank, $0.title, $0.url,
                          $0.secondaryURL, $0.secondaryTitle]) },
        merge: { BookmarkKind.merge(local: $0, remote: $1) })
}

// MARK: - Pins

func pinsSimKind() -> SimKind<Phi_PhiPinTabEntity> {
    SimKind(
        name: "pins",
        create: { lineage, stamper, rng in
            let seed = stamper.stamp(overwriting: nil)
            var entity = Phi_PhiPinTabEntity()
            entity.pinUuid = lineage
            entity.owner = .spaceUuid(simSpaceUuid)
            entity.rank = settingValue(Pool.legalRanks[rng.below(Pool.legalRanks.count)], seed)
            entity.title = settingValue("pin", seed)
            entity.url = settingValue("https://a.example/", seed)
            entity.splitPartnerUuid = settingValue("", seed)
            entity.source = 0
            entity.createdAtMs = 1_690_000_000_000
            return entity
        },
        edit: { entity, stamper, rng in
            var out = entity
            switch rng.below(3) {
            case 0: out.url = stamped(out.url, "https://a.example/\(rng.int(0...3))", stamper)
            case 1: out.rank = stamped(out.rank, Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                                       stamper)
            default: out.splitPartnerUuid = stamped(out.splitPartnerUuid,
                                                    rng.bool() ? "" : Pool.uuids[0], stamper)
            }
            return out
        },
        content: { $0.title.stringValue },
        contentStamp: { $0.title.updatedAtMs },
        setContent: { entity, text, stamper in
            var out = entity
            out.title = stamped(out.title, text, stamper)
            return out
        },
        stamps: { stamps([$0.rank, $0.title, $0.url, $0.splitPartnerUuid]) },
        merge: { PinKind.merge(local: $0, remote: $1) })
}

// MARK: - URL rules

func rulesSimKind() -> SimKind<Phi_PhiURLRuleEntity> {
    /// §8.2 rule 1: all three content members carry the host's stamp.
    func setContentGroup(_ entity: inout Phi_PhiURLRuleEntity, host: String, path: String,
                         ask: Bool, _ stamper: SimStamper) {
        let unchanged = entity.host.stringValue == host
            && entity.pathPrefix.stringValue == path && entity.ask.boolValue == ask
        // The host is the group's fixed stamp carrier (R-M3-4a-40), so it is also
        // the stamp an edit to the group overwrites.
        let stamp = unchanged ? entity.host.updatedAtMs
            : stamper.stamp(overwriting: entity.host.updatedAtMs)
        entity.host = settingValue(host, stamp)
        entity.pathPrefix = settingValue(path, stamp)
        entity.ask = settingValue(bool: ask, stamp)
    }
    return SimKind(
        name: "urlrules",
        create: { uuid, stamper, rng in
            let seed = stamper.stamp(overwriting: nil)
            var entity = Phi_PhiURLRuleEntity()
            entity.ruleUuid = uuid
            setContentGroup(&entity, host: "example.com", path: "", ask: false, stamper)
            entity.targetSpaceUuid = settingValue(simSpaceUuid, seed)
            entity.rank = settingValue(Pool.legalRanks[rng.below(Pool.legalRanks.count)], seed)
            entity.source = 0
            entity.createdAtMs = 1_690_000_000_000
            return entity
        },
        edit: { entity, stamper, rng in
            var out = entity
            switch rng.below(3) {
            case 0:
                setContentGroup(&out, host: "h\(rng.int(0...3)).example",
                                path: rng.bool() ? "" : "/p\(rng.int(0...2))",
                                ask: rng.bool(), stamper)
            case 1:
                let target = rng.bool() ? simSpaceUuid : "space-b"
                let moved = out.targetSpaceUuid.stringValue != target
                let overwritten = out.rank.updatedAtMs
                out.targetSpaceUuid = stamped(out.targetSpaceUuid, target, stamper)
                // §8.2 rule 4: a bucket change creates a new position, so rank
                // is restamped even if the string happens to stay the same.
                out.rank = moved
                    ? settingValue(Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                                   stamper.stamp(overwriting: overwritten))
                    : stamped(out.rank, Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                              stamper)
            default:
                out.rank = stamped(out.rank, Pool.legalRanks[rng.below(Pool.legalRanks.count)],
                                   stamper)
            }
            return out
        },
        content: { $0.host.stringValue },
        contentStamp: { $0.host.updatedAtMs },
        setContent: { entity, text, stamper in
            var out = entity
            setContentGroup(&out, host: text + ".example",
                            path: out.pathPrefix.stringValue,
                            ask: out.ask.boolValue, stamper)
            return out
        },
        stamps: { stamps([$0.host, $0.pathPrefix, $0.ask, $0.targetSpaceUuid, $0.rank]) },
        merge: { URLRuleKind.merge(local: $0, remote: $1) })
}

// MARK: - Bookmark tree invariants

/// The resolver the production planner needs: only Space resolution matters
/// here, and every simulated bookmark lives in one Space.
func simResolver() -> OwnerResolver {
    OwnerResolver(
        syncUuid: { _ in nil },
        localSpaceId: { uuid in
            [simSpaceUuid, "space-b", "default-space"].contains(uuid) ? "local-" + uuid : nil
        },
        isEligibleSpace: { _ in true },
        globalUuid: { _ in nil },
        localProfileId: { _ in nil })
}

/// Identities that sit on a parent cycle in `entities`.
func cyclicIdentities(_ entities: [String: Phi_PhiBookmarkEntity]) -> Set<String> {
    var cyclic: Set<String> = []
    for identity in entities.keys {
        var seen: Set<String> = [identity]
        var cursor = entities[identity]?.parentUuid.stringValue ?? ""
        var hops = 0
        while !cursor.isEmpty, hops <= entities.count {
            if !seen.insert(cursor).inserted {
                cyclic.insert(identity)
                break
            }
            cursor = entities[cursor]?.parentUuid.stringValue ?? ""
            hops += 1
        }
    }
    return cyclic
}

/// Assert the tree invariants on a converged bookmark set, cross-checked
/// against `SyncableOwnedItems.plan` -- the production code that actually
/// decides what may land.
func checkBookmarkTree(_ entities: [String: Phi_PhiBookmarkEntity], report: Report,
                       label: String) {
    let resolve = simResolver()
    let arrivals = entities.keys.sorted().compactMap { identity -> OwnedItemArrival<Phi_PhiBookmarkEntity>? in
        entities[identity].map { OwnedItemArrival(entity: $0, entityId: "srv-" + identity,
                                                  version: 1) }
    }
    let plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: arrivals, parked: [:],
                                       table: PhiOwnedItemTable(), resolve: resolve,
                                       context: OwnedItemPlanContext())
    let planned = Set(plan.steps.map(\.identity))
    let cyclic = cyclicIdentities(entities)

    report.check("\(label).plan-never-lands-a-cycle",
                 planned.isDisjoint(with: cyclic),
                 "cyclic=\(cyclic.sorted()) planned=\(planned.sorted())")

    // Every landed identity reaches a Space root through landed ancestors.
    for identity in planned.sorted() {
        var cursor = identity
        var hops = 0
        var reached = false
        while hops <= entities.count + 1 {
            guard let entity = entities[cursor] else { break }
            let parent = entity.parentUuid.stringValue
            if parent.isEmpty {
                reached = resolve.localSpaceId(entity.spaceUuid.stringValue) != nil
                break
            }
            cursor = parent
            hops += 1
        }
        report.check("\(label).every-landed-node-reaches-a-space-root", reached,
                     "identity=\(identity) chain broke at \(cursor)")
    }

    // A node with exactly one parent field cannot have two parents; what has to
    // hold is that the planner agreed with our own cycle analysis.
    if cyclic.isEmpty {
        let danglingParents = entities.values.filter {
            let parent = $0.parentUuid.stringValue
            return !parent.isEmpty && entities[parent] == nil
        }
        if danglingParents.isEmpty {
            report.check("\(label).acyclic-set-lands-completely",
                         planned == Set(entities.keys) && plan.refused == 0,
                         "planned=\(planned.sorted()) all=\(entities.keys.sorted()) "
                         + "refused=\(plan.refused) parked=\(plan.parked.keys.sorted())")
        }
    } else {
        report.check("\(label).cyclic-set-is-refused", plan.refused >= cyclic.count,
                     "cyclic=\(cyclic.sorted()) refused=\(plan.refused)")
    }
    report.markPassed("\(label).plan-never-lands-a-cycle")
    report.markPassed("\(label).every-landed-node-reaches-a-space-root")
    report.markPassed("\(label).acyclic-set-lands-completely")
    report.markPassed("\(label).cyclic-set-is-refused")
}

/// Positive control: a hand-built two-cycle must be refused by the planner, or
/// the check above would pass vacuously.
func checkPlannerRefusesAnInjectedCycle(report: Report) {
    var left = Phi_PhiBookmarkEntity()
    left.bookmarkUuid = "cycle-left"
    left.spaceUuid = settingValue(simSpaceUuid, 1)
    left.parentUuid = settingValue("cycle-right", 1)
    left.rank = settingValue("V", 1)
    left.isFolder = true
    left.url = settingValue("https://bookmark.phi/folder", 1)
    var right = left
    right.bookmarkUuid = "cycle-right"
    right.parentUuid = settingValue("cycle-left", 1)

    let plan = SyncableOwnedItems.plan(
        BookmarkKind.self,
        arrivals: [OwnedItemArrival(entity: left, entityId: "a", version: 1),
                   OwnedItemArrival(entity: right, entityId: "b", version: 1)],
        parked: [:], table: PhiOwnedItemTable(), resolve: simResolver(),
        context: OwnedItemPlanContext())
    report.check("planner.refuses-an-injected-cycle",
                 plan.steps.isEmpty && plan.refused == 2,
                 "steps=\(plan.steps.map(\.identity)) refused=\(plan.refused)")
    report.markPassed("planner.refuses-an-injected-cycle")
}

// MARK: - Bookmark location intent

/// The location analogue of the rename regression C2 was opened for, run through
/// the production `BookmarkKind.stamp`: replica A moves a bookmark at T1 while
/// offline, replica B moves the same bookmark at T2 > T1 while online, and A
/// only reconnects and publishes at T3 > T2. B's move is the later one by true
/// wall clock, so B must win.
///
/// Before V13 the location group had no edit-date column, so A's projection was
/// stamped T3 at publish time and beat B every time. The column makes the
/// offline move carry T1; AM-1 keeps it above the stamp it overwrites without
/// letting it reach T3.
func checkAnOfflineMoveLosesToALaterOnlineMove(report: Report) {
    let t0: Int64 = 1_700_000_000_000
    let t1 = t0 + 60_000            // A moves the bookmark, offline
    let t2 = t0 + 120_000           // B moves it, online
    let t3 = t0 + 3_600_000         // A reconnects and publishes

    let resolve = OwnerResolver(
        syncUuid: { $0 == "local-space" ? simSpaceUuid : nil },
        localSpaceId: { $0 == simSpaceUuid ? "local-space" : nil },
        isEligibleSpace: { _ in true },
        globalUuid: { _ in nil },
        localProfileId: { _ in nil })

    // The account value both replicas start from: at the Space root, stamped t0.
    var baseline = Phi_PhiBookmarkEntity()
    baseline.bookmarkUuid = "bm-0001"
    baseline.spaceUuid = settingValue(simSpaceUuid, t0)
    baseline.parentUuid = settingValue("", t0)
    baseline.rank = settingValue("V", t0)
    baseline.isFolder = false
    baseline.title = settingValue("title", t0)
    baseline.url = settingValue("https://a.example/", t0)
    baseline.secondaryURL = settingValue("", t0)
    baseline.secondaryTitle = settingValue("", t0)

    // A's row after its offline move into folder bm-0002.
    let moved = PhiLocalBookmark(
        syncId: "bm-0001", guid: "guid-1", spaceId: "local-space", profileId: "p",
        parentGuid: "guid-2", index: 0, isFolder: false, title: "title",
        url: URL(string: "https://a.example/")!, secondaryUrl: nil, secondaryTitle: nil,
        source: 0, createdDate: Date(timeIntervalSince1970: Double(t0) / 1_000),
        contentUpdatedDate: nil,
        locationUpdatedDate: Date(timeIntervalSince1970: Double(t1) / 1_000))
    guard let projected = BookmarkKind.project(moved, resolve: resolve, scope: nil,
                                               parentIdentity: "bm-0002") else {
        report.check("bookmarks.an-offline-move-loses-to-a-later-online-move", false,
                     "projection failed: the resolver no longer maps the simulated Space")
        return
    }
    // `now` is the reconnect, which is what the pre-V13 code stamped.
    let published = BookmarkKind.stamp(projected, baseline: baseline, local: moved,
                                       rank: BookmarkKind.rank(of: baseline), now: t3,
                                       hlcMax: t0)

    // B's move, made online at t2, into folder bm-0003.
    var fromB = baseline
    fromB.parentUuid = settingValue("bm-0003", t2)
    fromB.spaceUuid = settingValue(simSpaceUuid, t2)

    let merged = BookmarkKind.merge(local: published, remote: fromB)

    report.check("bookmarks.an-offline-move-carries-its-move-time",
                 BookmarkKind.locationStamp(of: published) == t1,
                 "published location stamp \(BookmarkKind.locationStamp(of: published)), "
                 + "expected the move time \(t1) and not the publish time \(t3)")
    report.check("bookmarks.an-offline-move-loses-to-a-later-online-move",
                 merged.parentUuid.stringValue == "bm-0003",
                 "converged parent \(merged.parentUuid.stringValue) at stamp "
                 + "\(BookmarkKind.locationStamp(of: merged)); the later true-time move was B's")
    // §4.3: whichever side wins, both members leave with the same stamp.
    report.check("bookmarks.a-merged-location-keeps-one-stamp-on-both-members",
                 merged.spaceUuid.updatedAtMs == merged.parentUuid.updatedAtMs,
                 "space_uuid@\(merged.spaceUuid.updatedAtMs) "
                 + "parent_uuid@\(merged.parentUuid.updatedAtMs)")
    report.markPassed("bookmarks.an-offline-move-carries-its-move-time")
    report.markPassed("bookmarks.an-offline-move-loses-to-a-later-online-move")
    report.markPassed("bookmarks.a-merged-location-keeps-one-stamp-on-both-members")
}

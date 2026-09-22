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
        merge: { BookmarkKind.merge(local: $0, remote: $1) },
        holdsUnpublishedEdit: { holdsUnpublishedEdit(BookmarkKind.self, local: $0, baseline: $1) },
        beatsDeleteDecision: { beatsDeleteDecision(BookmarkKind.self, remote: $0,
                                                   decidedAtMs: $1) })
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
        merge: { PinKind.merge(local: $0, remote: $1) },
        holdsUnpublishedEdit: { holdsUnpublishedEdit(PinKind.self, local: $0, baseline: $1) },
        beatsDeleteDecision: { beatsDeleteDecision(PinKind.self, remote: $0, decidedAtMs: $1) })
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
        merge: { URLRuleKind.merge(local: $0, remote: $1) },
        holdsUnpublishedEdit: { holdsUnpublishedEdit(URLRuleKind.self, local: $0, baseline: $1) },
        beatsDeleteDecision: { beatsDeleteDecision(URLRuleKind.self, remote: $0,
                                                   decidedAtMs: $1) })
}

// MARK: - C4 "edit beats delete": the two production decisions

/// Direction (i). `SyncableOwnedItems.unpublishedEdits` is the production predicate, and it reads
/// a projection table plus a cursor table, so build the one-entry pair the engine would hand it:
/// the round's local projection and the cursor whose `reconciled` is the baseline. Membership of
/// the projection map is what carries the "a live local row currently claims this identity"
/// conjunct in production; here the caller only reaches this closure when the row is live.
func holdsUnpublishedEdit<K: OwnedItemKind>(_ kind: K.Type, local: K.Entity,
                                            baseline: K.Entity) -> Bool {
    guard let projection = try? K.envelope(local).serializedData(),
          let baselineBytes = try? K.envelope(baseline).serializedData() else { return false }
    var table = PhiOwnedItemTable()
    var cursor = PhiOwnedItemCursor()
    cursor.reconciled = baselineBytes
    table.cursors["x"] = cursor
    return !SyncableOwnedItems.unpublishedEdits(K.self, projections: ["x": projection],
                                                table: table).isEmpty
}

/// Direction (ii): A9's first conjunct as ruling C4-a amends it, from the production kind queries.
func beatsDeleteDecision<K: OwnedItemKind>(_ kind: K.Type, remote: K.Entity,
                                           decidedAtMs: Int64) -> Bool {
    max(K.locationStamp(of: remote), K.contentStamp(of: remote)) > decidedAtMs
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

/// Identities that sit on a parent cycle in `parentOf`.
func cyclicParents(_ parentOf: [String: String]) -> Set<String> {
    var cyclic: Set<String> = []
    for identity in parentOf.keys {
        var seen: Set<String> = [identity]
        var cursor = parentOf[identity] ?? ""
        var hops = 0
        while !cursor.isEmpty, hops <= parentOf.count {
            if !seen.insert(cursor).inserted {
                cyclic.insert(identity)
                break
            }
            cursor = parentOf[cursor] ?? ""
            hops += 1
        }
    }
    return cyclic
}

/// Identities that sit on a parent cycle in `entities`.
func cyclicIdentities(_ entities: [String: Phi_PhiBookmarkEntity]) -> Set<String> {
    cyclicParents(entities.mapValues { $0.parentUuid.stringValue })
}

/// Where each identity actually LANDS: the parent the step names when it names one — a lift, or
/// C5-a's revert to the baseline parent — otherwise the parent in the bytes the step carries, and
/// otherwise the location the arrival already had.
func landedParents(_ entities: [String: Phi_PhiBookmarkEntity],
                   plan: OwnedItemPlan) -> [String: String] {
    var out = entities.mapValues { $0.parentUuid.stringValue }
    for step in plan.steps {
        if let parent = step.newParentUuid {
            out[step.identity] = parent
            continue
        }
        guard let payload = step.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        out[step.identity] = entity.parentUuid.stringValue
    }
    return out
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
    // The invariant is about the tree the plan LANDS, not the one it was handed: under ruling
    // C5-a an arriving cycle lands, with its oldest move put back where the account last agreed
    // it was, and the result must be acyclic.
    let landed = landedParents(entities, plan: plan)

    report.check("\(label).plan-never-lands-a-cycle",
                 planned.isDisjoint(with: cyclicParents(landed)),
                 "cyclic=\(cyclic.sorted()) landed-cyclic=\(cyclicParents(landed).sorted()) "
                 + "planned=\(planned.sorted())")

    // Every landed identity reaches a Space root through landed ancestors.
    for identity in planned.sorted() {
        var cursor = identity
        var hops = 0
        var reached = false
        while hops <= entities.count + 1 {
            guard let entity = entities[cursor] else { break }
            let parent = landed[cursor] ?? ""
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
        // C5-a: a cycle is broken, not refused. Every member lands, and the one whose move lost
        // is the only one that moved somewhere other than where it asked to go.
        report.check("\(label).cyclic-set-is-broken-not-refused",
                     plan.cyclesBroken >= 1 && plan.refused == 0
                         && cyclic.isSubset(of: planned),
                     "cyclic=\(cyclic.sorted()) planned=\(planned.sorted()) "
                     + "cycles_broken=\(plan.cyclesBroken) refused=\(plan.refused)")
    }
    report.markPassed("\(label).plan-never-lands-a-cycle")
    report.markPassed("\(label).every-landed-node-reaches-a-space-root")
    report.markPassed("\(label).acyclic-set-lands-completely")
    report.markPassed("\(label).cyclic-set-is-broken-not-refused")
}

/// Positive control: a hand-built two-cycle must be resolved by the planner, or
/// the check above would pass vacuously.
///
/// Both moves here carry the same stamp, so the tie is broken on the UUID: `cycle-right` is the
/// greater one, so its move stands and `cycle-left` is the loser. Neither side has a baseline on
/// this device, so the loser goes back to the Space root -- the only location every device can
/// name for a folder it has never seen anywhere else.
func checkPlannerBreaksAnInjectedCycle(report: Report) {
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
    let landed = landedParents(["cycle-left": left, "cycle-right": right], plan: plan)
    report.check("planner.breaks-an-injected-cycle",
                 plan.cyclesBroken == 1 && plan.refused == 0
                     && Set(plan.steps.map(\.identity)) == ["cycle-left", "cycle-right"]
                     && landed["cycle-left"] == "" && landed["cycle-right"] == "cycle-left"
                     && plan.mustRepublish == ["cycle-left"],
                 "steps=\(plan.steps.map(\.identity)) cycles_broken=\(plan.cyclesBroken) "
                 + "refused=\(plan.refused) landed=\(landed) "
                 + "republish=\(plan.mustRepublish.sorted())")
    // The revert is stamped one above every stamp in the cycle, from the cycle's own values, so
    // the same page landed on another device -- or on this one twice -- produces the same bytes.
    report.check("planner.stamps-a-cycle-revert-above-the-cycle",
                 plan.cycleStampMs == 2
                     && plan.steps.compactMap { step -> Int64? in
                         guard step.identity == "cycle-left", let payload = step.payload,
                               let envelope = try? Phi_PhiEntity(serializedBytes: payload),
                               let entity = BookmarkKind.entity(from: envelope) else { return nil }
                         return BookmarkKind.locationStamp(of: entity)
                     }.allSatisfy { $0 == 2 },
                 "cycle stamp \(plan.cycleStampMs), expected 2 = max(1, 1) + 1")
    report.markPassed("planner.breaks-an-injected-cycle")
    report.markPassed("planner.stamps-a-cycle-revert-above-the-cycle")
}

// MARK: - C5-a: concurrent folder-move cycles

/// One replica of the cross-move scenario. Unlike `SimReplica` this one LANDS through the
/// production planner, so it keeps the engine's two baselines apart: `baseline` is
/// `cursor.reconciled`, the bytes landing last wrote and the location C5-a reverts a losing
/// folder to, while `server` is `cursor.server`, the account value the round's diff publishes
/// over when the local value no longer matches it.
private final class MoveReplica {
    let id: Int
    /// The local rows, as the entities a projection would publish for them.
    var store: [String: Phi_PhiBookmarkEntity] = [:]
    var baseline: [String: Phi_PhiBookmarkEntity] = [:]
    var server: [String: Phi_PhiBookmarkEntity] = [:]
    var baseVersion: [String: Int64] = [:]
    var watermark: Int64 = 0
    var drained = false
    var offlineUntil = 0
    var clock = PhiHybridClock()

    init(id: Int) { self.id = id }

    var hasPendingWork: Bool { store.contains { server[$0.key] != $0.value } }
}

/// Ruling C5-a end to end: N replicas that each move a folder under the next one, closing a
/// cycle, and then land the whole page through `SyncableOwnedItems.plan`. What is under test is
/// the production cycle break driven by the same server, the same duplicate deliveries, dropped
/// pages and offline spells as the other Layer 2 scenarios -- not a hand-built page.
///
/// Every mover starts INSIDE a holder folder, never at the Space root, so "back to the location
/// the account last agreed on" is distinguishable from "lifted to the root".
///
/// The moves are made offline and published before anybody pulls, which is both the case the
/// ruling describes and the only one the planner can see: a device that receives a cycle one
/// entity per page has no arrival to pair its local row with, its dependency graph -- built from
/// the page alone -- holds no cycle, and it lands one locally until the revert some other device
/// published reaches it. See docs/sync.md.
func checkConcurrentCrossMovesResolveByLastOperation(rng: inout SplitMix64, report: Report) {
    for (cycleLength, localRowCycle) in [(2, false), (3, false), (2, true), (3, true)] {
        let label = "bookmarks.crossmove\(cycleLength)\(localRowCycle ? "local" : "")"
        var converged: [String: Phi_PhiBookmarkEntity] = [:]
        for _ in 0..<6 {
            converged = runCrossMoveTrial(cycleLength: cycleLength, localRowCycle: localRowCycle,
                                          rng: &rng, report: report)
        }
        // Single parent is structural -- one parent field per entity -- so what is left to check
        // is that the converged tree is acyclic and every node reaches a Space root. The
        // production planner answers both. Once per shape: the trials differ only in schedule.
        checkBookmarkTree(converged, report: report, label: label)
        report.markPassed("\(label).all-replicas-converge")
        report.markPassed("\(label).reaches-quiescence")
        report.markPassed("\(label).the-newest-moves-stand-and-the-oldest-goes-back")
        report.markPassed("\(label).breaks-at-least-one-cycle")
        if localRowCycle { report.markPassed("\(label).a-cycle-closed-by-a-local-row-is-seen") }
    }
}

/// Returns the converged bookmark set, for the tree invariants above. With `localRowCycle` the
/// first replica keeps its move UNPUBLISHED and pulls before committing, so it meets the other
/// moves against its own local row and the page it receives holds no cycle of its own.
private func runCrossMoveTrial(cycleLength: Int, localRowCycle: Bool, rng: inout SplitMix64,
                               report: Report) -> [String: Phi_PhiBookmarkEntity] {
    let label = "bookmarks.crossmove\(cycleLength)\(localRowCycle ? "local" : "")"
    let base: Int64 = 1_700_000_000_000
    let server = SimServer()

    func bytes(_ entity: Phi_PhiBookmarkEntity) -> Data {
        (try? BookmarkKind.envelope(entity).serializedData()) ?? Data()
    }
    func decode(_ payload: Data) -> Phi_PhiBookmarkEntity? {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: payload) else { return nil }
        return BookmarkKind.entity(from: envelope)
    }
    /// What the local ROW holds, with every stamp cleared. Two entities that agree here are the
    /// same row seen at two different moments of the account's logical time.
    func rowValues(_ entity: Phi_PhiBookmarkEntity) -> Phi_PhiBookmarkEntity {
        var out = entity
        out.spaceUuid.updatedAtMs = 0
        out.parentUuid.updatedAtMs = 0
        out.rank.updatedAtMs = 0
        out.title.updatedAtMs = 0
        out.url.updatedAtMs = 0
        out.secondaryURL.updatedAtMs = 0
        out.secondaryTitle.updatedAtMs = 0
        return out
    }
    func folder(_ uuid: String, parent: String, stamp: Int64) -> Phi_PhiBookmarkEntity {
        var out = Phi_PhiBookmarkEntity()
        out.bookmarkUuid = uuid
        out.spaceUuid = settingValue(simSpaceUuid, stamp)
        out.parentUuid = settingValue(parent, stamp)
        out.rank = settingValue("V", stamp)
        out.isFolder = true
        out.title = settingValue(uuid, stamp)
        out.url = settingValue("https://bookmark.phi/folder", stamp)
        out.secondaryURL = settingValue("", stamp)
        out.secondaryTitle = settingValue("", stamp)
        out.createdAtMs = 1_690_000_000_000
        return out
    }

    let holders = (1...cycleLength).map { "hold-000\($0)" }
    let movers = (1...cycleLength).map { "move-000\($0)" }
    // The account everybody agrees on before the moves.
    var account: [String: Phi_PhiBookmarkEntity] = [:]
    for (index, holder) in holders.enumerated() {
        account[holder] = folder(holder, parent: "", stamp: base)
        account[movers[index]] = folder(movers[index], parent: holder, stamp: base)
    }
    for (identity, entity) in account.sorted(by: { $0.key < $1.key }) {
        _ = server.commit(tag: identity, baseVersion: 0, payload: bytes(entity), deleted: false)
    }

    /// Cycles the production planner broke over this whole trial. A scenario that never made one
    /// would assert its outcome vacuously.
    var cyclesBroken = 0

    /// One landing pass through the production planner: the table is this replica's baselines,
    /// the context its local rows, and the result is written back exactly where the engine writes
    /// it -- `cursor.reconciled` and the row itself. This scenario deletes nothing, so no step
    /// ever names a parent other than the one in the bytes it carries.
    func land(_ replica: MoveReplica, arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>]) {
        guard !arrivals.isEmpty else { return }
        var table = PhiOwnedItemTable()
        for (identity, entity) in replica.baseline {
            var cursor = PhiOwnedItemCursor()
            cursor.reconciled = bytes(entity)
            cursor.server = replica.server[identity].map(bytes)
            table.cursors[identity] = cursor
        }
        var context = OwnedItemPlanContext()
        context.liveLocalParents = Set(replica.store.keys)
        // Build the projection domain the ENGINE builds, not every local row: handing the planner
        // the whole store made a cycle closed by an off-page local row look reachable here while
        // the engine could not see it at all. Both callers now share
        // `SyncableOwnedItems.projectionDomain`, so the two cannot drift apart again.
        let domain = SyncableOwnedItems.projectionDomain(
            BookmarkKind.self, arrivals: arrivals.map(\.entity), parked: [], tombstoned: [],
            localParent: { replica.store[$0]?.parentUuid.stringValue })
        for identity in domain {
            guard let entity = replica.store[identity], replica.baseline[identity] != nil else {
                continue
            }
            context.localProjections[identity] = bytes(entity)
        }
        let plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: arrivals, parked: [:],
                                           table: table, resolve: simResolver(), context: context)
        // The engine folds the module's own cycle stamp into logical time; so does this replica.
        replica.clock.observe(plan.cycleStampMs)
        cyclesBroken += plan.cyclesBroken
        for step in plan.steps {
            guard let payload = step.payload, let entity = decode(payload) else { continue }
            replica.store[step.identity] = entity
            replica.baseline[step.identity] = entity
        }
        for (identity, payload) in plan.rebaselined {
            guard let entity = decode(payload) else { continue }
            replica.baseline[identity] = entity
        }
        // A local row carries no stamps: the projection takes them from the baseline for every
        // merge unit the row did not change (`BookmarkKind.stamp`). Model that, or a row that
        // landed no step would keep the stamp it had before and publish it over the account's
        // newer one every round -- an artefact of storing rows as entities, not a merge result.
        for (identity, entity) in replica.store {
            guard let baseline = replica.baseline[identity], entity != baseline,
                  rowValues(entity) == rowValues(baseline) else { continue }
            replica.store[identity] = baseline
        }
    }

    func pull(_ replica: MoveReplica, duplicate: Bool) {
        let page = server.getUpdates(since: replica.watermark)
        for _ in 0..<(duplicate ? 2 : 1) {
            var arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>] = []
            for item in page {
                replica.baseVersion[item.tag] = item.row.version
                guard let payload = item.row.payload, let entity = decode(payload) else { continue }
                replica.server[item.tag] = entity
                for value in [entity.spaceUuid, entity.parentUuid, entity.rank, entity.title] {
                    replica.clock.observe(value.updatedAtMs)
                }
                arrivals.append(OwnedItemArrival(entity: entity, entityId: "srv-" + item.tag,
                                                 version: item.row.version))
            }
            land(replica, arrivals: arrivals)
        }
        replica.watermark = page.last?.row.version ?? replica.watermark
        replica.drained = true
    }

    func commit(_ replica: MoveReplica) {
        guard replica.drained else { return }
        for identity in replica.store.keys.sorted() {
            guard let entity = replica.store[identity],
                  replica.server[identity] != entity else { continue }
            switch server.commit(tag: identity, baseVersion: replica.baseVersion[identity] ?? 0,
                                 payload: bytes(entity), deleted: false) {
            case .applied(let version):
                replica.baseVersion[identity] = version
                replica.server[identity] = entity
            case .conflict:
                // Pull before commit: the one scoped retry needs another drained pull.
                replica.drained = false
                return
            }
        }
    }

    let replicas = (0..<cycleLength).map { MoveReplica(id: $0) }
    for replica in replicas { pull(replica, duplicate: false) }

    // Each replica moves its own folder under the next one while offline, at its own moment.
    // Distinct stamps, so this trial asserts the stamp rule; the UUID tie-break is pinned by the
    // injected-cycle control and by the unit tests.
    let offsets = Array(rng.shuffled(Array(1...(cycleLength * 4))).prefix(cycleLength))
    var moveStamp: [String: Int64] = [:]
    for (index, replica) in replicas.enumerated() {
        let mover = movers[index]
        guard var moved = replica.store[mover] else { continue }
        let stamp = replica.clock.stamp(wallMs: base + 60_000 + Int64(offsets[index]) * 1_000)
        // §4.3: location is one merge unit, so both members take the move's stamp.
        moved.parentUuid = settingValue(movers[(index + 1) % cycleLength], stamp)
        moved.spaceUuid = settingValue(simSpaceUuid, stamp)
        replica.store[mover] = moved
        moveStamp[mover] = stamp
    }
    // Publish them before anybody pulls. Each move is a different tag, so none of these commits
    // conflicts with another and none of them needs a pull in between. In the `localRowCycle`
    // variant replica 0 stays offline with its move unpublished and pulls first, so the cycle it
    // has to break is closed by its own local row rather than by two entities on the page.
    for replica in replicas where !(localRowCycle && replica.id == 0) { commit(replica) }
    if localRowCycle {
        // That first pull is the whole point of this variant: the page it delivers is acyclic on
        // its own, and only the local row's unpublished move closes the cycle.
        pull(replicas[0], duplicate: false)
        report.check("\(label).a-cycle-closed-by-a-local-row-is-seen", cyclesBroken > 0,
                     "replica 0 met the other moves against its own unpublished move and broke "
                     + "nothing: the planner is building its graph from the page alone again")
    }

    // The schedule: pulls (sometimes delivered twice), commits, dropped pages and offline spells.
    for step in 0..<(24 * cycleLength) {
        let replica = replicas[rng.below(replicas.count)]
        if replica.offlineUntil > step { continue }
        switch rng.below(6) {
        case 0, 1, 2:
            if rng.chance(8) { replica.drained = false; break }      // dropped response
            pull(replica, duplicate: rng.chance(3))
        case 3, 4:
            commit(replica)
        default:
            if rng.chance(2) { replica.offlineUntil = step + rng.int(2...8) }
        }
    }

    for replica in replicas { replica.offlineUntil = 0 }
    var rounds = 0
    var quiesced = false
    while rounds < 50 {
        rounds += 1
        let before = server.version
        for replica in replicas {
            pull(replica, duplicate: false)
            commit(replica)
            pull(replica, duplicate: false)
        }
        if server.version == before, !replicas.contains(where: { $0.hasPendingWork }) {
            quiesced = true
            break
        }
    }

    // Last operation wins: the oldest move is the only one put back, at the parent the account
    // last agreed on -- its holder, not the Space root.
    let loser = movers.min {
        let left = moveStamp[$0] ?? 0, right = moveStamp[$1] ?? 0
        return left == right ? $0 < $1 : left < right
    }
    let reference = replicas[0]
    for replica in replicas.dropFirst() {
        let same = reference.store.count == replica.store.count
            && reference.store.allSatisfy { strippingUnknown($1) == replica.store[$0].map(strippingUnknown) }
        report.check("\(label).all-replicas-converge", same,
                     "replica 0 = \(reference.store.sorted { $0.key < $1.key }.map(\.value.oneLine)) "
                     + "replica \(replica.id) = "
                     + "\(replica.store.sorted { $0.key < $1.key }.map(\.value.oneLine))")
    }
    report.check("\(label).reaches-quiescence", quiesced,
                 "still committing after \(rounds) idle rounds: the replicas keep reverting each "
                 + "other's moves")
    report.check("\(label).breaks-at-least-one-cycle", cyclesBroken > 0,
                 "no replica ever saw a cycle in this trial, so its outcome proves nothing")
    for replica in replicas {
        for (index, mover) in movers.enumerated() {
            let expected = mover == loser ? holders[index] : movers[(index + 1) % cycleLength]
            report.check("\(label).the-newest-moves-stand-and-the-oldest-goes-back",
                         replica.store[mover]?.parentUuid.stringValue == expected,
                         "replica \(replica.id) holds \(mover) under "
                         + "\(replica.store[mover]?.parentUuid.stringValue ?? "nothing"), expected "
                         + "\(expected); stamps \(moveStamp.sorted { $0.key < $1.key }), "
                         + "loser \(loser ?? "none")")
        }
    }
    return reference.store
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

// MARK: - Space edit intent (C2-a / design option S2)

/// The Space analogue of the bookmark move above, run through the production
/// `SyncableSpaces.snapshot`: replica A renames a Space at T1 while offline and recolours it at
/// T1b, replica B renames the same Space at T2 > T1 while online, and A only reconnects and
/// publishes at T3 > T2. B's rename is the later one by true wall clock, so B must win.
///
/// Before C2-a the Space projection was stamped inside the publish pass, which runs only after a
/// successful pull, so A's rename left carrying T3 and beat B every time. `SpaceModel` has no
/// edit-date column to read T1 back from -- and `theme_id`, the opacities and the Profile binding
/// are not even on the row -- so the edit time is carried in the cursor's `pendingProjection`
/// instead, written by the engine's gate-free stamping pass. Each call below is one run of that
/// pass over one Space; the last one is the publish pass, which re-projects and finds the same
/// bytes, so it keeps the stamps rather than issuing new ones.
func checkAnOfflineRenameLosesToALaterOnlineRename(report: Report) {
    let t0: Int64 = 1_700_000_000_000
    let t1 = t0 + 60_000            // A renames the Space, offline
    let t1b = t0 + 90_000           // A recolours it, still offline
    let t2 = t0 + 120_000           // B renames it, online
    let t3 = t0 + 3_600_000         // A reconnects and publishes

    let profileUuid = Pool.uuids[0]
    let created = Date(timeIntervalSince1970: 1_690_000_000)

    // The account value both replicas start from.
    var baseline = Phi_PhiSpaceEntity()
    baseline.spaceUuid = simSpaceUuid
    baseline.name = settingValue("Work", t0)
    baseline.iconName = settingValue("icon", t0)
    baseline.colorHex = settingValue("#101010", t0)
    baseline.rank = settingValue("V", t0)
    baseline.profileUuid = settingValue(profileUuid, t0)
    baseline.themeID = settingValue("", t0)
    baseline.overlayOpacityLight = settingValue(int: -1, t0)
    baseline.overlayOpacityDark = settingValue(int: -1, t0)
    baseline.createdAtMs = Int64(created.timeIntervalSince1970 * 1_000)

    func row(name: String, colorHex: String) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: "local-a", profileId: "p", name: name, colorHex: colorHex,
                      iconName: "icon", sortOrder: 0, createdDate: created,
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }
    func project(_ space: PhiLocalSpace, pending: Phi_PhiSpaceEntity?,
                 now: Int64) -> Phi_PhiSpaceEntity? {
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-a"
        cursor.version = 3
        cursor.reconciled = try? baseline.serializedData()
        cursor.pendingProjection = pending.flatMap { try? $0.serializedData() }
        table.cursors[simSpaceUuid] = cursor
        return SyncableSpaces.snapshot(spaces: [space], table: table,
                                       globalUuid: { $0 == "p" ? profileUuid : nil },
                                       syncUuid: { $0 == "local-a" ? simSpaceUuid : nil },
                                       now: now)[simSpaceUuid]
    }

    guard let renamed = project(row(name: "Travel", colorHex: "#101010"), pending: nil, now: t1),
          let recoloured = project(row(name: "Travel", colorHex: "#FF00FF"),
                                   pending: renamed, now: t1b),
          let published = project(row(name: "Travel", colorHex: "#FF00FF"),
                                  pending: recoloured, now: t3),
          let reverted = project(row(name: "Work", colorHex: "#101010"),
                                 pending: recoloured, now: t3) else {
        report.check("spaces.an-offline-rename-loses-to-a-later-online-rename", false,
                     "projection failed: the Space is no longer eligible for snapshot")
        return
    }

    // B's rename, made online at t2.
    var fromB = baseline
    fromB.name = settingValue("Studio", t2)
    let merged = SyncableSpaces.merge(local: published, remote: fromB)

    report.check("spaces.an-offline-rename-carries-its-rename-time",
                 published.name.updatedAtMs == t1,
                 "published name stamp \(published.name.updatedAtMs), expected the rename time "
                 + "\(t1) and not the publish time \(t3)")
    report.check("spaces.a-second-offline-edit-leaves-the-first-field-alone",
                 published.name.updatedAtMs == t1 && published.colorHex.updatedAtMs == t1b,
                 "name@\(published.name.updatedAtMs) colour@\(published.colorHex.updatedAtMs), "
                 + "expected \(t1) and \(t1b): each field keeps its own edit time")
    report.check("spaces.an-offline-rename-loses-to-a-later-online-rename",
                 merged.name.stringValue == "Studio",
                 "converged name \(merged.name.stringValue) at stamp \(merged.name.updatedAtMs); "
                 + "the later true-time rename was B's")
    // A field put back to the account's own value before publishing leaves nothing to publish:
    // the projection merges into the baseline unchanged, which is the commit batch's own test.
    report.check("spaces.a-reverted-edit-publishes-nothing",
                 SyncableSpaces.merge(local: reverted, remote: baseline) == baseline,
                 "the reverted projection still differs from the baseline: \(reverted.oneLine)")
    // An untouched Space keeps the account's rank stamp; the stamping pass never manufactures a
    // drag out of a projection that did not move (§7's kept set).
    report.check("spaces.an-untouched-rank-is-not-restamped",
                 published.rank.updatedAtMs == t0 && published.rank.stringValue == "V",
                 "rank \(published.rank.stringValue)@\(published.rank.updatedAtMs), expected the "
                 + "baseline's V@\(t0)")
    report.markPassed("spaces.an-offline-rename-carries-its-rename-time")
    report.markPassed("spaces.a-second-offline-edit-leaves-the-first-field-alone")
    report.markPassed("spaces.an-offline-rename-loses-to-a-later-online-rename")
    report.markPassed("spaces.a-reverted-edit-publishes-nothing")
    report.markPassed("spaces.an-untouched-rank-is-not-restamped")
}

// MARK: - C4 tree case: a folder deleted while one of its children was edited

/// T1, through the production planner. Another device deleted folder F and its child C, publishing
/// the tombstones subtree-first; this device holds an unpublished rename of C. The three things
/// that must hold are checked in one place because they are one outcome:
///
/// 1. C yields and no delete step is produced for it, while F is deleted -- the chain is lifted,
///    never resurrected;
/// 2. an arrival that still names the dead folder as its parent is LIFTED to the Space root rather
///    than parked, which is what puts C at the top level on every device;
/// 3. the resulting single-node tree satisfies the same reachability invariants the converged sets
///    are held to.
func checkAnEditedChildSurvivesItsFoldersDeletion(report: Report) {
    func bookmark(_ uuid: String, parent: String, title: String, stamp: Int64,
                  isFolder: Bool) -> Phi_PhiBookmarkEntity {
        var out = Phi_PhiBookmarkEntity()
        out.bookmarkUuid = uuid
        out.spaceUuid = settingValue(simSpaceUuid, stamp)
        out.parentUuid = settingValue(parent, stamp)
        out.rank = settingValue("V", stamp)
        out.isFolder = isFolder
        out.title = settingValue(title, stamp)
        out.url = settingValue(isFolder ? "https://bookmark.phi/folder" : "https://a.example/",
                               stamp)
        out.secondaryURL = settingValue("", stamp)
        out.secondaryTitle = settingValue("", stamp)
        return out
    }
    func bytes(_ entity: Phi_PhiBookmarkEntity) -> Data {
        (try? BookmarkKind.envelope(entity).serializedData()) ?? Data()
    }

    let folder = bookmark("tree-folder", parent: "", title: "F", stamp: 1_000, isFolder: true)
    let childBaseline = bookmark("tree-child", parent: "tree-folder", title: "C", stamp: 1_000,
                                 isFolder: false)
    var edited = childBaseline
    edited.title = settingValue("renamed", 2_000)

    var table = PhiOwnedItemTable()
    var folderCursor = PhiOwnedItemCursor()
    folderCursor.reconciled = bytes(folder)
    folderCursor.entityId = "srv-f"
    folderCursor.version = 4
    var childCursor = PhiOwnedItemCursor()
    childCursor.reconciled = bytes(childBaseline)
    childCursor.entityId = "srv-c"
    childCursor.version = 5
    table.cursors["tree-folder"] = folderCursor
    table.cursors["tree-child"] = childCursor

    var context = OwnedItemPlanContext()
    context.tombstonedIdentities = ["tree-folder", "tree-child"]
    context.localProjections = ["tree-child": bytes(edited)]
    context.pendingLocalEdits = SyncableOwnedItems.unpublishedEdits(
        BookmarkKind.self, projections: context.localProjections, table: table)

    let landing = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: [], parked: [:],
                                          table: table, resolve: simResolver(), context: context)
    let deletes = landing.steps.filter { $0.kind == .delete }.map(\.identity)
    report.check("bookmarks.tree.an-edited-child-yields-while-its-folder-dies",
                 landing.yieldedTombstones == ["tree-child"] && deletes == ["tree-folder"],
                 "yielded=\(landing.yieldedTombstones.sorted()) deleted=\(deletes) "
                 + "predicate=\(context.pendingLocalEdits.sorted())")

    // The child's republish reaches a peer that still holds the dead folder as its parent.
    var afterFolderDied = table
    afterFolderDied.cursors["tree-folder"]?.deletedAtMs = 9_000
    afterFolderDied.cursors["tree-folder"]?.reconciled = nil
    let lift = SyncableOwnedItems.plan(
        BookmarkKind.self,
        arrivals: [OwnedItemArrival(entity: edited, entityId: "srv-c", version: 11)],
        parked: [:], table: afterFolderDied, resolve: simResolver(),
        context: OwnedItemPlanContext())
    report.check("bookmarks.tree.a-child-of-a-dead-folder-lifts-to-the-space-root",
                 lift.lifted == 1 && lift.steps.first?.newParentUuid == ""
                     && lift.parked.isEmpty,
                 "lifted=\(lift.lifted) parent=\(lift.steps.first?.newParentUuid ?? "nil") "
                 + "parked=\(lift.parked.keys.sorted())")

    var lifted = edited
    lifted.parentUuid = settingValue("", 9_001)
    lifted.spaceUuid = settingValue(simSpaceUuid, 9_001)
    checkBookmarkTree(["tree-child": lifted], report: report, label: "bookmarks.tree.after-lift")

    report.markPassed("bookmarks.tree.an-edited-child-yields-while-its-folder-dies")
    report.markPassed("bookmarks.tree.a-child-of-a-dead-folder-lifts-to-the-space-root")
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Layer 1: the algebraic laws every one of the five merges has to satisfy for
// an unordered, replayed, duplicated update stream to converge.
//
//   idempotence    merge(a, a) == a
//   commutativity  merge(a, b) ~ merge(b, a)
//   associativity  every one of the 6 orders of three replicas agrees
//
// `~` is equality after clearing the ENTITY'S OWN `unknownFields`, and nothing
// else. That exclusion is required, not a convenience: SyncableSpaces,
// BookmarkKind, PinKind and URLRuleKind all start the merged message from
// `remote` so a newer client's reserved fields survive (Proto/README.md,
// "Reserved-field preservation is a contract"). `merge(a, b)` therefore always
// carries b's unknown bytes and `merge(b, a)` always carries a's, by design.
// Preservation itself is asserted separately, as its own property, so dropping
// it from the comparison cannot hide a regression.
//
// Two further documented asymmetries are respected by GENERATING them away
// rather than by excluding fields, because the production code refuses or
// rejects the disagreement rather than merging it:
//   - `BookmarkKind.merge` takes `is_folder` from remote: a row cannot change
//     between bookmark and folder, and `refuses` rejects `isFolderMismatch`.
//   - `PinKind.merge` leaves the owner oneof at remote's: the owner is half the
//     pin's identity, so two entities with one identity always share it.
// Same-identity trios therefore always share `is_folder` and the owner.

func strippingUnknown<E: SwiftProtobuf.Message>(_ entity: E) -> E {
    var copy = entity
    copy.unknownFields = SwiftProtobuf.UnknownStorage()
    return copy
}

/// Every order of three replicas: the 6 left folds plus the 6 right folds, so a
/// break in associativity alone is caught as well as a break in commutativity.
private func allOrders<E>(_ items: [E], _ merge: (E, E) -> E) -> [(String, E)] {
    let labels = ["a", "b", "c"]
    var out: [(String, E)] = []
    for i in 0..<3 {
        for j in 0..<3 where j != i {
            let k = 3 - i - j
            let (x, y, z) = (items[i], items[j], items[k])
            out.append(("merge(merge(\(labels[i]),\(labels[j])),\(labels[k]))", merge(merge(x, y), z)))
            out.append(("merge(\(labels[i]),merge(\(labels[j]),\(labels[k])))", merge(x, merge(y, z))))
        }
    }
    return out
}

struct AlgebraSuite<E: SwiftProtobuf.Message & Equatable> {
    var name: String
    var merge: (E, E) -> E
    /// Three replicas of one identity, coherent in every field the merge treats
    /// as an invariant rather than as data.
    var trio: (inout Generators) -> (E, E, E)
    /// Field numbers phi_entity.proto declares always-emitted; see `shrink`.
    var alwaysEmitted: Set<Int> = []

    func run(iterations: Int, generators: inout Generators, report: Report) {
        for mode in [TieMode.mixed, TieMode.allStampsEqual] {
            let suffix = mode == .mixed ? "" : " [equal stamps]"
            for iteration in 0..<iterations {
                generators.beginTrio(mode: mode)
                let (a, b, c) = trio(&generators)

                // --- idempotence -------------------------------------------------
                let idempotent: ([E]) -> Bool = { items in merge(items[0], items[0]) != items[0] }
                if idempotent([a]) {
                    let minimal = shrink([a], keeping: alwaysEmitted, fails: idempotent)
                    report.check("\(name).idempotence\(suffix)", false, """
                        iteration=\(iteration)  [minimal]
                          a          = \(minimal[0].oneLine)
                          merge(a,a) = \(merge(minimal[0], minimal[0]).oneLine)
                        original a   = \(a.oneLine)
                        """)
                } else {
                    report.check("\(name).idempotence\(suffix)", true, "")
                }

                // A merge that is not idempotent may still be a NORMALISER: it
                // rewrites the payload once and then holds still. That distinction
                // is the difference between "one extra commit" and "republishes
                // forever", so it gets its own property here as well as over the
                // malformed domain in NormalisationProperties.swift.
                let notAFixedPoint: ([E]) -> Bool = { items in
                    let once = merge(items[0], items[0])
                    return merge(once, once) != once
                }
                if notAFixedPoint([a]) {
                    let minimal = shrink([a], keeping: alwaysEmitted, fails: notAFixedPoint)
                    let once = merge(minimal[0], minimal[0])
                    report.check("\(name).merge-settles-after-one-pass\(suffix)", false, """
                        iteration=\(iteration)  [minimal]
                          a               = \(minimal[0].oneLine)
                          merge(a,a)      = \(once.oneLine)
                          merge(m,m)      = \(merge(once, once).oneLine)
                        """)
                } else {
                    report.check("\(name).merge-settles-after-one-pass\(suffix)", true, "")
                }

                // --- commutativity -----------------------------------------------
                let notCommutative: ([E]) -> Bool = { items in
                    strippingUnknown(merge(items[0], items[1]))
                        != strippingUnknown(merge(items[1], items[0]))
                }
                if notCommutative([a, b]) {
                    let minimal = shrink([a, b], keeping: alwaysEmitted, fails: notCommutative)
                    report.check("\(name).commutativity\(suffix)", false, """
                        iteration=\(iteration)  [minimal]
                          a           = \(minimal[0].oneLine)
                          b           = \(minimal[1].oneLine)
                          merge(a,b)  = \(merge(minimal[0], minimal[1]).oneLine)
                          merge(b,a)  = \(merge(minimal[1], minimal[0]).oneLine)
                        """)
                } else {
                    report.check("\(name).commutativity\(suffix)", true, "")
                }

                // --- associativity / all 6 orders --------------------------------
                let notAssociative: ([E]) -> Bool = { items in
                    let results = allOrders(items, merge).map { strippingUnknown($0.1) }
                    return results.dropFirst().contains { $0 != results[0] }
                }
                if notAssociative([a, b, c]) {
                    let minimal = shrink([a, b, c], keeping: alwaysEmitted, fails: notAssociative)
                    let orders = allOrders(minimal, merge)
                    let reference = strippingUnknown(orders[0].1)
                    let disagreeing = orders.first { strippingUnknown($0.1) != reference }
                    report.check("\(name).associativity\(suffix)", false, """
                        iteration=\(iteration)  [minimal]
                          a = \(minimal[0].oneLine)
                          b = \(minimal[1].oneLine)
                          c = \(minimal[2].oneLine)
                          \(orders[0].0) = \(orders[0].1.oneLine)
                          \(disagreeing?.0 ?? "?") = \(disagreeing?.1.oneLine ?? "?")
                        """)
                } else {
                    report.check("\(name).associativity\(suffix)", true, "")
                }
            }
        }
        for law in ["idempotence", "commutativity", "associativity",
                    "merge-settles-after-one-pass"] {
            report.markPassed("\(name).\(law)")
            report.markPassed("\(name).\(law) [equal stamps]")
        }
    }
}

/// The reserved-range contract: a merge must hand back the authoritative
/// side's unknown bytes untouched (Proto/README.md).
func checkUnknownFieldPreservation<E: SwiftProtobuf.Message & Equatable>(
    name: String, merge: (E, E) -> E, trio: (inout Generators) -> (E, E, E),
    iterations: Int, generators: inout Generators, report: Report) {
    let property = "\(name).unknown-fields-preserved-from-remote"
    for _ in 0..<iterations {
        generators.beginTrio(mode: .mixed)
        let (a, b, _) = trio(&generators)
        let merged = merge(a, b)
        report.check(property, merged.unknownFields == b.unknownFields, """
              local  = \(a.oneLine)
              remote = \(b.oneLine)  unknownFields=\(b.unknownFields)
              merged unknownFields=\(merged.unknownFields)
            """)
    }
    report.markPassed(property)
}

// MARK: - Per-kind suites

/// phi_entity.proto: "every MUTABLE field is a PhiSettingValue ... always
/// emitted, never omitted-when-empty". These are those field numbers. The
/// generators always populate them and the shrinker never removes them.
enum AlwaysEmitted {
    static let space: Set<Int> = [2, 3, 4, 5, 8, 9]          // not 6/7: optional by `has`
    static let bookmark: Set<Int> = [2, 3, 4, 6, 7, 8, 9]
    static let pin: Set<Int> = [4, 5, 6, 7]                  // 2/3 are the owner oneof
    static let rule: Set<Int> = [2, 3, 4, 5, 6]
}

// The two malformed shapes that used to be REPORTED here -- a merge unit whose
// members carry different stamps, and an absent always-emitted field -- are now
// asserted properties of their own in NormalisationProperties.swift. The
// generators below produce well-formed payloads, which is the domain the
// algebraic laws are statements about; the adversarial generators live on,
// behind `malformed:`, and feed the normalisation properties.

func runLayer1(iterations: Int, generators: inout Generators, report: Report) {
    // Settings -----------------------------------------------------------------
    // The registry keys plus one key this build does not know: the settings
    // entity's forward compatibility is unknown MAP KEYS, not reserved fields.
    let settingsKeys = ["PhiUserAppearanceChoice", "PhiCurrentThemeId", "layoutMode",
                        "alwaysShowURLPath", "settings.from.a.newer.client"]
    let settingsTrio: (inout Generators) -> (Phi_PhiSettingEntity, Phi_PhiSettingEntity,
                                             Phi_PhiSettingEntity) = { gen in
        (gen.settingsEntity(keys: settingsKeys),
         gen.settingsEntity(keys: settingsKeys),
         gen.settingsEntity(keys: settingsKeys))
    }
    AlgebraSuite(name: "settings", merge: { SyncableSettings.merge(local: $0, remote: $1) },
                 trio: settingsTrio)
        .run(iterations: iterations, generators: &generators, report: report)

    // Forward compatibility for settings is the key union, so assert that
    // directly instead of the reserved-field rule.
    for _ in 0..<iterations {
        generators.beginTrio(mode: .mixed)
        let (a, b, _) = settingsTrio(&generators)
        let merged = SyncableSettings.merge(local: a, remote: b)
        let union = Set(a.values.keys).union(b.values.keys)
        report.check("settings.unknown-registry-keys-survive",
                     Set(merged.values.keys) == union,
                     """
                       local keys  = \(a.values.keys.sorted())
                       remote keys = \(b.values.keys.sorted())
                       merged keys = \(merged.values.keys.sorted())
                     """)
    }
    report.markPassed("settings.unknown-registry-keys-survive")

    // Observation, not an assertion: `SyncableSettings.merge` starts from
    // `local`, the only one of the five that does not start from `remote`.
    // `PhiSettingEntity` declares no reserved range today, so nothing is lost
    // yet; the note records the divergence from the documented rule.
    do {
        var probe = Phi_PhiSettingEntity()
        probe.values["k"] = settingValue("v", 1)
        let remote = addingUnknownField(probe, number: 9, value: 42)
        let merged = SyncableSettings.merge(local: probe, remote: remote)
        if merged.unknownFields != remote.unknownFields {
            report.note("""
                settings: SyncableSettings.merge starts from `local`, so an unknown FIELD on the \
                remote PhiSettingEntity is dropped (field 9 varint 42 -> merged.unknownFields empty). \
                The other four merges start from `remote` per Proto/README.md. Harmless today \
                (PhiSettingEntity has no reserved range; its forward compatibility is unknown map \
                keys, which do survive), but it is the one merge that would not honour a reserved \
                field if one were ever added.
                """)
        }
    }

    // Spaces -------------------------------------------------------------------
    let spacesTrio: (inout Generators) -> (Phi_PhiSpaceEntity, Phi_PhiSpaceEntity,
                                           Phi_PhiSpaceEntity) = { gen in
        let uuid = gen.rng.pick(Pool.spaceUuids)
        return (gen.spaceEntity(uuid: uuid), gen.spaceEntity(uuid: uuid),
                gen.spaceEntity(uuid: uuid))
    }
    AlgebraSuite(name: "spaces", merge: { SyncableSpaces.merge(local: $0, remote: $1) },
                 trio: spacesTrio, alwaysEmitted: AlwaysEmitted.space)
        .run(iterations: iterations, generators: &generators, report: report)
    checkUnknownFieldPreservation(name: "spaces",
                                  merge: { SyncableSpaces.merge(local: $0, remote: $1) },
                                  trio: spacesTrio, iterations: iterations,
                                  generators: &generators, report: report)

    // Bookmarks ----------------------------------------------------------------
    let bookmarksTrio: (inout Generators) -> (Phi_PhiBookmarkEntity, Phi_PhiBookmarkEntity,
                                              Phi_PhiBookmarkEntity) = { gen in
        let uuid = gen.rng.pick(Pool.uuids)
        let isFolder = gen.rng.bool()
        return (gen.bookmarkEntity(uuid: uuid, isFolder: isFolder),
                gen.bookmarkEntity(uuid: uuid, isFolder: isFolder),
                gen.bookmarkEntity(uuid: uuid, isFolder: isFolder))
    }
    AlgebraSuite(name: "bookmarks", merge: { BookmarkKind.merge(local: $0, remote: $1) },
                 trio: bookmarksTrio, alwaysEmitted: AlwaysEmitted.bookmark)
        .run(iterations: iterations, generators: &generators, report: report)
    checkUnknownFieldPreservation(name: "bookmarks",
                                  merge: { BookmarkKind.merge(local: $0, remote: $1) },
                                  trio: bookmarksTrio, iterations: iterations,
                                  generators: &generators, report: report)

    // Pins ---------------------------------------------------------------------
    let pinsTrio: (inout Generators) -> (Phi_PhiPinTabEntity, Phi_PhiPinTabEntity,
                                         Phi_PhiPinTabEntity) = { gen in
        let lineage = gen.rng.pick(Pool.uuids).lowercased()
        let owner: Phi_PhiPinTabEntity.OneOf_Owner?
        switch gen.rng.below(3) {
        case 0: owner = .spaceUuid(gen.rng.pick(Pool.spaceUuids))
        case 1: owner = .profileUuid(gen.rng.pick(Pool.uuids))
        default: owner = nil            // App scope: absence is a value (§2.4)
        }
        return (gen.pinEntity(lineage: lineage, owner: owner),
                gen.pinEntity(lineage: lineage, owner: owner),
                gen.pinEntity(lineage: lineage, owner: owner))
    }
    AlgebraSuite(name: "pins", merge: { PinKind.merge(local: $0, remote: $1) }, trio: pinsTrio,
                 alwaysEmitted: AlwaysEmitted.pin)
        .run(iterations: iterations, generators: &generators, report: report)
    checkUnknownFieldPreservation(name: "pins",
                                  merge: { PinKind.merge(local: $0, remote: $1) },
                                  trio: pinsTrio, iterations: iterations,
                                  generators: &generators, report: report)

    // URL rules ----------------------------------------------------------------
    let rulesTrio: (inout Generators) -> (Phi_PhiURLRuleEntity, Phi_PhiURLRuleEntity,
                                          Phi_PhiURLRuleEntity) = { gen in
        let uuid = gen.rng.pick(Pool.uuids)
        return (gen.ruleEntity(uuid: uuid), gen.ruleEntity(uuid: uuid), gen.ruleEntity(uuid: uuid))
    }
    AlgebraSuite(name: "urlrules", merge: { URLRuleKind.merge(local: $0, remote: $1) },
                 trio: rulesTrio, alwaysEmitted: AlwaysEmitted.rule)
        .run(iterations: iterations, generators: &generators, report: report)
    checkUnknownFieldPreservation(name: "urlrules",
                                  merge: { URLRuleKind.merge(local: $0, remote: $1) },
                                  trio: rulesTrio, iterations: iterations,
                                  generators: &generators, report: report)

    // The shared LWW winner ----------------------------------------------------
    // Every kind above routes its field decisions through this one function
    // (R4, single implementation), so its own laws are worth pinning directly.
    for _ in 0..<iterations * 4 {
        generators.beginTrio(mode: generators.rng.bool() ? .mixed : .allStampsEqual)
        let x = generators.maybeWrongCase(generators.text())
        let y = generators.maybeWrongCase(generators.text())
        let z = generators.maybeWrongCase(generators.text())
        report.check("lwwWinner.idempotence",
                     SyncableSettings.lwwWinner(x, x) == x,
                     "x=\(x.oneLine)")
        report.check("lwwWinner.commutativity",
                     SyncableSettings.lwwWinner(x, y) == SyncableSettings.lwwWinner(y, x),
                     "x=\(x.oneLine) y=\(y.oneLine)")
        let left = SyncableSettings.lwwWinner(SyncableSettings.lwwWinner(x, y), z)
        let right = SyncableSettings.lwwWinner(x, SyncableSettings.lwwWinner(y, z))
        report.check("lwwWinner.associativity", left == right,
                     "x=\(x.oneLine) y=\(y.oneLine) z=\(z.oneLine) left=\(left.oneLine) right=\(right.oneLine)")
    }
    for law in ["idempotence", "commutativity", "associativity"] {
        report.markPassed("lwwWinner.\(law)")
    }

    // created_at_ms -------------------------------------------------------------
    // The one non-LWW scalar all four entity kinds share: "merged with min()",
    // implemented as `[left, right].filter { $0 > 0 }.min() ?? 0`. It decides
    // the final ordering tie-break, so losing it silently reorders an account.
    // Isolated from the idempotence law so the cause is named, not inferred.
    //
    // The LEGAL domain only: 0 is the wire encoding of "unset" and a real
    // instant is positive. What the merge does to a non-positive value is the
    // sanitisation contract, asserted in NormalisationProperties.swift.
    func checkCreatedAt<E: SwiftProtobuf.Message & Equatable>(
        _ name: String, _ merge: (E, E) -> E, _ set: (Int64) -> E, _ get: (E) -> Int64) {
        for value in Pool.createdAt {
            let entity = set(value)
            report.check("\(name).created_at_ms-survives-a-merge-with-itself",
                         get(merge(entity, entity)) == value,
                         "created_at_ms=\(value) -> \(get(merge(entity, entity)))")
        }
        report.markPassed("\(name).created_at_ms-survives-a-merge-with-itself")
    }
    checkCreatedAt("spaces", { SyncableSpaces.merge(local: $0, remote: $1) },
                   { value in var e = Phi_PhiSpaceEntity(); e.createdAtMs = value; return e },
                   { $0.createdAtMs })
    checkCreatedAt("bookmarks", { BookmarkKind.merge(local: $0, remote: $1) },
                   { value in var e = Phi_PhiBookmarkEntity(); e.createdAtMs = value; return e },
                   { $0.createdAtMs })
    checkCreatedAt("pins", { PinKind.merge(local: $0, remote: $1) },
                   { value in var e = Phi_PhiPinTabEntity(); e.createdAtMs = value; return e },
                   { $0.createdAtMs })
    checkCreatedAt("urlrules", { URLRuleKind.merge(local: $0, remote: $1) },
                   { value in var e = Phi_PhiURLRuleEntity(); e.createdAtMs = value; return e },
                   { $0.createdAtMs })
}

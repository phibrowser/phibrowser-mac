// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Layer 1, second half: what the merges do to a payload the SCHEMA FORBIDS.
//
// The algebraic laws in AlgebraProperties.swift run over WELL-FORMED payloads,
// because `merge(a, a) == a` is a statement about a value a publisher can
// actually emit. Three shapes are outside that domain, and each is reachable
// only from a truncated, hand-written or foreign payload:
//
//   * `created_at_ms <= 0`. phi_entity.proto declares it a proto3 `int64`
//     "merged with min()", so 0 is indistinguishable from an absent field and
//     IS the encoding of "unset"; a non-positive instant is not a creation time.
//   * a merge unit whose members carry DIFFERENT stamps -- §4.3's bookmark
//     location pair, §8.2 rule 1's host/path_prefix/ask content group. One
//     designated carrier per unit is the contract, and every publisher writes
//     one stamp to every member of the unit.
//   * an always-emitted `PhiSettingValue` field that is ABSENT
//     (phi_entity.proto: "always emitted, never omitted-when-empty").
//
// Narrowing the algebra suites and saying nothing else would be weakening the
// gate, so each shape is pinned here instead, by the four laws a NORMALISER
// owes: it is deterministic, it is side-independent, it settles after one pass,
// and it never changes a VALUE. These are asserted, not reported.

// MARK: - Value digests

// Every VALUE an entity carries, with the stamps deliberately left out. A
// normalisation may rewrite a timestamp or materialise an empty submessage; it
// may never change one of these.

func valueDigest(_ e: Phi_PhiSpaceEntity) -> String {
    [e.spaceUuid, e.name.stringValue, e.iconName.stringValue, e.colorHex.stringValue,
     e.rank.stringValue, e.profileUuid.stringValue, e.themeID.stringValue,
     String(e.overlayOpacityLight.intValue), String(e.overlayOpacityDark.intValue),
     String(e.createdAtMs)].joined(separator: "|")
}

func valueDigest(_ e: Phi_PhiBookmarkEntity) -> String {
    [e.bookmarkUuid, e.spaceUuid.stringValue, e.parentUuid.stringValue, e.rank.stringValue,
     String(e.isFolder), e.title.stringValue, e.url.stringValue, e.secondaryURL.stringValue,
     e.secondaryTitle.stringValue, String(e.source), String(e.createdAtMs)]
        .joined(separator: "|")
}

func valueDigest(_ e: Phi_PhiPinTabEntity) -> String {
    [e.pinUuid, String(describing: e.owner), e.rank.stringValue, e.title.stringValue,
     e.url.stringValue, e.splitPartnerUuid.stringValue, String(e.source),
     String(e.createdAtMs)].joined(separator: "|")
}

func valueDigest(_ e: Phi_PhiURLRuleEntity) -> String {
    [e.ruleUuid, e.host.stringValue, e.pathPrefix.stringValue, String(e.ask.boolValue),
     e.targetSpaceUuid.stringValue, e.rank.stringValue, String(e.source),
     String(e.createdAtMs)].joined(separator: "|")
}

// MARK: - Wire helpers

/// Re-parse through the wire, so a normalisation that depends on anything other
/// than the payload itself shows up as non-determinism.
private func roundTripped<E: SwiftProtobuf.Message>(_ entity: E) -> E {
    guard let data = try? entity.serializedData(),
          let out = try? E(serializedBytes: data) else { return entity }
    return out
}

/// `entity` with top-level field `number` removed, exactly as a truncated
/// payload arrives. Wire-level, so it stays kind-agnostic like `shrink`.
/// Nil when the field was not present to begin with.
func withoutField<E: SwiftProtobuf.Message>(_ entity: E, number: Int) -> E? {
    guard let data = try? entity.serializedData(), let fields = WireSplit.split(data),
          fields.contains(where: { $0.number == number }) else { return nil }
    return try? E(serializedBytes: WireSplit.joined(fields.filter { $0.number != number }))
}

// MARK: - The four normalisation laws

private let normalisationLaws = ["settles-after-one-pass", "is-deterministic",
                                 "is-side-independent", "never-changes-a-value"]

/// `peer` is a WELL-FORMED entity of the same identity: side-independence is
/// only meaningful against something a real device would send.
private func checkNormalises<E: SwiftProtobuf.Message & Equatable>(
    _ property: String, malformed a: E, peer b: E, merge: (E, E) -> E,
    digest: (E) -> String, report: Report) {
    let once = merge(a, a)
    report.check("\(property).settles-after-one-pass", merge(once, once) == once, """
          malformed  = \(a.oneLine)
          merge(a,a) = \(once.oneLine)
          merge(m,m) = \(merge(once, once).oneLine)
        """)
    let reparsed = roundTripped(a)
    report.check("\(property).is-deterministic", merge(reparsed, reparsed) == once, """
          malformed      = \(a.oneLine)
          merge(a,a)     = \(once.oneLine)
          after a wire round trip = \(merge(reparsed, reparsed).oneLine)
        """)
    report.check("\(property).is-side-independent",
                 strippingUnknown(merge(a, b)) == strippingUnknown(merge(b, a)), """
          malformed  = \(a.oneLine)
          peer       = \(b.oneLine)
          merge(a,b) = \(merge(a, b).oneLine)
          merge(b,a) = \(merge(b, a).oneLine)
        """)
    report.check("\(property).never-changes-a-value", digest(once) == digest(a), """
          malformed = \(a.oneLine)
          values before = \(digest(a))
          values after  = \(digest(once))
        """)
}

private func markNormalisationPassed(_ property: String, report: Report) {
    for law in normalisationLaws { report.markPassed("\(property).\(law)") }
}

// MARK: - created_at_ms (the sanitised domain)

/// `[left, right].filter { $0 > 0 }.min() ?? 0`, the same helper in all four
/// kinds. It is shared with the outbound projection on purpose (R4 / R-exec-16):
/// a merge and a projection that folded this field differently would alternate
/// X/Y forever and republish from both devices every round. So the rule pinned
/// here is a rule about the WIRE, not only about `merge`.
private func checkCreatedAtSanitisation(report: Report) {
    func probe<E: SwiftProtobuf.Message & Equatable>(
        _ name: String, _ merge: (E, E) -> E, _ set: (Int64) -> E, _ get: (E) -> Int64) {
        let sanitises = "\(name).non-positive-created_at_ms-sanitises-to-unset"
        let symmetric = "\(name).created_at_ms-merge-is-side-independent"
        let earliest = "\(name).created_at_ms-keeps-the-earliest-real-instant"
        for value in Pool.illegalCreatedAt {
            let entity = set(value)
            let merged = get(merge(entity, entity))
            report.check(sanitises, merged == 0,
                         "created_at_ms=\(value) merged with itself -> \(merged), expected 0 "
                         + "(the wire encoding of \"unset\")")
        }
        for left in Pool.illegalCreatedAt + Pool.createdAt {
            for right in Pool.illegalCreatedAt + Pool.createdAt {
                let forward = get(merge(set(left), set(right)))
                let backward = get(merge(set(right), set(left)))
                report.check(symmetric, forward == backward,
                             "created_at_ms \(left) vs \(right) -> \(forward) one way, "
                             + "\(backward) the other")
                let real = [left, right].filter { $0 > 0 }.min() ?? 0
                report.check(earliest, forward == real,
                             "created_at_ms \(left) vs \(right) -> \(forward), expected \(real): "
                             + "a sanitised value must neither win nor drag a real instant down")
            }
        }
        for property in [sanitises, symmetric, earliest] { report.markPassed(property) }
    }
    probe("spaces", { SyncableSpaces.merge(local: $0, remote: $1) },
          { value in var e = Phi_PhiSpaceEntity(); e.createdAtMs = value; return e },
          { $0.createdAtMs })
    probe("bookmarks", { BookmarkKind.merge(local: $0, remote: $1) },
          { value in var e = Phi_PhiBookmarkEntity(); e.createdAtMs = value; return e },
          { $0.createdAtMs })
    probe("pins", { PinKind.merge(local: $0, remote: $1) },
          { value in var e = Phi_PhiPinTabEntity(); e.createdAtMs = value; return e },
          { $0.createdAtMs })
    probe("urlrules", { URLRuleKind.merge(local: $0, remote: $1) },
          { value in var e = Phi_PhiURLRuleEntity(); e.createdAtMs = value; return e },
          { $0.createdAtMs })
}

// MARK: - Merge units whose members disagree about the stamp

/// §4.3 (bookmark location) and §8.2 rule 1 (rule content group) each designate
/// ONE carrier. A peer that stamped the members differently is rewritten onto
/// that carrier -- never onto `max`, which two clients could read differently
/// and republish over each other forever.
private func checkMergeUnitStampNormalisation(iterations: Int, generators: inout Generators,
                                              report: Report) {
    var incoherentBookmarks = 0
    var incoherentRules = 0
    for _ in 0..<iterations {
        generators.beginTrio(mode: generators.rng.bool() ? .mixed : .allStampsEqual)

        let bookmarkUuid = generators.rng.pick(Pool.uuids)
        let isFolder = generators.rng.bool()
        let bookmark = generators.bookmarkEntity(uuid: bookmarkUuid, isFolder: isFolder,
                                                 malformed: true)
        let bookmarkPeer = generators.bookmarkEntity(uuid: bookmarkUuid, isFolder: isFolder)
        if bookmark.spaceUuid.updatedAtMs != bookmark.parentUuid.updatedAtMs {
            incoherentBookmarks += 1
        }
        checkNormalises("bookmarks.incoherent-location-unit", malformed: bookmark,
                        peer: bookmarkPeer, merge: { BookmarkKind.merge(local: $0, remote: $1) },
                        digest: valueDigest, report: report)
        let carried = BookmarkKind.merge(local: bookmark, remote: bookmark)
        let carrier = BookmarkKind.locationStamp(of: bookmark)
        report.check("bookmarks.incoherent-location-unit.normalises-onto-the-carrier-stamp",
                     carried.spaceUuid.updatedAtMs == carrier
                     && carried.parentUuid.updatedAtMs == carrier, """
                       malformed = \(bookmark.oneLine)
                       carrier stamp (§4.3) = \(carrier)
                       merged    = \(carried.oneLine)
                     """)

        let ruleUuid = generators.rng.pick(Pool.uuids)
        let rule = generators.ruleEntity(uuid: ruleUuid, malformed: true)
        let rulePeer = generators.ruleEntity(uuid: ruleUuid)
        if rule.pathPrefix.updatedAtMs != rule.host.updatedAtMs
            || rule.ask.updatedAtMs != rule.host.updatedAtMs {
            incoherentRules += 1
        }
        checkNormalises("urlrules.incoherent-content-group", malformed: rule, peer: rulePeer,
                        merge: { URLRuleKind.merge(local: $0, remote: $1) },
                        digest: valueDigest, report: report)
        let grouped = URLRuleKind.merge(local: rule, remote: rule)
        report.check("urlrules.incoherent-content-group.normalises-onto-the-carrier-stamp",
                     grouped.host.updatedAtMs == rule.host.updatedAtMs
                     && grouped.pathPrefix.updatedAtMs == rule.host.updatedAtMs
                     && grouped.ask.updatedAtMs == rule.host.updatedAtMs, """
                       malformed = \(rule.oneLine)
                       carrier stamp (§8.2 rule 1) = \(rule.host.updatedAtMs)
                       merged    = \(grouped.oneLine)
                     """)
    }
    markNormalisationPassed("bookmarks.incoherent-location-unit", report: report)
    markNormalisationPassed("urlrules.incoherent-content-group", report: report)
    report.markPassed("bookmarks.incoherent-location-unit.normalises-onto-the-carrier-stamp")
    report.markPassed("urlrules.incoherent-content-group.normalises-onto-the-carrier-stamp")

    // The laws above are only worth anything if the generator really produced
    // the malformed shape, so the run fails when it produced none of it.
    report.check("bookmarks.incoherent-location-unit.is-actually-exercised",
                 incoherentBookmarks > 0,
                 "no generated bookmark carried unequal location member stamps on this seed")
    report.markPassed("bookmarks.incoherent-location-unit.is-actually-exercised")
    report.check("urlrules.incoherent-content-group.is-actually-exercised", incoherentRules > 0,
                 "no generated rule carried unequal content-group member stamps on this seed")
    report.markPassed("urlrules.incoherent-content-group.is-actually-exercised")
}

// MARK: - Always-emitted fields that are absent

/// phi_entity.proto: every mutable field is a `PhiSettingValue`, "always
/// emitted, never omitted-when-empty -- an absent field cannot carry a
/// timestamp". A truncated payload that omits one is materialised as an empty
/// submessage, which changes the entity's BYTES with no change of meaning, so
/// the one thing that must be true is that it happens once and costs one commit.
private func checkAbsentAlwaysEmittedFieldNormalisation(iterations: Int,
                                                        generators: inout Generators,
                                                        report: Report) {
    var truncations = 0

    func probe<E: SwiftProtobuf.Message & Equatable>(
        _ name: String, _ entity: E, _ peer: E, _ fields: [Int], _ index: Int,
        _ merge: (E, E) -> E, _ digest: (E) -> String) {
        guard let truncated = withoutField(entity, number: fields[index % fields.count]) else {
            return
        }
        truncations += 1
        checkNormalises("\(name).absent-always-emitted-field", malformed: truncated, peer: peer,
                        merge: merge, digest: digest, report: report)
    }

    for _ in 0..<iterations {
        generators.beginTrio(mode: generators.rng.bool() ? .mixed : .allStampsEqual)
        let index = generators.rng.below(16)

        let spaceUuid = generators.rng.pick(Pool.spaceUuids)
        probe("spaces", generators.spaceEntity(uuid: spaceUuid),
              generators.spaceEntity(uuid: spaceUuid), AlwaysEmitted.space.sorted(), index,
              { SyncableSpaces.merge(local: $0, remote: $1) }, valueDigest)

        let bookmarkUuid = generators.rng.pick(Pool.uuids)
        let isFolder = generators.rng.bool()
        probe("bookmarks", generators.bookmarkEntity(uuid: bookmarkUuid, isFolder: isFolder),
              generators.bookmarkEntity(uuid: bookmarkUuid, isFolder: isFolder),
              AlwaysEmitted.bookmark.sorted(), index,
              { BookmarkKind.merge(local: $0, remote: $1) }, valueDigest)

        let lineage = generators.rng.pick(Pool.uuids).lowercased()
        let owner: Phi_PhiPinTabEntity.OneOf_Owner?
        switch generators.rng.below(3) {
        case 0: owner = .spaceUuid(generators.rng.pick(Pool.spaceUuids))
        case 1: owner = .profileUuid(generators.rng.pick(Pool.uuids))
        default: owner = nil            // App scope: absence is a value (§2.4)
        }
        probe("pins", generators.pinEntity(lineage: lineage, owner: owner),
              generators.pinEntity(lineage: lineage, owner: owner), AlwaysEmitted.pin.sorted(),
              index, { PinKind.merge(local: $0, remote: $1) }, valueDigest)

        let ruleUuid = generators.rng.pick(Pool.uuids)
        probe("urlrules", generators.ruleEntity(uuid: ruleUuid),
              generators.ruleEntity(uuid: ruleUuid), AlwaysEmitted.rule.sorted(), index,
              { URLRuleKind.merge(local: $0, remote: $1) }, valueDigest)
    }

    for name in ["spaces", "bookmarks", "pins", "urlrules"] {
        markNormalisationPassed("\(name).absent-always-emitted-field", report: report)
    }
    report.check("absent-always-emitted-field.is-actually-exercised", truncations > 0,
                 "no always-emitted field was ever removed on this seed")
    report.markPassed("absent-always-emitted-field.is-actually-exercised")
}

// MARK: - Entry point

func runNormalisationProperties(iterations: Int, generators: inout Generators, report: Report) {
    checkCreatedAtSanitisation(report: report)
    checkMergeUnitStampNormalisation(iterations: iterations, generators: &generators,
                                     report: report)
    checkAbsentAlwaysEmittedFieldNormalisation(iterations: iterations, generators: &generators,
                                               report: report)
}

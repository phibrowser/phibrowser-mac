// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Adversarial generators. Every pool is deliberately tiny so equal timestamps,
// equal bytes and equal locations occur constantly: the interesting merge bugs
// live on the tie paths, not on the "obviously newer wins" path.

enum Pool {
    /// Duplicates are intentional -- they make exact ties the common case.
    static let stamps: [Int64] = [0, 0, 0, 1, 7, 7, 7, 1_000, 1_700_000_000_000,
                                  1_700_000_000_000, -1, Int64.max]
    static let texts = ["", "a", "b", "A", "aa", " ", "x\u{0}y", "\u{7A7A}\u{95F4}"]
    static let hosts = ["", "example.com", "Example.com.", "*", "*.", "a/b", "[::1]",
                        "host:8080", "x.example.com"]
    static let paths = ["", "/", "/a", "/a/", "/%2F", "  /b  "]
    static let legalRanks = ["1", "V", "Vz", "W", "b", "z9", "zzzV", "V1"]
    /// `isLegalRank` rejects every one of these, and `rankBetween` traps on the
    /// first two as upper bounds: they must never leave the decoding boundary.
    static let illegalRanks = ["", "0", "V0", "Z!", "a b", "\u{7A7A}"]
    static let uuids = ["11111111-1111-4111-8111-111111111111",
                        "22222222-2222-4222-8222-222222222222",
                        "33333333-3333-4333-8333-333333333333"]
    static let spaceUuids = ["space-a", "space-b", "default-space"]
    static let urls = ["https://a.example/", "https://b.example/", "https://a.example/x"]
    static let opacities: [Int64] = [-1, 0, 500, 1_000]
    /// The LEGAL `created_at_ms` domain. `phi_entity.proto` declares the field a
    /// plain proto3 `int64` merged with `min()`, so 0 is indistinguishable from
    /// an absent field on the wire and is the encoding of "unset"; a real
    /// creation instant is a positive epoch millisecond. Non-positive values are
    /// the SANITISED domain, generated only by
    /// `checkCreatedAtSanitisation` — see the README, "created_at_ms".
    static let createdAt: [Int64] = [0, 0, 1, 1_699_999_999_000, 1_700_000_000_000]
    /// Values the merge is contracted to rewrite to "unset".
    static let illegalCreatedAt: [Int64] = [-1, -5, -1_700_000_000_000, Int64.min + 1]
    static let sources: [Int32] = [0, 0, 1, 2, -1]
}

/// How a generated replica trio relates to its siblings.
enum TieMode {
    /// Free-running stamps: ordinary LWW.
    case mixed
    /// Every stamp on every field is the same value, so the byte tie-break is
    /// the only thing deciding any field. This is the "timestamp ties resolve
    /// identically on both sides" case.
    case allStampsEqual
}

struct Generators {
    var rng: SplitMix64
    var mode: TieMode = .mixed
    private var fixedStamp: Int64 = 7

    init(rng: SplitMix64) { self.rng = rng }

    mutating func beginTrio(mode: TieMode) {
        self.mode = mode
        fixedStamp = rng.pick(Pool.stamps)
    }

    mutating func stamp() -> Int64 {
        mode == .allStampsEqual ? fixedStamp : rng.pick(Pool.stamps)
    }

    mutating func text(_ pool: [String] = Pool.texts) -> Phi_PhiSettingValue {
        settingValue(rng.pick(pool), stamp())
    }

    mutating func rank(legalOnly: Bool) -> Phi_PhiSettingValue {
        let value = legalOnly || rng.chance(4)
            ? rng.pick(Pool.legalRanks)
            : rng.pick(Pool.legalRanks + Pool.illegalRanks)
        return settingValue(value, stamp())
    }

    /// Occasionally hand a field the wrong oneof case, which is what a newer or
    /// corrupted peer produces. `stringValue` then reads back as "" while the
    /// serialized bytes differ, which is exactly the situation the byte
    /// tie-break has to stay symmetric under.
    mutating func maybeWrongCase(_ value: Phi_PhiSettingValue) -> Phi_PhiSettingValue {
        guard rng.chance(12) else { return value }
        return settingValue(bool: rng.bool(), value.updatedAtMs)
    }

    mutating func maybeUnknown<M: SwiftProtobuf.Message>(_ message: M, reserved: Int) -> M {
        guard rng.chance(3) else { return message }
        return addingUnknownField(message, number: reserved, value: UInt64(rng.int(1...9)))
    }

    // MARK: - Settings

    mutating func settingsEntity(keys: [String]) -> Phi_PhiSettingEntity {
        var entity = Phi_PhiSettingEntity()
        for key in keys where !rng.chance(6) {
            switch rng.below(3) {
            case 0: entity.values[key] = settingValue(rng.pick(Pool.texts), stamp())
            case 1: entity.values[key] = settingValue(bool: rng.bool(), stamp())
            default: entity.values[key] = settingValue(int: Int64(rng.int(-2...2)), stamp())
            }
        }
        return maybeUnknown(entity, reserved: 9)
    }

    // MARK: - Spaces

    mutating func spaceEntity(uuid: String) -> Phi_PhiSpaceEntity {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = uuid
        entity.name = maybeWrongCase(text())
        entity.iconName = text()
        entity.colorHex = text()
        entity.rank = rank(legalOnly: false)
        if !rng.chance(5) { entity.profileUuid = text(Pool.uuids) }
        if !rng.chance(5) { entity.themeID = text() }
        entity.overlayOpacityLight = settingValue(int: rng.pick(Pool.opacities), stamp())
        entity.overlayOpacityDark = settingValue(int: rng.pick(Pool.opacities), stamp())
        entity.createdAtMs = rng.pick(Pool.createdAt)
        return maybeUnknown(entity, reserved: 13)
    }

    // MARK: - Bookmarks

    /// Location is one merge unit: `space_uuid` + `parent_uuid` share a stamp
    /// carried by whichever member is authoritative for the shape (space for a
    /// root, parent for a descendant). A WELL-FORMED bookmark stamps both
    /// members equally, which is the only shape a Phi publisher emits
    /// (`BookmarkKind.stamp` writes one stamp to both). `malformed: true` breaks
    /// that on purpose, for the normalisation properties.
    mutating func bookmarkEntity(uuid: String, isFolder: Bool,
                                 malformed: Bool = false) -> Phi_PhiBookmarkEntity {
        var entity = Phi_PhiBookmarkEntity()
        entity.bookmarkUuid = uuid
        let parent = rng.chance(2) ? "" : rng.pick(Pool.uuids)
        let space = rng.pick(Pool.spaceUuids)
        let locationStamp = stamp()
        entity.spaceUuid = settingValue(space, locationStamp)
        entity.parentUuid = settingValue(parent, locationStamp)
        if malformed, rng.chance(2) {
            // Unequal member stamps: the carrier rule must still be used verbatim.
            entity.parentUuid.updatedAtMs = stamp()
        }
        entity.rank = rank(legalOnly: false)
        entity.isFolder = isFolder
        entity.title = text()
        entity.url = text(Pool.urls)
        entity.secondaryURL = text(Pool.urls + [""])
        entity.secondaryTitle = text()
        entity.source = rng.pick(Pool.sources)
        entity.createdAtMs = rng.pick(Pool.createdAt)
        return maybeUnknown(entity, reserved: 14)
    }

    // MARK: - Pins

    mutating func pinEntity(lineage: String, owner: Phi_PhiPinTabEntity.OneOf_Owner?)
        -> Phi_PhiPinTabEntity {
        var entity = Phi_PhiPinTabEntity()
        entity.pinUuid = lineage
        entity.owner = owner
        entity.rank = rank(legalOnly: false)
        entity.title = text()
        entity.url = text(Pool.urls)
        entity.splitPartnerUuid = text(Pool.uuids + [""])
        entity.source = rng.pick(Pool.sources)
        entity.createdAtMs = rng.pick(Pool.createdAt)
        return maybeUnknown(entity, reserved: 12)
    }

    // MARK: - URL rules

    /// The three units: the content group (host/path/ask under host's stamp),
    /// the target, and the rank. A well-formed rule stamps all three content
    /// members from the host carrier (§8.2 rule 1), which is what
    /// `URLRuleKind.stamp` emits; `malformed: true` breaks that on purpose, for
    /// the normalisation properties.
    mutating func ruleEntity(uuid: String, malformed: Bool = false) -> Phi_PhiURLRuleEntity {
        var entity = Phi_PhiURLRuleEntity()
        entity.ruleUuid = uuid
        let contentStamp = stamp()
        entity.host = settingValue(rng.pick(Pool.hosts), contentStamp)
        entity.pathPrefix = settingValue(rng.pick(Pool.paths), contentStamp)
        entity.ask = settingValue(bool: rng.bool(), contentStamp)
        if malformed, rng.chance(2) {
            // Malformed peer: group members disagree about the stamp. Only the
            // host carrier may be read.
            entity.pathPrefix.updatedAtMs = stamp()
            entity.ask.updatedAtMs = stamp()
        }
        entity.targetSpaceUuid = text(Pool.spaceUuids + ["incognito-space", ""])
        entity.rank = rank(legalOnly: false)
        entity.source = rng.pick(Pool.sources)
        entity.createdAtMs = rng.pick(Pool.createdAt)
        return maybeUnknown(entity, reserved: 11)
    }
}

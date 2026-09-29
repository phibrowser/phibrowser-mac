// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import SwiftProtobuf

// The production Space apply pass (`PhiSyncEngine.applySpaces`), the pull's Space tag routing
// (`routeSpaceEntity`) and the pull's per-page tag-index extension, re-hosted in `SpaceApplyHost`
// by extract_production_slices.py. This file supplies the engine members they read and a fake
// local store, then pins the apply-loop decisions the convergence properties above cannot reach:
// a landing clears a refusal, a Space being deleted locally is never landed again (both mark
// reads), a mapped Space outside the sync view is parked instead of created over, and a tombstone
// on a later page resolves a Space an earlier page of the same pull introduced.

func AppLogInfo(_ text: @autoclosure () -> String) {}
func AppLogWarn(_ text: @autoclosure () -> String) {}
func AppLogError(_ text: @autoclosure () -> String) {}

enum PhiSyncLog {
    static func describe(_ error: Error) -> String { String(describing: error) }
}

/// Routing decrypts only a live entity; the tombstone case pinned here is routed before any decrypt.
enum PhiEntityCodec {
    struct NotHosted: Error {}
    static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Phi_PhiEntity { throw NotHosted() }
}

actor SpaceApplyHost {
    let spaceAccess: (any PhiSpaceLocalAccess)?
    var spaceCounters = SpaceRoundCounters()
    var cursorSaveFailures = 0
    private let clockMs: Int64

    init(access: any PhiSpaceLocalAccess, nowMs: Int64) {
        spaceAccess = access
        clockMs = nowMs
    }

    var isStopped: Bool { false }
    func now() -> Int64 { clockMs }
    func hlcNow() -> Int64 { clockMs }
    func observeStamps(of entity: Phi_PhiSpaceEntity) {}

    /// One page's Space arrivals through the production apply pass.
    func apply(_ arrivals: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String, version: Int64)],
               to table: PhiSpaceSyncTable) async -> PhiSpaceSyncTable {
        var batch = SpacePullBatch()
        batch.decoded = arrivals
        var result = table
        await applySpaces(batch, table: &result)
        return result
    }
}

/// Only what the apply pass reads and writes. Every write is recorded.
@MainActor
final class ApplyFakeSpaceAccess: PhiSpaceLocalAccess {
    /// The sync-eligible view (`currentSpaces()`).
    var spaces: [PhiLocalSpace] = []
    /// Rows in unfiltered storage (`isKnownLocalSpace`).
    var storedSpaceIds: Set<String> = []
    var mappings: [String: String] = [:]           // local id -> sync uuid
    var profileIdByUuid: [String: String] = [:]
    /// Successive answers of `isBeingDeletedLocally`; the last one repeats.
    var beingDeletedAnswers: [Bool] = [false]
    /// Called after every `isBeingDeletedLocally` answer, to model a deletion starting in between.
    var afterBeingDeletedRead: ((Int) -> Void)?
    private(set) var beingDeletedReads = 0
    private(set) var writes: [String] = []

    func currentSpaces() -> [PhiLocalSpace] { spaces }
    func allSpacesForOrdering() -> [PhiLocalSpace] { spaces }
    func globalUuid(forProfileId profileId: String) -> String? {
        profileIdByUuid.first { $0.value == profileId }?.key
    }
    func localProfileId(forGlobalUuid uuid: String) -> String? { profileIdByUuid[uuid] }
    func isKnownLocalProfile(_ profileId: String) -> Bool { profileIdByUuid.values.contains(profileId) }
    func dropMapping(forProfileId profileId: String) { writes.append("dropProfileMapping") }
    func syncUuid(forSpaceId spaceId: String) -> String? { mappings[spaceId] }
    func localSpaceId(forSyncUuid uuid: String) -> String? {
        mappings.filter { $0.value == uuid }.keys.sorted().first
    }
    func ensureMapped(spaceId: String) throws -> String {
        if let uuid = mappings[spaceId] { return uuid }
        mappings[spaceId] = "sync-\(spaceId)"
        return "sync-\(spaceId)"
    }
    func mapSpace(_ spaceId: String, toSyncUuid uuid: String) throws {
        writes.append("mapSpace")
        mappings[spaceId] = uuid
    }
    func dropSpaceMapping(forSpaceId spaceId: String) {
        writes.append("dropSpaceMapping")
        mappings.removeValue(forKey: spaceId)
    }
    func isKnownLocalSpace(_ spaceId: String) -> Bool { storedSpaceIds.contains(spaceId) }
    func allSpaceMappings() -> [String: String] { mappings }
    func isBeingDeletedLocally(syncUuid: String) -> Bool {
        let answer = beingDeletedAnswers[min(beingDeletedReads, beingDeletedAnswers.count - 1)]
        beingDeletedReads += 1
        afterBeingDeletedRead?(beingDeletedReads)
        return answer
    }
    func pairableSpaces() -> [PhiLocalSpace] { spaces }
    func isImporting(intoSpaceId spaceId: String) -> Bool { false }
    func refreshAccountProfiles() async -> ProfileRefreshOutcome { .unchanged }
    func profilesCreatedInLastRefresh() -> Int { 0 }

    func create(_ space: PhiLocalSpace) async throws {
        writes.append("create")
        spaces.append(space)
        storedSpaceIds.insert(space.spaceId)
    }
    func update(spaceId: String, name: String?, colorHex: String?,
                iconName: String?, createdDate: Date?) async throws { writes.append("update") }
    func rebind(spaceId: String, toProfileId profileId: String) async throws { writes.append("rebind") }
    func applyThemeState(spaceId: String, themeId: String?,
                         opacityLight: Double?, opacityDark: Double?) async throws {
        writes.append("applyThemeState")
    }
    func applyOrder(_ orderedSpaceIds: [String]) async throws {}
    func hide(spaceId: String) async throws { writes.append("hide") }
    func purge(spaceId: String) async throws { writes.append("purge") }

    var landingWrites: [String] {
        writes.filter { ["create", "update", "rebind", "applyThemeState", "mapSpace"].contains($0) }
    }
}

/// Drives an async body from this synchronous top level. The fake store is main-actor isolated,
/// so the main run loop is spun (never blocked) until the body finishes.
private final class ResultBox<T> { var value: T? }

private func runToCompletion<T>(_ body: @escaping () async -> T) -> T {
    let box = ResultBox<T>()
    Task { box.value = await body() }
    while box.value == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    return box.value!
}

private let applyNowMs: Int64 = 1_700_000_000_000
private let applyProfileUuid = "profile-uuid-a"

private func applyEntity(_ uuid: String, name: String = "Work") -> Phi_PhiSpaceEntity {
    var entity = Phi_PhiSpaceEntity()
    entity.spaceUuid = uuid
    entity.name = settingValue(name, applyNowMs - 60_000)
    entity.iconName = settingValue("icon", applyNowMs - 60_000)
    entity.colorHex = settingValue("#101010", applyNowMs - 60_000)
    entity.rank = settingValue("V", applyNowMs - 60_000)
    entity.profileUuid = settingValue(applyProfileUuid, applyNowMs - 60_000)
    entity.themeID = settingValue("", applyNowMs - 60_000)
    entity.overlayOpacityLight = settingValue(int: -1, applyNowMs - 60_000)
    entity.overlayOpacityDark = settingValue(int: -1, applyNowMs - 60_000)
    entity.createdAtMs = applyNowMs - 3_600_000
    return entity
}

@MainActor
private func applyAccess() -> ApplyFakeSpaceAccess {
    let access = ApplyFakeSpaceAccess()
    access.profileIdByUuid = [applyProfileUuid: "profile-a"]
    return access
}

private func publishedCursor(version: Int64) -> PhiSpaceCursor {
    var cursor = PhiSpaceCursor()
    cursor.entityId = "srv-a"
    cursor.version = version
    cursor.reconciled = try? applyEntity("sync-a").serializedData()
    cursor.server = cursor.reconciled
    return cursor
}

// MARK: - BH-1: a landing clears a refusal

func checkALandingClearsARefusal(report: Report) {
    let (table, writes) = runToCompletion { () async -> (PhiSpaceSyncTable, [String]) in
        let access = await applyAccess()
        var table = PhiSpaceSyncTable()
        var refused = PhiSpaceCursor()
        refused.refusedAtMs = applyNowMs - 120_000       // an earlier version was refused
        table.cursors["sync-a"] = refused
        let host = SpaceApplyHost(access: access, nowMs: applyNowMs)
        let after = await host.apply([(uuid: "sync-a", entity: applyEntity("sync-a"),
                                       entityId: "srv-a", version: 3)], to: table)
        return (after, await access.writes)
    }
    let cursor = table.cursors["sync-a"]
    report.check("spaces.apply.a-landed-space-is-no-longer-refused",
                 writes.contains("create") && cursor?.refusedAtMs == nil && cursor?.reconciled != nil,
                 "writes \(writes); refusedAtMs \(String(describing: cursor?.refusedAtMs))")
    report.markPassed("spaces.apply.a-landed-space-is-no-longer-refused")
}

// MARK: - DI-3: a Space being deleted locally is not landed again

func checkASpaceBeingDeletedIsNotLandedAgain(report: Report) {
    // The cascade is still running: the row is there and the mark is set from the start.
    let cascading = runToCompletion { () async -> (PhiSpaceSyncTable, [String], [String: String]) in
        let access = await applyAccess()
        await MainActor.run {
            access.spaces = [PhiLocalSpace(spaceId: "local-a", profileId: "profile-a", name: "Work",
                                           colorHex: "#101010", iconName: "icon", sortOrder: 0,
                                           createdDate: Date(timeIntervalSince1970: 1_696_396_400),
                                           themeId: nil, opacityLight: nil, opacityDark: nil)]
            access.storedSpaceIds = ["local-a"]
            access.mappings = ["local-a": "sync-a"]
            access.beingDeletedAnswers = [true]
        }
        var table = PhiSpaceSyncTable()
        table.cursors["sync-a"] = publishedCursor(version: 4)
        let host = SpaceApplyHost(access: access, nowMs: applyNowMs)
        let after = await host.apply([(uuid: "sync-a", entity: applyEntity("sync-a", name: "Renamed"),
                                       entityId: "srv-a", version: 6)], to: table)
        return (after, await access.landingWrites, await access.mappings)
    }
    report.check("spaces.apply.a-space-being-deleted-is-not-updated",
                 cascading.1.isEmpty && cascading.2["local-a"] == "sync-a"
                    && cascading.0.cursors["sync-a"]?.version == 6
                    && cascading.0.cursors["sync-a"]?.pendingApply != nil,
                 "writes \(cascading.1); mappings \(cascading.2); cursor "
                    + "\(String(describing: cascading.0.cursors["sync-a"]?.version))")
    report.markPassed("spaces.apply.a-space-being-deleted-is-not-updated")

    // R1: the deletion begins after the first mark read, and its cascade removes the row before
    // the row check. Only the second read, after the row was seen gone, can see it.
    let racing = runToCompletion { () async -> (PhiSpaceSyncTable, [String], [String], [String: String]) in
        let access = await applyAccess()
        await MainActor.run {
            access.storedSpaceIds = []                   // the cascade has committed
            access.mappings = ["local-a": "sync-a"]
            access.beingDeletedAnswers = [false, true]
        }
        var table = PhiSpaceSyncTable()
        table.cursors["sync-a"] = publishedCursor(version: 4)
        let host = SpaceApplyHost(access: access, nowMs: applyNowMs)
        let after = await host.apply([(uuid: "sync-a", entity: applyEntity("sync-a", name: "Renamed"),
                                       entityId: "srv-a", version: 6)], to: table)
        return (after, await access.landingWrites, await access.writes, await access.mappings)
    }
    report.check("spaces.apply.a-deletion-begun-mid-round-keeps-its-mapping",
                 racing.1.isEmpty && !racing.2.contains("dropSpaceMapping")
                    && racing.3 == ["local-a": "sync-a"]
                    && racing.0.cursors["sync-a"]?.version == 6
                    && racing.0.cursors["sync-a"]?.pendingApply != nil,
                 "writes \(racing.2); mappings \(racing.3)")
    report.markPassed("spaces.apply.a-deletion-begun-mid-round-keeps-its-mapping")

    // Control: with no deletion anywhere, the same dead mapping is repaired and the Space lands.
    let repaired = runToCompletion { () async -> [String] in
        let access = await applyAccess()
        await MainActor.run {
            access.storedSpaceIds = []
            access.mappings = ["local-a": "sync-a"]
        }
        var table = PhiSpaceSyncTable()
        table.cursors["sync-a"] = publishedCursor(version: 4)
        let host = SpaceApplyHost(access: access, nowMs: applyNowMs)
        _ = await host.apply([(uuid: "sync-a", entity: applyEntity("sync-a"),
                               entityId: "srv-a", version: 6)], to: table)
        return await access.writes
    }
    report.check("spaces.apply.a-dead-mapping-is-still-repaired",
                 repaired.contains("dropSpaceMapping") && repaired.contains("create"),
                 "writes \(repaired)")
    report.markPassed("spaces.apply.a-dead-mapping-is-still-repaired")
}

// MARK: - DI-1: a mapped Space outside the sync view is parked, never created over

func checkAMappedSpaceOutsideTheSyncViewIsParked(report: Report) {
    let result = runToCompletion { () async -> (PhiSpaceSyncTable, [String]) in
        let access = await applyAccess()
        await MainActor.run {
            access.spaces = []                           // its Profile has no mapping
            access.storedSpaceIds = ["local-a"]          // but the row exists
            access.mappings = ["local-a": "sync-a"]
        }
        var table = PhiSpaceSyncTable()
        table.cursors["sync-a"] = publishedCursor(version: 4)
        let host = SpaceApplyHost(access: access, nowMs: applyNowMs)
        let after = await host.apply([(uuid: "sync-a", entity: applyEntity("sync-a", name: "Renamed"),
                                       entityId: "srv-a", version: 6)], to: table)
        return (after, await access.writes)
    }
    let cursor = result.0.cursors["sync-a"]
    report.check("spaces.apply.a-mapped-space-outside-the-sync-view-is-parked",
                 !result.1.contains("create") && cursor?.pendingApply != nil && cursor?.version == 6,
                 "writes \(result.1); pendingApply \(cursor?.pendingApply != nil)")
    report.markPassed("spaces.apply.a-mapped-space-outside-the-sync-view-is-parked")
}

// MARK: - A tombstone on a later page of the same pull

func checkATombstoneResolvesASpaceFromAnEarlierPage(report: Report) {
    let tombstones = runToCompletion { () async -> [String] in
        let host = SpaceApplyHost(access: await applyAccess(), nowMs: applyNowMs)
        return await host.routeAcrossTwoPages()
    }
    report.check("spaces.pull.a-tombstone-resolves-a-space-from-an-earlier-page",
                 tombstones == ["sync-new"], "routed tombstones \(tombstones)")
    report.markPassed("spaces.pull.a-tombstone-resolves-a-space-from-an-earlier-page")
}

extension SpaceApplyHost {
    /// Page 1 introduces a Space no cursor or mapping knows; page 2 carries its tombstone.
    func routeAcrossTwoPages() -> [String] {
        var tagIndex: [String: String] = [:]         // the pull's entry index knew nothing of it
        var page1 = SpacePullBatch()
        page1.decoded = [(uuid: "sync-new", entity: applyEntity("sync-new"), entityId: "srv-n", version: 1)]
        extendTagIndex(&tagIndex, with: page1)
        var page2 = SpacePullBatch()
        let hash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("sync-new"))
        routeSpaceEntity(PhiRemoteEntity(entityId: "srv-n", clientTagHash: hash, version: 2,
                                         ciphertext: Data(), deleted: true),
                         key: SymmetricKey(size: .bits256), tagIndex: tagIndex, into: &page2)
        return page2.tombstones.map(\.uuid)
    }
}

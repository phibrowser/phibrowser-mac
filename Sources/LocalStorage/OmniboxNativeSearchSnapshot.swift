// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum OmniboxNativeEntityKind: String, Codable, Sendable {
    case bookmark
    case pin
}

struct OmniboxNativeEntity: Codable, Equatable, Sendable {
    let kind: OmniboxNativeEntityKind
    let entityID: String
    let title: String
    let url: String
    var isOpen = false
    var currentURL: String?
    /// Seconds since 1970; ranks native rows against each other only.
    var lastSeen: Double?
}

struct OmniboxNativeKindSnapshot: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case complete
        case limitExceeded = "limit_exceeded"
        case unavailable
    }
    let status: Status
    let entities: [OmniboxNativeEntity]
}

struct OmniboxNativeCommand: Codable, Equatable, Sendable {
    let commandID: String
    let title: String
    let keywords: [String]
}

struct OmniboxNativeCommandSnapshot: Codable, Sendable {
    let status: OmniboxNativeKindSnapshot.Status
    let entities: [OmniboxNativeCommand]
}

/// The last choice for one normalized input, as Chromium froze it at
/// selection time. `kind` and `entityID` are nil for an ordinary row.
struct OmniboxNativeLearningEntry: Codable, Equatable, Sendable {
    let text: String
    let kind: OmniboxNativeEntityKind?
    let entityID: String?
    /// Seconds since 1970.
    let lastUsed: Double
}

struct OmniboxNativeSearchSnapshot: Codable, Sendable {
    let mutationEpoch: String
    let pinScope: String
    let bookmarks: OmniboxNativeKindSnapshot
    let pins: OmniboxNativeKindSnapshot
    /// Runtime catalog, attached on the main actor; never read from the store.
    var commands: OmniboxNativeCommandSnapshot?
    /// Attached like `commands`; at most 256 KiB, dropped as a whole if invalid.
    var learning: [OmniboxNativeLearningEntry]?

    /// Drops the entity bound to the focused tab, which would only switch to itself.
    func excluding(entityID: String?) -> Self {
        guard let entityID else { return self }
        func drop(_ kind: OmniboxNativeKindSnapshot) -> OmniboxNativeKindSnapshot {
            .init(status: kind.status, entities: kind.entities.filter { $0.entityID != entityID })
        }
        return .init(mutationEpoch: mutationEpoch, pinScope: pinScope,
                     bookmarks: drop(bookmarks), pins: drop(pins), commands: commands, learning: learning)
    }

    /// Recheck each complete kind while attaching runtime display metadata.
    /// Metadata cannot alter persisted identity, title, or action target.
    func withRuntimeMetadata(
        ticket: OmniboxQueryTicket,
        bytesPerKind: Int = 512 * 1024,
        metadata: (OmniboxNativeEntity) -> (isOpen: Bool, currentURL: String?)
    ) throws -> Self {
        guard (1...512 * 1024).contains(bytesPerKind) else {
            throw OmniboxNativeQueryError.unavailable
        }
        func checkTicket() throws {
            if let failure = ticket.failure(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                throw failure
            }
        }
        func decorate(_ kind: OmniboxNativeKindSnapshot) throws -> OmniboxNativeKindSnapshot {
            try checkTicket()
            guard kind.status == .complete else { return kind }
            let overflow = OmniboxNativeKindSnapshot(status: .limitExceeded, entities: [])
            guard kind.entities.count <= 1024 else { return overflow }
            let encoder = JSONEncoder()
            var bytes = try encoder.encode(OmniboxNativeKindSnapshot(status: .complete, entities: [])).count
            guard bytes <= bytesPerKind else { return overflow }
            var entities: [OmniboxNativeEntity] = []
            entities.reserveCapacity(kind.entities.count)
            for var entity in kind.entities {
                try checkTicket()
                let value = metadata(entity)
                try checkTicket()
                // Refuse an oversized scalar before constructing its JSON copy.
                guard (value.currentURL?.utf8.count ?? 0) <= bytesPerKind else { return overflow }
                entity.isOpen = value.isOpen
                entity.currentURL = value.currentURL
                bytes += try encoder.encode(entity).count + (entities.isEmpty ? 0 : 1)
                guard bytes <= bytesPerKind else { return overflow }
                entities.append(entity)
            }
            return .init(status: .complete, entities: entities)
        }
        let result = try Self(mutationEpoch: mutationEpoch, pinScope: pinScope,
                              bookmarks: decorate(bookmarks), pins: decorate(pins))
        try checkTicket()
        _ = try result.encoded()
        return result
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 1024 * 1024 + 16 * 1024 else {
            throw OmniboxNativeQueryError.unavailable
        }
        return data
    }
}

enum OmniboxNativeSnapshotReader {
    struct Limits: Sendable {
        var candidatesPerKind = 1024
        var bytesPerKind = 512 * 1024
        var batchSize = 64
    }

    static func read(context: ModelContext, profileID: String, spaceID: String,
                     pinScope: PinnedTabScope, epoch: UInt64, ticket: OmniboxQueryTicket,
                     limits: Limits = Limits()) throws -> OmniboxNativeSearchSnapshot {
        let bookmarks = try readKind(.bookmark, context: context, profileID: profileID, spaceID: spaceID,
                                     pinScope: pinScope, ticket: ticket, limits: limits)
        let pins = try readKind(.pin, context: context, profileID: profileID, spaceID: spaceID,
                               pinScope: pinScope, ticket: ticket, limits: limits)
        return OmniboxNativeSearchSnapshot(mutationEpoch: String(epoch), pinScope: pinScope.rawValue,
                                          bookmarks: bookmarks, pins: pins)
    }

    // Call inside the same FIFO selection job that waits for synchronous dispatch.
    // Runtime metadata is intentionally re-resolved by the caller on MainActor.
    static func validate(_ expected: OmniboxNativeEntity, expectedEpoch: String,
                         expectedPinScope: String, context: ModelContext, profileID: String,
                         spaceID: String, pinScope: PinnedTabScope, epoch: UInt64,
                         ticket: OmniboxQueryTicket) throws -> OmniboxNativeEntity {
        try check(ticket)
        // Judged per entity: unrelated writes since the read keep a row valid.
        guard expectedPinScope == pinScope.rawValue,
              !expected.entityID.isEmpty else {
            AppLogDebug("[OmniboxNative] validate failed: pinScope expected=\(expectedPinScope) actual=\(pinScope.rawValue)")
            throw OmniboxNativeQueryError.unavailable
        }
        var query = descriptor(expected.kind, profileID: profileID, spaceID: spaceID,
                               pinScope: pinScope, entityID: expected.entityID)
        query.fetchLimit = 2
        let rows = try context.fetch(query)
        guard rows.count == 1, let row = rows.first,
              let actual = try entity(row, kind: expected.kind, context: context,
                                      profileID: profileID, spaceID: spaceID, pinScope: pinScope),
              actual.title == expected.title, actual.url == expected.url else {
            AppLogDebug("[OmniboxNative] validate failed kind=\(expected.kind.rawValue) rows=\(rows.count) " +
                "scope=\(pinScope.rawValue)")
            throw OmniboxNativeQueryError.unavailable
        }
        try check(ticket)
        return actual
    }

    private static func entity(_ row: TabDataModel, kind: OmniboxNativeEntityKind,
                               context: ModelContext, profileID: String, spaceID: String,
                               pinScope: PinnedTabScope) throws -> OmniboxNativeEntity? {
        guard !row.guid.isEmpty, row.secondaryUrl == nil, row.splitPartnerGuid == nil,
              row.splitPaneGuids == nil,
              let scheme = row.url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              row.url.host?.isEmpty == false else { return nil }
        if kind == .pin {
            var incoming = descriptor(.pin, profileID: profileID, spaceID: spaceID,
                                      pinScope: pinScope, partnerID: row.guid)
            incoming.fetchLimit = 1
            if !(try context.fetch(incoming)).isEmpty { return nil }
        }
        return OmniboxNativeEntity(kind: kind, entityID: row.guid,
            title: row.overrideTitle.flatMap { $0.isEmpty ? nil : $0 } ?? row.title,
            url: row.url.absoluteString, lastSeen: row.lastSeen?.timeIntervalSince1970)
    }

    private static func readKind(_ kind: OmniboxNativeEntityKind, context: ModelContext,
                                 profileID: String, spaceID: String, pinScope: PinnedTabScope,
                                 ticket: OmniboxQueryTicket, limits: Limits) throws -> OmniboxNativeKindSnapshot {
        guard limits.candidatesPerKind > 0, limits.bytesPerKind > 0, limits.batchSize > 0 else {
            return .init(status: .unavailable, entities: [])
        }
        let encoder = JSONEncoder()
        var bytes = try encoder.encode(OmniboxNativeKindSnapshot(status: .complete, entities: [])).count
        guard bytes <= limits.bytesPerKind else {
            return .init(status: .limitExceeded, entities: [])
        }
        var entities: [OmniboxNativeEntity] = []
        var identifiers = Set<String>()
        var offset = 0
        while true {
            try check(ticket)
            var descriptor = descriptor(kind, profileID: profileID, spaceID: spaceID, pinScope: pinScope)
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limits.batchSize
            let rows: [TabDataModel]
            do {
                rows = try context.fetch(descriptor)
            } catch {
                return .init(status: .unavailable, entities: [])
            }
            for row in rows {
                try check(ticket)
                let candidate: OmniboxNativeEntity?
                do {
                    candidate = try entity(row, kind: kind, context: context, profileID: profileID,
                                           spaceID: spaceID, pinScope: pinScope)
                } catch {
                    return .init(status: .unavailable, entities: [])
                }
                guard let entity = candidate else { continue }
                guard entities.count < limits.candidatesPerKind else {
                    return .init(status: .limitExceeded, entities: [])
                }
                guard entity.entityID.utf8.count <= limits.bytesPerKind,
                      entity.title.utf8.count <= limits.bytesPerKind, entity.url.utf8.count <= limits.bytesPerKind else {
                    return .init(status: .limitExceeded, entities: [])
                }
                guard identifiers.insert(row.guid).inserted else {
                    return .init(status: .unavailable, entities: [])
                }
                bytes += try encoder.encode(entity).count + (entities.isEmpty ? 0 : 1)
                guard bytes <= limits.bytesPerKind else {
                    return .init(status: .limitExceeded, entities: [])
                }
                entities.append(entity)
            }
            if rows.count < limits.batchSize { break }
            offset += rows.count
        }
        try check(ticket)
        return .init(status: .complete, entities: entities)
    }

    private static func check(_ ticket: OmniboxQueryTicket) throws {
        if let error = ticket.failure(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
            throw error
        }
    }

    private static func descriptor(_ kind: OmniboxNativeEntityKind, profileID: String,
                                   spaceID: String, pinScope: PinnedTabScope,
                                   partnerID: String? = nil, entityID: String? = nil) -> FetchDescriptor<TabDataModel> {
        let rawType = kind == .bookmark ? TabDataType.bookmark.rawValue : TabDataType.pinnedTab.rawValue
        let selectedID = entityID ?? ""
        let predicate: Predicate<TabDataModel>
        if kind == .bookmark {
            predicate = #Predicate<TabDataModel> {
                $0.type == rawType && $0.profile?.profileId == profileID && $0.spaceId == spaceID
                && (selectedID.isEmpty || $0.guid == selectedID)
            }
        } else {
            switch pinScope {
            case .space:
                predicate = #Predicate<TabDataModel> {
                    $0.type == rawType && ($0.profileId == profileID || $0.profile?.profileId == profileID)
                    && $0.spaceId == spaceID && (partnerID == nil || $0.splitPartnerGuid == partnerID)
                    && (selectedID.isEmpty || $0.guid == selectedID)
                }
            case .profile:
                predicate = #Predicate<TabDataModel> {
                    $0.type == rawType && ($0.profileId == profileID || $0.profile?.profileId == profileID)
                    && $0.spaceId == nil && (partnerID == nil || $0.splitPartnerGuid == partnerID)
                    && (selectedID.isEmpty || $0.guid == selectedID)
                }
            case .app:
                predicate = #Predicate<TabDataModel> {
                    $0.type == rawType && $0.profileId == nil && $0.spaceId == nil
                    && (partnerID == nil || $0.splitPartnerGuid == partnerID)
                    && (selectedID.isEmpty || $0.guid == selectedID)
                }
            }
        }
        return FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.guid), SortDescriptor(\.createdDate)])
    }
}

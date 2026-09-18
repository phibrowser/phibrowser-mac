// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// Observable presentation data. No field retains a SwiftData model or context.
/// Identity includes the store instance: equal IDs in two accounts are unrelated.
final class Space: ObservableObject, Identifiable {
    struct Content: Equatable {
        var profileId: String
        var name: String
        var colorHex: String
        var iconName: String
        var sortOrder: Int
        var createdDate: Date
        var updatedDate: Date
    }

    let spaceId: String
    let storeIdentifier: UUID?
    var id: String { spaceId }
    @Published private(set) var content: Content

    var profileId: String { content.profileId }
    var name: String { content.name }
    var colorHex: String { content.colorHex }
    var iconName: String { content.iconName }
    var sortOrder: Int { content.sortOrder }
    var createdDate: Date { content.createdDate }
    var updatedDate: Date { content.updatedDate }

    init(spaceId: String = UUID().uuidString,
         profileId: String,
         name: String,
         colorHex: String,
         iconName: String,
         sortOrder: Int,
         createdDate: Date = Date(),
         updatedDate: Date = Date(),
         storeIdentifier: UUID? = nil) {
        self.spaceId = spaceId
        self.storeIdentifier = storeIdentifier
        content = Content(profileId: profileId, name: name, colorHex: colorHex,
                          iconName: iconName, sortOrder: sortOrder,
                          createdDate: createdDate, updatedDate: updatedDate)
    }

    /// Called on the main thread when the owning manager receives a store update.
    /// A retained row observes one coherent change, including profile/theme edits.
    func update(from incoming: Space) {
        precondition(spaceId == incoming.spaceId && storeIdentifier == incoming.storeIdentifier)
        if content != incoming.content { content = incoming.content }
    }

    /// Reuses presentation objects only within the same store lifetime. The
    /// incoming list is authoritative, including deletion and an empty account.
    static func reconcile(_ incoming: [Space], with existing: [Space]) -> [Space] {
        let byId = Dictionary(existing.map { ($0.spaceId, $0) },
                              uniquingKeysWith: { first, _ in first })
        return incoming.map { fresh in
            guard let current = byId[fresh.spaceId],
                  current.storeIdentifier == fresh.storeIdentifier else { return fresh }
            current.update(from: fresh)
            return current
        }
    }
}

/// Detached routing data. Editors already maintain their own editable drafts.
struct SpaceRoutingRule: Equatable, Identifiable {
    let id: String
    let spaceId: String
    let host: String
    let pathPrefix: String?
    let askBeforeRouting: Bool
    let sortOrder: Int
    let createdDate: Date
    let syncId: String?
    let deletedDate: Date?

    init(id: String = UUID().uuidString, spaceId: String, host: String,
         pathPrefix: String? = nil, askBeforeRouting: Bool = false,
         sortOrder: Int, createdDate: Date = Date(), syncId: String? = nil, deletedDate: Date? = nil) {
        self.id = id
        self.spaceId = spaceId
        self.host = host
        self.pathPrefix = pathPrefix
        self.askBeforeRouting = askBeforeRouting
        self.sortOrder = sortOrder
        self.createdDate = createdDate
        self.syncId = syncId
        self.deletedDate = deletedDate
    }
}

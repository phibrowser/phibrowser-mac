// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// Modification record:
/// - V7 introduces `SpaceModel` and `SpaceURLRule` for the Phi Spaces feature.
///   `TabDataModel` is unchanged from V6 (it retains the V6 `lastSeen` column).
enum TabDataModelSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProfileModel.self, TabDataModel.self, SpaceModel.self, SpaceURLRule.self]
    }

    @Model
    final class ProfileModel {
        var guid: String
        @Attribute(.unique) var profileId: String

        @Relationship(inverse: \TabDataModel.profile)
        var tabs: [TabDataModel] = []

        @Relationship
        var bookmarkRoot: TabDataModel?

        init(guid: String = UUID().uuidString, profileId: String) {
            self.guid = guid
            self.profileId = profileId
        }

        static let entityName = "ProfileModel"
    }

    @Model
    final class TabDataModel {
        var guid: String
        var title: String
        var index: Int
        var url: URL
        var favicon: Data?
        var createdDate: Date
        var updatedDate: Date
        var type: Int = 0
        var overrideTitle: String?
        var isOpenned = false
        var isCreatedByChromium = false
        var needUpdateMetaData = false
        var spaceId: String?
        var profileId: String?
        var source: Int = 0
        var secondaryUrl: URL?
        var secondaryTitle: String?
        var splitPartnerGuid: String?
        var lastSeen: Date?

        @Relationship(inverse: \TabDataModel.children)
        var parent: TabDataModel?

        @Relationship(deleteRule: .cascade)
        var children: [TabDataModel] = []

        var profile: ProfileModel?

        init(title: String, guid: String, index: Int, url: URL, favicon: Data?, createdDate: Date, updatedDate: Date) {
            self.title = title
            self.guid = guid
            self.index = index
            self.url = url
            self.favicon = favicon
            self.createdDate = createdDate
            self.updatedDate = updatedDate
        }

        static let entityName = "TabDataModel"
    }

    /// A user-facing browsing context: a named, ordered group bound to exactly
    /// one profile (a profile can own many Spaces). At runtime each Space is
    /// backed by a dedicated Chromium window.
    ///
    /// Scoping of related `TabDataModel` rows differs by kind:
    /// - Pinned tabs are per-PROFILE — shared across every Space of that
    ///   profile. They are queried by `profile.profileId` alone; `spaceId` is
    ///   left nil on pinned rows and ignored by the pinned-tab queries.
    /// - Bookmarks are per-SPACE — each Space owns its own sub-tree under
    ///   `bookmarkRoot` and is queried by `(profileId, spaceId)`.
    @Model
    final class SpaceModel {
        @Attribute(.unique) var spaceId: String
        var profileId: String
        var name: String
        var colorHex: String
        var iconName: String
        var sortOrder: Int
        var createdDate: Date
        var updatedDate: Date

        /// The hidden top-level folder that owns this Space's bookmark tree.
        /// Mirrors `ProfileModel.bookmarkRoot`. Nil until first bookmark write
        /// (lazy-create) or until `ensureDefaultSpace` / `createSpace`
        /// materializes a root.
        @Relationship
        var bookmarkRoot: TabDataModel?

        init(spaceId: String = UUID().uuidString,
             profileId: String,
             name: String,
             colorHex: String,
             iconName: String,
             sortOrder: Int,
             createdDate: Date = Date(),
             updatedDate: Date = Date()) {
            self.spaceId = spaceId
            self.profileId = profileId
            self.name = name
            self.colorHex = colorHex
            self.iconName = iconName
            self.sortOrder = sortOrder
            self.createdDate = createdDate
            self.updatedDate = updatedDate
        }

        static let entityName = "SpaceModel"
    }

    /// A user-authored "send URLs matching this rule to that Space" entry.
    /// Stored as a separate model rather than an array on `SpaceModel` so
    /// rules can be queried and reordered cleanly, and so future per-rule
    /// metadata (e.g. last-matched-at) survives schema migration
    /// without touching the Space row. Owned by `SpaceManager`; UI must
    /// mutate via `SpaceManager.setRules(_:forSpaceId:)` so the routing
    /// table can be pushed down to Chromium atomically.
    @Model
    final class SpaceURLRule {
        @Attribute(.unique) var id: String
        /// Destination Space (matches `SpaceModel.spaceId`).
        var spaceId: String
        /// Match host. One of three forms:
        ///   - exact host ("github.com")
        ///   - wildcard subdomain pattern ("*.figma.com" matches both
        ///     `figma.com` and any sub-host)
        ///   - contains pattern ("*git*" matches any host containing "git";
        ///     detected before the wildcard form since a needle starting
        ///     with "." also carries the "*." prefix)
        /// Always lower-cased before persistence.
        var host: String
        /// Optional path-prefix match. Empty/nil = match any path.
        /// A non-empty prefix matches when the URL path equals the prefix
        /// or is followed by `/` (so `/foo` does not match `/foobar`).
        var pathPrefix: String?
        /// When true, a matching navigation is not routed silently: Chromium
        /// cancels it and asks the Swift side which Space to open it in (the
        /// rule's `spaceId` is the suggested default). When false, the URL is
        /// routed to `spaceId` automatically.
        var askBeforeRouting: Bool = false
        /// Ascending wins the final tiebreak when multiple rules match the
        /// same URL with equal specificity.
        var sortOrder: Int
        var createdDate: Date

        init(id: String = UUID().uuidString,
             spaceId: String,
             host: String,
             pathPrefix: String? = nil,
             askBeforeRouting: Bool = false,
             sortOrder: Int,
             createdDate: Date = Date()) {
            self.id = id
            self.spaceId = spaceId
            self.host = host
            self.pathPrefix = pathPrefix
            self.askBeforeRouting = askBeforeRouting
            self.sortOrder = sortOrder
            self.createdDate = createdDate
        }

        static let entityName = "SpaceURLRule"
    }
}

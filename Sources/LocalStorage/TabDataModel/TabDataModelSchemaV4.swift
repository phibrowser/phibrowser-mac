// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum TabDataModelSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProfileModel.self, TabDataModel.self]
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
        /// Second URL for a split-view bookmark. When non-nil, the bookmark
        /// represents two web pages and opens both as a split view on click.
        /// Nil for ordinary bookmarks and for folders.
        var secondaryUrl: URL?
        /// Display title for the secondary URL. Used by the bookmark bar and
        /// sidebar to show both panes' names. Nil for non-split bookmarks; may
        /// also be nil for split bookmarks saved before this field was added
        /// (callers fall back to the secondary URL's host in that case).
        var secondaryTitle: String?

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
}

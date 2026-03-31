// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData
enum TabDataModelSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [TabDataModel.self]
    }

    @Model
    class TabDataModel {
        var guid: String
        var title: String
        var index: Int
        var url: URL
        var favicon: Data?
        var createdDate: Date
        var updatedDate: Date
        var isPinned = false
        var overrideTitle: String?
        var isOpenned = false
        var isBookmark = false
        var isFolder = false
        var isCreatedByChromium = false
        var needUpdateMetaData = false
        var associatedProfileIdentifier: String?
        var spaceId: String?
        var profileId: String?
        var source: Int = 0 // 0: Phi, 1: Chromium, 2: Safari, 3: Arc

        @Relationship(inverse: \TabDataModel.children)
        var parent: TabDataModel?

        @Relationship(deleteRule: .cascade)
        var children: [TabDataModel] = []

        init(title: String, guid: String, index: Int, url: URL, favicon: Data?, createdDate: Date, updatedDate: Date) {
            self.title = title
            self.guid = guid
            self.index = index
            self.url = url
            self.favicon = favicon
            self.createdDate = createdDate
            self.updatedDate = updatedDate
        }
    }
}

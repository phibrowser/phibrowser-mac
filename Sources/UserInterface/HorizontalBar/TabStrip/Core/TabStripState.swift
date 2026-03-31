// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct TabRenderData: Equatable {
    var id: String
    var title: String
    var url: String
    var isActive: Bool
    var isPinned: Bool

    // `sourceTab` is intentionally excluded from `Equatable`.
    weak var sourceTab: Tab?
    static func == (lhs: TabRenderData, rhs: TabRenderData) -> Bool {
        return lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.url == rhs.url &&
            lhs.isActive == rhs.isActive &&
            lhs.isPinned == rhs.isPinned
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Temporary, window-scoped multi-selection of sidebar items.
/// Membership only; ordering is derived from authoritative tab and bookmark lists.
struct TabMultiSelection: Equatable {
    private(set) var guids: Set<Int>
    private(set) var bookmarkGuids: Set<String>

    /// Single feature gate for temporary multi-selection availability.
    static let isEnabled = true

    static let empty = TabMultiSelection(guids: [], bookmarkGuids: [])

    init(guids: Set<Int> = [], bookmarkGuids: Set<String> = []) {
        self.guids = guids
        self.bookmarkGuids = bookmarkGuids
    }

    var isActive: Bool { hasTabSelection || hasBookmarkSelection }
    var hasTabSelection: Bool { !guids.isEmpty }
    var hasBookmarkSelection: Bool { !bookmarkGuids.isEmpty }

    func contains(_ guid: Int) -> Bool { guids.contains(guid) }
    func containsBookmark(_ guid: String) -> Bool { bookmarkGuids.contains(guid) }

    mutating func toggle(_ guid: Int) {
        if guids.contains(guid) {
            guids.remove(guid)
        } else {
            guids.insert(guid)
        }
    }

    mutating func insert(_ guid: Int) {
        guids.insert(guid)
    }

    mutating func remove(_ guid: Int) {
        guids.remove(guid)
    }

    mutating func toggleBookmark(_ guid: String) {
        if bookmarkGuids.contains(guid) {
            bookmarkGuids.remove(guid)
        } else {
            bookmarkGuids.insert(guid)
        }
    }

    mutating func insertBookmark(_ guid: String) {
        bookmarkGuids.insert(guid)
    }

    mutating func removeBookmark(_ guid: String) {
        bookmarkGuids.remove(guid)
    }

    /// Drops any guids not present in `valid`, e.g. after their tabs close.
    mutating func formIntersection(_ valid: Set<Int>) {
        guids.formIntersection(valid)
    }

    mutating func formBookmarkIntersection(_ valid: Set<String>) {
        bookmarkGuids.formIntersection(valid)
    }
}

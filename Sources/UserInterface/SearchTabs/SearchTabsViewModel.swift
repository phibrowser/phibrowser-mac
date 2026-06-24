// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

@MainActor
final class SearchTabsViewModel: ObservableObject {
    @Published private(set) var snapshot: SearchTabsSnapshot
    @Published private(set) var sections: [SearchTabsSectionSnapshot] = []
    @Published private(set) var selectedIndex: Int = -1
    @Published private(set) var inputText: String = ""

    private let dataController: SearchTabsDataController
    private var collapsedSections = Set<SearchTabsSectionKind>()

    var items: [SearchTabsItem] {
        sections.flatMap(\.visibleItems)
    }

    var selectedItem: SearchTabsItem? {
        guard selectedIndex >= 0, selectedIndex < items.count else {
            return nil
        }
        return items[selectedIndex]
    }

    init(dataController: SearchTabsDataController) {
        self.dataController = dataController
        self.snapshot = dataController.snapshot(query: "")
        self.sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        self.selectedIndex = items.isEmpty ? -1 : 0
    }

    func reset() {
        updateInputText("")
    }

    func updateInputText(_ text: String) {
        inputText = text
        snapshot = dataController.snapshot(query: text)
        sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        selectedIndex = items.isEmpty ? -1 : 0
    }

    func selectNextItem() {
        guard !items.isEmpty else {
            selectedIndex = -1
            return
        }
        selectedIndex = min(selectedIndex + 1, items.count - 1)
    }

    func selectPreviousItem() {
        guard !items.isEmpty else {
            selectedIndex = -1
            return
        }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func selectItem(at index: Int) {
        guard index >= 0, index < items.count else {
            return
        }
        selectedIndex = index
    }

    func removeItem(withID itemID: String) {
        let selectedItemID = selectedItem?.id
        let removedVisibleIndex = items.firstIndex { $0.id == itemID }
        let filteredItems = snapshot.items.filter { $0.id != itemID }
        guard filteredItems.count != snapshot.items.count else {
            return
        }

        snapshot = SearchTabsSnapshot(
            query: snapshot.query,
            profileId: snapshot.profileId,
            windowId: snapshot.windowId,
            generatedAt: Date(),
            items: filteredItems
        )
        sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)

        if let selectedItemID,
           selectedItemID != itemID,
           let preservedIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            selectedIndex = preservedIndex
        } else if let removedVisibleIndex, !items.isEmpty {
            selectedIndex = min(removedVisibleIndex, items.count - 1)
        } else {
            selectedIndex = items.isEmpty ? -1 : min(max(selectedIndex, 0), items.count - 1)
        }
    }

    func toggleSection(_ section: SearchTabsSectionKind) {
        let selectedItemID = selectedItem?.id
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }

        sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        if let selectedItemID,
           let preservedIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            selectedIndex = preservedIndex
        } else if items.isEmpty {
            selectedIndex = -1
        } else {
            selectedIndex = min(max(selectedIndex, 0), items.count - 1)
        }
    }

    private static func makeSections(
        from items: [SearchTabsItem],
        collapsedSections: Set<SearchTabsSectionKind>
    ) -> [SearchTabsSectionSnapshot] {
        SearchTabsSectionKind.allCases.compactMap { section in
            let sectionItems = items.filter { SearchTabsSectionKind(item: $0) == section }
            guard !sectionItems.isEmpty else {
                return nil
            }
            return SearchTabsSectionSnapshot(
                kind: section,
                items: sectionItems,
                isCollapsed: collapsedSections.contains(section)
            )
        }
    }
}

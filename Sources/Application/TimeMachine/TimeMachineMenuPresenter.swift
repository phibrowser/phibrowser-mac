// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

struct TimeMachineMenuEntry: Equatable {
    let title: String
    let backupID: UUID?
    let isEnabled: Bool
}

struct TimeMachineMenuPresenter {
    static let emptyTitle = NSLocalizedString("No Backups Available", comment: "Help menu - Time Machine submenu placeholder when no completed backups exist")

    private let catalogStore: TimeMachineCatalogStore
    private let timeZone: TimeZone

    init(
        catalogStore: TimeMachineCatalogStore = TimeMachineCatalogStore(),
        timeZone: TimeZone = .current
    ) {
        self.catalogStore = catalogStore
        self.timeZone = timeZone
    }

    func menuEntries() throws -> [TimeMachineMenuEntry] {
        let backups = try catalogStore.load().completedBackups
        guard !backups.isEmpty else {
            return [
                TimeMachineMenuEntry(
                    title: Self.emptyTitle,
                    backupID: nil,
                    isEnabled: false
                )
            ]
        }

        return backups.map {
            TimeMachineMenuEntry(
                title: $0.menuTitle(timeZone: timeZone),
                backupID: $0.id,
                isEnabled: true
            )
        }
    }

    func backup(id: UUID) throws -> TimeMachineBackupRecord? {
        try catalogStore.load().completedBackups.first { $0.id == id }
    }

    func populate(_ menu: NSMenu, target: AnyObject, action: Selector) throws {
        menu.removeAllItems()

        for entry in try menuEntries() {
            let item = NSMenuItem(title: entry.title, action: entry.backupID == nil ? nil : action, keyEquivalent: "")
            item.target = target
            item.isEnabled = entry.isEnabled
            item.representedObject = entry.backupID?.uuidString
            menu.addItem(item)
        }
    }
}

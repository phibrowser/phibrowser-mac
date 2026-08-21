// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class BookmarkFolderIconTests: XCTestCase {
    func testSplitBookmarkContextMenuOffersLayoutConversion() {
        let bookmark = Bookmark(title: "Split",
                                url: "https://left.example",
                                secondaryUrl: "https://right.example",
                                layout: .vertical)
        let menu = NSMenu()

        bookmark.makeContextMenu(on: menu, source: .sidebar)

        let title = NSLocalizedString(
            "sidebar.tabContextMenu.convertToVerticalSplit",
            value: "Convert to Vertical Split",
            comment: "Split context menu - Switch a side-by-side split to a stacked split"
        )
        XCTAssertTrue(menu.items.contains { $0.title == title })
    }

    func testSidebarFolderContextMenuPlacesChangeIconAfterRename() {
        let folder = Bookmark(folderTitle: "Folder")
        let menu = NSMenu()

        folder.makeContextMenu(on: menu, source: .sidebar)

        let renameTitle = NSLocalizedString(
            "sidebar.bookmarkContextMenu.renameAction",
            value: "Rename...",
            comment: "Bookmark Rename menu item"
        )
        let changeIconTitle = NSLocalizedString(
            "sidebar.bookmarkContextMenu.changeIconAction",
            value: "Change Icon...",
            comment: "Bookmark folder context menu - Opens the folder icon picker"
        )
        let renameIndex = menu.items.firstIndex { $0.title == renameTitle }
        let changeIconIndex = menu.items.firstIndex { $0.title == changeIconTitle }

        XCTAssertNotNil(renameIndex)
        XCTAssertEqual(changeIconIndex, renameIndex.map { $0 + 1 })
    }

    func testSidebarChangeIconMenuActionRequestsPickerForFolder() throws {
        let folder = Bookmark(folderTitle: "Folder")
        let menu = NSMenu()
        folder.makeContextMenu(on: menu, source: .sidebar)
        let changeIconTitle = NSLocalizedString(
            "sidebar.bookmarkContextMenu.changeIconAction",
            value: "Change Icon...",
            comment: "Bookmark folder context menu - Opens the folder icon picker"
        )
        let changeIconItem = try XCTUnwrap(menu.items.first { $0.title == changeIconTitle })
        let request = expectation(
            forNotification: .bookmarkFolderIconPickerRequested,
            object: folder
        )
        let action = try XCTUnwrap(changeIconItem.action)

        XCTAssertTrue(
            NSApplication.shared.sendAction(
                action,
                to: changeIconItem.target,
                from: changeIconItem
            )
        )

        wait(for: [request], timeout: 1)
    }

    func testResourceMapCoversEveryIconWithUniqueAssets() {
        XCTAssertEqual(Set(BookmarkFolderIcon.resourceMap.keys), Set(BookmarkFolderIcon.allCases))

        let pickerIconNames = Set(BookmarkFolderIcon.allCases.map(\.rawValue))
        XCTAssertTrue(
            pickerIconNames.isSuperset(of: ["discord", "x", "reddit", "facebook", "thumb-up", "chart-bar"])
        )

        let pickerNames = BookmarkFolderIcon.allCases.map(\.resources.pickerAssetName)
        let animationNames = BookmarkFolderIcon.allCases.map(\.resources.animationResourceName)
        XCTAssertEqual(Set(pickerNames).count, BookmarkFolderIcon.allCases.count)
        XCTAssertEqual(Set(animationNames).count, BookmarkFolderIcon.allCases.count)
    }

    func testEveryMappedAssetIsBundled() {
        for icon in BookmarkFolderIcon.allCases {
            XCTAssertNotNil(
                NSImage(named: NSImage.Name(icon.resources.pickerAssetName)),
                "Missing picker asset for \(icon.rawValue)"
            )
            XCTAssertNotNil(
                Bundle.main.url(
                    forResource: icon.resources.animationResourceName,
                    withExtension: "json",
                    subdirectory: "LottieFiles/BookmarkFolderIcons"
                ),
                "Missing animation asset for \(icon.rawValue)"
            )
        }
    }

    func testEveryLottieUsesEnglishFolderAndSymbolNames() throws {
        for icon in BookmarkFolderIcon.allCases {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: icon.resources.animationResourceName,
                    withExtension: "json",
                    subdirectory: "LottieFiles/BookmarkFolderIcons"
                )
            )
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let names = lottieNames(in: object)

            XCTAssertTrue(names.contains("Folder1"), "Missing Folder1 in \(icon.rawValue)")
            XCTAssertTrue(names.contains("Folder2"), "Missing Folder2 in \(icon.rawValue)")
            if let symbolGroupName = icon.resources.symbolGroupName {
                XCTAssertTrue(names.contains(symbolGroupName), "Missing symbol group in \(icon.rawValue)")
            }
        }

        let animationURLs = try XCTUnwrap(
            Bundle.main.urls(
                forResourcesWithExtension: "json",
                subdirectory: "LottieFiles/BookmarkFolderIcons"
            )
        )
        for url in animationURLs {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let names = lottieNames(in: object)

            XCTAssertFalse(
                names.contains { $0.range(of: #"\p{Han}"#, options: .regularExpression) != nil },
                "Chinese Lottie property name remains in \(url.lastPathComponent)"
            )
        }
    }

    func testStoredIconFallsBackToDefault() {
        XCTAssertEqual(BookmarkFolderIcon.resolve(nil), .standard)
        XCTAssertEqual(BookmarkFolderIcon.resolve("unknown"), .standard)
        XCTAssertEqual(BookmarkFolderIcon.resolve("github"), .github)
    }

    func testFolderStateSelectsMatchingAnimationEndpoint() {
        XCTAssertEqual(BookmarkFolderIcon.animationProgress(isExpanded: false), 0)
        XCTAssertEqual(BookmarkFolderIcon.animationProgress(isExpanded: true), 1)
    }

    func testTabDataModelDefaultsToDefaultIcon() {
        let now = Date()
        let model = TabDataModel(
            title: "Folder",
            guid: "folder",
            index: 0,
            url: URL(string: "https://bookmark.phi/folder")!,
            favicon: nil,
            createdDate: now,
            updatedDate: now
        )

        XCTAssertEqual(model.icon, BookmarkFolderIcon.standard.rawValue)
    }

    func testVersionNineStoreMigratesWithDefaultIcon() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("LocalStore.sqlite")
        try createVersionNineStore(at: storeURL)

        let configuration = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: TabDataModel.self,
            ProfileModel.self,
            SpaceModel.self,
            SpaceURLRule.self,
            BrowserDataSettingsModel.self,
            migrationPlan: TabDataModelMigrationPlan.self,
            configurations: configuration
        )
        let models = try container.mainContext.fetch(FetchDescriptor<TabDataModel>())

        XCTAssertEqual(try XCTUnwrap(models.first).icon, BookmarkFolderIcon.standard.rawValue)
    }

    private func createVersionNineStore(at url: URL) throws {
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: TabDataModelSchemaV9.ProfileModel.self,
            TabDataModelSchemaV9.TabDataModel.self,
            TabDataModelSchemaV9.SpaceModel.self,
            TabDataModelSchemaV9.SpaceURLRule.self,
            TabDataModelSchemaV9.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let now = Date()
        let folder = TabDataModelSchemaV9.TabDataModel(
            title: "Legacy Folder",
            guid: "legacy-folder",
            index: 0,
            url: URL(string: "https://bookmark.phi/folder")!,
            favicon: nil,
            createdDate: now,
            updatedDate: now
        )
        folder.type = TabDataType.bookmarkFolder.rawValue
        container.mainContext.insert(folder)
        try container.mainContext.save()
    }

    private func lottieNames(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, child in
                (key == "nm" ? [child as? String].compactMap { $0 } : []) + lottieNames(in: child)
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { lottieNames(in: $0) }
        }
        return []
    }

}

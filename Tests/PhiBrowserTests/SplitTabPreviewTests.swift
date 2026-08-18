// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import class SwiftUI.NSHostingView
import XCTest
@testable import Phi

@MainActor
final class SplitTabPreviewTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testLiveSplitResolvesBothPanesAsOneTarget() throws {
        let (state, left, right) = try makeLiveSplit(layout: .vertical)
        var requestedIDs: [Int64] = []
        let resolver = SplitTabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }
        let leftTarget = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let rightTarget = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: right, in: state)
        )

        let content = try XCTUnwrap(resolver.resolve(leftTarget, in: state))

        XCTAssertEqual(leftTarget.logicalID, .live("split-10-11"))
        XCTAssertEqual(rightTarget.logicalID, leftTarget.logicalID)
        XCTAssertEqual(content.id, leftTarget.logicalID)
        XCTAssertEqual(content.layout, .vertical)
        XCTAssertEqual(content.leftPane.title, "Left page")
        XCTAssertEqual(content.rightPane.title, "Right page")
        XCTAssertEqual(content.leftPane.url, "https://left.example/path")
        XCTAssertEqual(content.rightPane.url, "https://right.example/path")
        XCTAssertNotNil(content.leftPane.image)
        XCTAssertNotNil(content.rightPane.image)
        XCTAssertEqual(requestedIDs, [10, 11])
    }

    func testHorizontalLayoutIsPreservedForFutureStackedRendering() throws {
        let (state, left, _) = try makeLiveSplit(layout: .horizontal)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let resolver = SplitTabPreviewContentResolver { _ in nil }

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(content.layout, .horizontal)
    }

    func testBackgroundSplitUsesBothThumbnails() throws {
        let (state, _, right) = try makeLiveSplit(layout: .vertical)
        var requestedIDs: [Int64] = []
        let resolver = SplitTabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: right, in: state)
        )

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(content.mode, .standard)
        XCTAssertNotNil(content.leftPane.image)
        XCTAssertEqual(content.leftPane.imageSource, .thumbnail(tabID: 10))
        XCTAssertNotNil(content.rightPane.image)
        XCTAssertEqual(content.rightPane.imageSource, .thumbnail(tabID: 11))
        XCTAssertEqual(requestedIDs, [10, 11])
    }

    func testActiveSplitUsesCompactTextOnlyPreviewFromEitherPane() throws {
        let (state, left, right) = try makeLiveSplit(layout: .vertical)
        state.focusingTab = left
        var requestedIDs: [Int64] = []
        let resolver = SplitTabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }
        let leftTarget = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let rightTarget = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: right, in: state)
        )

        let compactContent = try XCTUnwrap(resolver.resolve(leftTarget, in: state))
        let compactContentFromRightPane = try XCTUnwrap(
            resolver.resolve(rightTarget, in: state)
        )

        XCTAssertEqual(compactContent.mode, .compact)
        XCTAssertEqual(compactContentFromRightPane.mode, .compact)
        XCTAssertEqual(compactContent.leftPane.title, "Left page")
        XCTAssertEqual(compactContent.leftPane.url, "https://left.example/path")
        XCTAssertEqual(compactContent.rightPane.title, "Right page")
        XCTAssertEqual(compactContent.rightPane.url, "https://right.example/path")
        XCTAssertNil(compactContent.leftPane.image)
        XCTAssertNil(compactContent.rightPane.image)
        XCTAssertEqual(compactContent.leftPane.imageSource, .notRequested)
        XCTAssertEqual(compactContent.rightPane.imageSource, .notRequested)
        XCTAssertTrue(requestedIDs.isEmpty)

        state.focusingTab = nil
        let standardContent = try XCTUnwrap(resolver.resolve(leftTarget, in: state))

        XCTAssertEqual(standardContent.mode, .standard)
        XCTAssertGreaterThan(
            fittingSize(for: standardContent).height,
            fittingSize(for: compactContent).height + 80
        )
    }

    func testNewTabPageURLsAreHiddenAndTheirRowsCollapse() throws {
        let (state, left, right) = try makeLiveSplit(layout: .vertical)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let resolver = SplitTabPreviewContentResolver { _ in nil }
        let visibleContent = try XCTUnwrap(resolver.resolve(target, in: state))

        left.url = "chrome://newtab"
        right.url = "phi://newtab"
        let hiddenContent = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertTrue(hiddenContent.leftPane.url.isEmpty)
        XCTAssertTrue(hiddenContent.rightPane.url.isEmpty)
        XCTAssertLessThan(
            fittingSize(for: hiddenContent).height,
            fittingSize(for: visibleContent).height
        )
    }

    func testMetadataRefreshReusesBothPaneImages() throws {
        let (state, left, right) = try makeLiveSplit(layout: .vertical)
        var requestedIDs: [Int64] = []
        let resolver = SplitTabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let initial = try XCTUnwrap(resolver.resolve(target, in: state))
        left.title = "Updated left"
        right.title = "Updated right"

        let updated = try XCTUnwrap(
            resolver.resolve(target, in: state, reusing: initial)
        )

        XCTAssertEqual(updated.leftPane.title, "Updated left")
        XCTAssertEqual(updated.rightPane.title, "Updated right")
        XCTAssertEqual(requestedIDs, [10, 11])
    }

    func testTargetBecomesIneligibleWhenSplitDissolves() throws {
        let (state, left, _) = try makeLiveSplit(layout: .vertical)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let resolver = SplitTabPreviewContentResolver { _ in
            XCTFail("A dissolved split must not request thumbnails.")
            return nil
        }

        state.splits = []

        XCTAssertFalse(resolver.isEligible(target, in: state))
        XCTAssertNil(resolver.resolve(target, in: state))
    }

    func testClosedPinnedSplitResolvesPersistedPairWithoutThumbnailRequests() throws {
        let state = try makeBrowserState()
        let left = makeTab(
            guid: -1,
            title: "Pinned left",
            url: "https://pinned-left.example",
            persistentID: "pinned-left"
        )
        let right = makeTab(
            guid: -2,
            title: "Pinned right",
            url: "https://pinned-right.example",
            persistentID: "pinned-right"
        )
        left.isPinned = true
        right.isPinned = true
        left.isOpenned = false
        right.isOpenned = false
        left.splitPartnerGuid = "pinned-right"
        right.splitPartnerGuid = "pinned-left"
        state.pinnedTabs = [left, right]
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let resolver = SplitTabPreviewContentResolver { _ in
            XCTFail("Closed pinned panes have no Chromium thumbnails.")
            return nil
        }

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(target.logicalID, .persisted("pinned-left", "pinned-right"))
        XCTAssertEqual(content.mode, .compact)
        XCTAssertEqual(content.leftPane.title, "Pinned left")
        XCTAssertEqual(content.rightPane.title, "Pinned right")
        XCTAssertNil(content.leftPane.image)
        XCTAssertNil(content.rightPane.image)
        XCTAssertEqual(content.leftPane.imageSource, .notRequested)
        XCTAssertEqual(content.rightPane.imageSource, .notRequested)
    }

    func testClosedSplitBookmarkResolvesStoredPanesWithoutThumbnails() throws {
        let state = try makeBrowserState()
        let bookmark = Bookmark(
            guid: "split-bookmark",
            title: "Stored primary",
            url: "https://primary.example/path",
            secondaryUrl: "https://secondary.example/path"
        )
        let target = try XCTUnwrap(SplitTabPreviewTarget.make(representing: bookmark))
        let resolver = SplitTabPreviewContentResolver { _ in
            XCTFail("Closed split bookmarks have no Chromium thumbnails.")
            return nil
        }

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(target.logicalID, .bookmark("split-bookmark"))
        XCTAssertEqual(content.mode, .compact)
        XCTAssertEqual(content.layout, .vertical)
        XCTAssertEqual(content.leftPane.title, "Stored primary")
        XCTAssertEqual(content.leftPane.url, "https://primary.example/path")
        XCTAssertEqual(content.rightPane.title, "https://secondary.example/path")
        XCTAssertEqual(content.rightPane.url, "https://secondary.example/path")
        XCTAssertNil(content.leftPane.image)
        XCTAssertNil(content.rightPane.image)
        XCTAssertEqual(content.leftPane.imageSource, .notRequested)
        XCTAssertEqual(content.rightPane.imageSource, .notRequested)
    }

    func testOpenedSplitBookmarkUsesLivePaneMetadataAndThumbnails() throws {
        let state = try makeBrowserState()
        let bookmark = Bookmark(
            guid: "split-bookmark",
            title: "Stored primary",
            url: "https://primary.example",
            secondaryUrl: "https://secondary.example",
            secondaryTitle: "Stored secondary"
        )
        let primary = makeTab(
            guid: 20,
            title: "Live primary",
            url: "https://live-primary.example"
        )
        let secondary = makeTab(
            guid: 21,
            title: "Live secondary",
            url: "https://live-secondary.example"
        )
        state.tabs = [primary, secondary]
        state.splits = [
            SplitGroup(
                id: "opened-split-bookmark",
                primaryTabId: primary.guid,
                secondaryTabId: secondary.guid,
                layout: .horizontal,
                ratio: 0.5
            ),
        ]
        state.splitBookmarkBindings[bookmark.guid] = "opened-split-bookmark"
        var requestedIDs: [Int64] = []
        let resolver = SplitTabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }
        let target = try XCTUnwrap(SplitTabPreviewTarget.make(representing: bookmark))

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(content.layout, .horizontal)
        XCTAssertEqual(content.mode, .standard)
        XCTAssertEqual(content.leftPane.title, "Live primary")
        XCTAssertEqual(content.leftPane.url, "https://live-primary.example")
        XCTAssertEqual(content.rightPane.title, "Live secondary")
        XCTAssertEqual(content.rightPane.url, "https://live-secondary.example")
        XCTAssertEqual(requestedIDs, [20, 21])
    }

    func testActiveSplitBookmarkUsesCompactTextOnlyPreview() throws {
        let state = try makeBrowserState()
        let bookmark = Bookmark(
            guid: "split-bookmark",
            title: "Stored primary",
            url: "https://primary.example",
            secondaryUrl: "https://secondary.example"
        )
        let primary = makeTab(
            guid: 20,
            title: "Live primary",
            url: "https://live-primary.example"
        )
        let secondary = makeTab(
            guid: 21,
            title: "Live secondary",
            url: "https://live-secondary.example"
        )
        state.tabs = [primary, secondary]
        state.splits = [
            SplitGroup(
                id: "opened-split-bookmark",
                primaryTabId: primary.guid,
                secondaryTabId: secondary.guid,
                layout: .vertical,
                ratio: 0.5
            ),
        ]
        state.splitBookmarkBindings[bookmark.guid] = "opened-split-bookmark"
        state.focusingTab = secondary
        let resolver = SplitTabPreviewContentResolver { _ in
            XCTFail("The compact split bookmark preview must not request thumbnails.")
            return nil
        }
        let target = try XCTUnwrap(SplitTabPreviewTarget.make(representing: bookmark))

        let content = try XCTUnwrap(resolver.resolve(target, in: state))

        XCTAssertEqual(content.mode, .compact)
        XCTAssertEqual(content.leftPane.imageSource, .notRequested)
        XCTAssertEqual(content.rightPane.imageSource, .notRequested)
    }

    func testSplitPreviewIsWiderThanRegularPreview() throws {
        let (state, left, _) = try makeLiveSplit(layout: .vertical)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let content = try XCTUnwrap(
            SplitTabPreviewContentResolver { _ in nil }.resolve(target, in: state)
        )
        let viewModel = SplitTabPreviewViewModel()
        viewModel.update(content)
        let hostingView = NSHostingView(rootView: SplitTabPreviewView(viewModel: viewModel))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.fittingSize.width, 396, accuracy: 1)
        XCTAssertGreaterThan(hostingView.fittingSize.width, 280)
    }

    func testStandardSplitPreviewMatchesRegularPreviewHeight() throws {
        let (state, left, _) = try makeLiveSplit(layout: .vertical)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let imageData = makeImageData()
        let resolver = SplitTabPreviewContentResolver { _ in imageData }
        let splitContent = try XCTUnwrap(resolver.resolve(target, in: state))
        let regularImage = try XCTUnwrap(NSImage(data: imageData))

        let regularHeight = regularPreviewFittingSize(
            title: "Left page",
            url: "https://left.example/path",
            image: regularImage
        ).height

        XCTAssertEqual(splitContent.mode, .standard)
        XCTAssertEqual(fittingSize(for: splitContent).height, regularHeight, accuracy: 1)
    }

    func testSplitPreviewMetadataExpandsOnlyWhenTitleWraps() throws {
        let (state, left, _) = try makeLiveSplit(layout: .vertical)
        let target = try XCTUnwrap(
            SplitTabPreviewTarget.make(representing: left, in: state)
        )
        let resolver = SplitTabPreviewContentResolver { _ in nil }
        let singleLineContent = try XCTUnwrap(resolver.resolve(target, in: state))
        let singleLineHeight = fittingSize(for: singleLineContent).height

        left.title = "A title long enough to wrap over two lines in the split preview pane"
        let wrappedContent = try XCTUnwrap(resolver.resolve(target, in: state))
        let wrappedHeight = fittingSize(for: wrappedContent).height

        XCTAssertGreaterThan(wrappedHeight, singleLineHeight + 8)
    }

    func testSplitAndRegularPreviewsShareWindowPresentationController() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(
            window.tabPreviewController.presentationController
                === window.splitTabPreviewController.presentationController
        )
        XCTAssertTrue(
            window.splitTabPreviewController.presentationController
                === window.customTooltipController
        )
    }

    private func makeLiveSplit(
        layout: SplitLayout
    ) throws -> (BrowserState, Tab, Tab) {
        let state = try makeBrowserState()
        let left = makeTab(
            guid: 10,
            title: "Left page",
            url: "https://left.example/path"
        )
        let right = makeTab(
            guid: 11,
            title: "Right page",
            url: "https://right.example/path"
        )
        state.tabs = [left, right]
        state.normalTabs = [left, right]
        state.splits = [
            SplitGroup(
                id: "split-10-11",
                primaryTabId: 10,
                secondaryTabId: 11,
                layout: layout,
                ratio: 0.5
            ),
        ]
        return (state, left, right)
    }

    private func fittingSize(for content: SplitTabPreviewContent) -> CGSize {
        let viewModel = SplitTabPreviewViewModel()
        viewModel.update(content)
        let hostingView = NSHostingView(rootView: SplitTabPreviewView(viewModel: viewModel))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    private func regularPreviewFittingSize(
        title: String,
        url: String,
        image: NSImage
    ) -> CGSize {
        let viewModel = TabPreviewViewModel()
        viewModel.update(
            TabPreviewContent(
                id: .tab("regular-preview"),
                title: title,
                url: url,
                image: image,
                imageSource: .thumbnail(tabID: 1)
            )
        )
        let hostingView = NSHostingView(rootView: TabPreviewView(viewModel: viewModel))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory
        )
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func makeTab(
        guid: Int,
        title: String,
        url: String,
        persistentID: String? = nil
    ) -> Tab {
        Tab(
            guid: guid,
            url: url,
            isActive: false,
            index: 0,
            title: title,
            customGuid: persistentID,
            windowId: 7
        )
    }

    private func makeImageData() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            XCTFail("Failed to create test JPEG data.")
            return Data()
        }
        return data
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class BrowserStatePinnedTabScopeVariantSyncTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testSpaceToProfileRebindsLiveRuntimeTabToItsContentMatchingVariant() async throws {
        let store = try makeStore()
        let profile = try seedProfileAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "profile-pin",
            lineageId: "shared-lineage",
            profile: profile,
            title: "Seed",
            url: "https://seed.example"
        )

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()

        let spaceAModel = try pinnedModel(
            in: store,
            spaceId: "space-a",
            lineageId: "shared-lineage"
        )
        let spaceBModel = try pinnedModel(
            in: store,
            spaceId: "space-b",
            lineageId: "shared-lineage"
        )
        try await updateVariant(
            spaceAModel,
            in: store,
            title: "Space A",
            url: "https://space-a.example"
        )
        try await updateVariant(
            spaceBModel,
            in: store,
            title: "Space B",
            url: "https://space-b.example"
        )

        let stateA = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let stateB = BrowserState(
            windowId: 2,
            localStore: store,
            profileId: "Default",
            spaceId: "space-b"
        )
        let runtimeA = try XCTUnwrap(stateA.pinnedTabs.first)
        let runtimeB = try XCTUnwrap(stateB.pinnedTabs.first)
        let oldGuidA = try XCTUnwrap(runtimeA.guidInLocalDB)
        let oldGuidB = try XCTUnwrap(runtimeB.guidInLocalDB)
        let bindingA = bindLiveTab(runtimeA, to: stateA, chromiumGuid: 101)
        let bindingB = bindLiveTab(runtimeB, to: stateB, chromiumGuid: 201)

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try waitUntil(describing: "both Space windows receive the merged profile rows") {
            stateA.pinnedTabs.count == 2 &&
                stateB.pinnedTabs.count == 2 &&
                runtimeA.guidInLocalDB != oldGuidA &&
                runtimeB.guidInLocalDB != oldGuidB
        }

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(
            merged.map { $0.url.absoluteString },
            ["https://space-a.example", "https://space-b.example"]
        )
        let targetA = try model(in: merged, url: "https://space-a.example")
        let targetB = try model(in: merged, url: "https://space-b.example")

        XCTAssertTrue(stateA.pinnedTabs.first(where: { $0.guidInLocalDB == targetA.guid }) === runtimeA)
        XCTAssertTrue(stateB.pinnedTabs.first(where: { $0.guidInLocalDB == targetB.guid }) === runtimeB)
        XCTAssertEqual(runtimeA.pinnedUrl, "https://space-a.example")
        XCTAssertEqual(runtimeB.pinnedUrl, "https://space-b.example")
        XCTAssertEqual(runtimeA.storedTitle, "Space A")
        XCTAssertEqual(runtimeB.storedTitle, "Space B")
        XCTAssertEqual(bindingA.liveTab.guidInLocalDB, targetA.guid)
        XCTAssertEqual(bindingB.liveTab.guidInLocalDB, targetB.guid)
        XCTAssertTrue(bindingA.wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(bindingB.wrapper.navigatedURLs.isEmpty)
    }

    func testSpaceToProfileRebindsLiveSplitPanesToTheirContentMatchingPairVariant() async throws {
        let store = try makeStore()
        let profile = try seedProfileAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "left-pin",
            lineageId: "left-lineage",
            profile: profile,
            title: "Left Seed",
            url: "https://seed.example/left",
            index: 0,
            splitPartnerGuid: "right-pin"
        )
        try insertPinnedTab(
            in: store,
            guid: "right-pin",
            lineageId: "right-lineage",
            profile: profile,
            title: "Right Seed",
            url: "https://seed.example/right",
            index: 1,
            splitPartnerGuid: "left-pin"
        )

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()

        let spaceALeft = try pinnedModel(
            in: store,
            spaceId: "space-a",
            lineageId: "left-lineage"
        )
        let spaceARight = try pinnedModel(
            in: store,
            spaceId: "space-a",
            lineageId: "right-lineage"
        )
        let spaceBLeft = try pinnedModel(
            in: store,
            spaceId: "space-b",
            lineageId: "left-lineage"
        )
        let spaceBRight = try pinnedModel(
            in: store,
            spaceId: "space-b",
            lineageId: "right-lineage"
        )
        try await updateVariant(
            spaceALeft,
            in: store,
            title: "Shared Left",
            url: "https://shared.example/left"
        )
        try await updateVariant(
            spaceARight,
            in: store,
            title: "Space A Right",
            url: "https://space-a.example/right"
        )
        try await updateVariant(
            spaceBLeft,
            in: store,
            title: "Shared Left",
            url: "https://shared.example/left"
        )
        try await updateVariant(
            spaceBRight,
            in: store,
            title: "Space B Right",
            url: "https://space-b.example/right"
        )

        let stateA = BrowserState(
            windowId: 3,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let stateB = BrowserState(
            windowId: 4,
            localStore: store,
            profileId: "Default",
            spaceId: "space-b"
        )
        let runtimeALeft = try runtimeTab(in: stateA, lineageId: "left-lineage")
        let runtimeARight = try runtimeTab(in: stateA, lineageId: "right-lineage")
        let runtimeBLeft = try runtimeTab(in: stateB, lineageId: "left-lineage")
        let runtimeBRight = try runtimeTab(in: stateB, lineageId: "right-lineage")
        let oldGuids = [runtimeALeft, runtimeARight, runtimeBLeft, runtimeBRight]
            .compactMap(\.guidInLocalDB)
        XCTAssertEqual(oldGuids.count, 4)

        let bindingALeft = bindLiveTab(runtimeALeft, to: stateA, chromiumGuid: 301)
        let bindingARight = bindLiveTab(runtimeARight, to: stateA, chromiumGuid: 302)
        let bindingBLeft = bindLiveTab(runtimeBLeft, to: stateB, chromiumGuid: 401)
        let bindingBRight = bindLiveTab(runtimeBRight, to: stateB, chromiumGuid: 402)

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try waitUntil(describing: "both Space windows receive both merged split variants") {
            stateA.pinnedTabs.count == 4 &&
                stateB.pinnedTabs.count == 4 &&
                [runtimeALeft, runtimeARight, runtimeBLeft, runtimeBRight].allSatisfy {
                    guard let guid = $0.guidInLocalDB else { return false }
                    return !oldGuids.contains(guid)
                }
        }

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(
            merged.map { $0.url.absoluteString },
            [
                "https://shared.example/left",
                "https://space-a.example/right",
                "https://shared.example/left",
                "https://space-b.example/right"
            ]
        )
        let targetARight = try model(in: merged, url: "https://space-a.example/right")
        let targetBRight = try model(in: merged, url: "https://space-b.example/right")
        let targetALeft = try XCTUnwrap(
            merged.first(where: { $0.splitPartnerGuid == targetARight.guid })
        )
        let targetBLeft = try XCTUnwrap(
            merged.first(where: { $0.splitPartnerGuid == targetBRight.guid })
        )

        assertRuntimeTab(
            runtimeALeft,
            is: targetALeft,
            in: stateA,
            liveBinding: bindingALeft
        )
        assertRuntimeTab(
            runtimeARight,
            is: targetARight,
            in: stateA,
            liveBinding: bindingARight
        )
        assertRuntimeTab(
            runtimeBLeft,
            is: targetBLeft,
            in: stateB,
            liveBinding: bindingBLeft
        )
        assertRuntimeTab(
            runtimeBRight,
            is: targetBRight,
            in: stateB,
            liveBinding: bindingBRight
        )
        XCTAssertEqual(targetALeft.splitPartnerGuid, targetARight.guid)
        XCTAssertEqual(targetARight.splitPartnerGuid, targetALeft.guid)
        XCTAssertEqual(targetBLeft.splitPartnerGuid, targetBRight.guid)
        XCTAssertEqual(targetBRight.splitPartnerGuid, targetBLeft.guid)
    }

    private struct LiveBinding {
        let liveTab: Tab
        let wrapper: PinnedScopeVariantWebContentWrapperSpy
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
    }

    private func seedProfileAndSpaces(in store: LocalStore) throws -> ProfileModel {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        context.insert(SpaceModel(
            spaceId: "space-b",
            profileId: "Default",
            name: "B",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 1
        ))
        try context.save()
        return profile
    }

    private func insertPinnedTab(
        in store: LocalStore,
        guid: String,
        lineageId: String,
        profile: ProfileModel,
        title: String,
        url: String,
        index: Int = 0,
        splitPartnerGuid: String? = nil
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        model.dataType = .pinnedTab
        model.profile = profile
        model.profileId = profile.profileId
        model.pinLineageId = lineageId
        model.splitPartnerGuid = splitPartnerGuid
        context.insert(model)
        try context.save()
    }

    private func pinnedModel(
        in store: LocalStore,
        spaceId: String,
        lineageId: String
    ) throws -> TabDataModel {
        try XCTUnwrap(
            store.getAllPinnedTabs(for: "Default", spaceId: spaceId)
                .first(where: { $0.pinLineageId == lineageId })
        )
    }

    private func model(in models: [TabDataModel], url: String) throws -> TabDataModel {
        try XCTUnwrap(models.first(where: { $0.url.absoluteString == url }))
    }

    private func runtimeTab(in state: BrowserState, lineageId: String) throws -> Tab {
        try XCTUnwrap(state.pinnedTabs.first(where: { $0.pinnedLineageId == lineageId }))
    }

    private func updateVariant(
        _ model: TabDataModel,
        in store: LocalStore,
        title: String,
        url: String
    ) async throws {
        store.updateTabURL(model.guid, url: try XCTUnwrap(URL(string: url)))
        store.updateTabTitle(model.guid, title: title)
        await store.performBackgroundWriteAndWait { _ in }
        drainMainQueue()
    }

    private func bindLiveTab(
        _ runtimeTab: Tab,
        to state: BrowserState,
        chromiumGuid: Int
    ) -> LiveBinding {
        let wrapper = PinnedScopeVariantWebContentWrapperSpy(
            urlString: runtimeTab.pinnedUrl ?? runtimeTab.url,
            title: runtimeTab.storedTitle
        )
        let liveTab = Tab(
            guid: chromiumGuid,
            url: runtimeTab.pinnedUrl ?? runtimeTab.url,
            isActive: false,
            index: state.tabs.count,
            title: runtimeTab.storedTitle,
            webContentView: wrapper,
            customGuid: runtimeTab.guidInLocalDB
        )
        liveTab.isPinned = true
        liveTab.pinnedLineageId = runtimeTab.pinnedLineageId
        state.tabs.append(liveTab)
        runtimeTab.isOpenned = true
        runtimeTab.guid = liveTab.guid
        runtimeTab.setWebContentsWrapper(wrapper: wrapper)
        return LiveBinding(liveTab: liveTab, wrapper: wrapper)
    }

    private func assertRuntimeTab(
        _ runtimeTab: Tab,
        is target: TabDataModel,
        in state: BrowserState,
        liveBinding: LiveBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            state.pinnedTabs.first(where: { $0.guidInLocalDB == target.guid }) === runtimeTab,
            file: file,
            line: line
        )
        XCTAssertEqual(runtimeTab.guidInLocalDB, target.guid, file: file, line: line)
        XCTAssertEqual(runtimeTab.pinnedUrl, target.url.absoluteString, file: file, line: line)
        XCTAssertEqual(runtimeTab.storedTitle, target.title, file: file, line: line)
        XCTAssertEqual(runtimeTab.splitPartnerGuid, target.splitPartnerGuid, file: file, line: line)
        XCTAssertEqual(liveBinding.liveTab.guidInLocalDB, target.guid, file: file, line: line)
        XCTAssertTrue(liveBinding.wrapper.navigatedURLs.isEmpty, file: file, line: line)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitUntil(
        describing expectation: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for: \(expectation)")
    }
}

private final class PinnedScopeVariantWebContentWrapperSpy: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false
    @objc dynamic var isDiscarded = false
    @objc dynamic var isUnloaded = false
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String? = nil

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    private(set) var navigatedURLs: [String] = []
    private(set) var customValues: [String] = []

    init(urlString: String?, title: String?) {
        self.urlString = urlString
        self.title = title
        super.init()
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) {
        navigatedURLs.append(urlString)
        self.urlString = urlString
    }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) { customValues.append(customValue) }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

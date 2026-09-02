// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class PhiScriptingServiceTests: XCTestCase {
    private final class Recorder {
        var calls: [String] = []
    }

    func testJSONSerializationPreservesUnicodeQuotesBackslashesAndMissingURL() throws {
        let longTitle = String(repeating: "中文 \\\" \\\\ ", count: 1_024)
        let tab = PhiScriptingTabSnapshot(
            id: "1",
            windowId: "2",
            spaceId: "space",
            title: longTitle,
            url: nil,
            isActive: true,
            isPinned: false
        )
        let json = PhiScriptingJSON.string(from: [
            "schemaVersion": 1,
            "ok": true,
            "tabs": [tab.jsonObject],
        ])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tabs = try XCTUnwrap(object["tabs"] as? [[String: Any]])

        XCTAssertEqual(tabs.first?["title"] as? String, longTitle)
        XCTAssertTrue(tabs.first?["url"] is NSNull)
    }

    func testJSONSerializationRebrandsChromeURLsForAllReturnedTabTypes() throws {
        let openedTab = PhiScriptingTabSnapshot(
            id: "tab",
            windowId: "window",
            spaceId: "space",
            title: "Settings",
            url: "chrome://settings/privacy?source=raycast",
            isActive: false,
            isPinned: false
        )
        let pinnedTab = PhiScriptingPinnedTabSnapshot(
            id: "pin",
            scope: .space,
            ownerSpaceId: "space",
            spaceIds: ["space"],
            title: "Downloads",
            url: "chrome://downloads",
            secondary: PhiScriptingSavedPaneSnapshot(
                id: "pin-secondary",
                title: "History",
                url: "chrome://history"
            )
        )
        let bookmark = PhiScriptingBookmarkSnapshot(
            id: "bookmark",
            spaceId: "space",
            title: "Example",
            url: "https://example.com",
            secondary: PhiScriptingSavedPaneSnapshot(
                id: "bookmark-secondary",
                title: "Bookmarks",
                url: "phi://bookmarks"
            )
        )

        XCTAssertEqual(openedTab.jsonObject["url"] as? String, "phi://settings/privacy?source=raycast")
        XCTAssertEqual(pinnedTab.jsonObject["url"] as? String, "phi://downloads")
        XCTAssertEqual(
            (pinnedTab.jsonObject["secondary"] as? [String: Any])?["url"] as? String,
            "phi://history"
        )
        XCTAssertEqual(bookmark.jsonObject["url"] as? String, "https://example.com")
        XCTAssertEqual(
            (bookmark.jsonObject["secondary"] as? [String: Any])?["url"] as? String,
            "phi://bookmarks"
        )
    }

    func testJSONSerializationReturnsVersionedFailureForUnsupportedValues() throws {
        let json = PhiScriptingJSON.string(from: ["unsupported": Date()])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "serialization_failed")
    }

    func testListSpacesAndActiveSpacePreserveProfileAndOpenState() throws {
        let service = makeService(recorder: Recorder())
        let response = service.listSpaces()
        let spaces = try XCTUnwrap(response["spaces"] as? [[String: Any]])

        XCTAssertEqual(spaces.count, 2)
        XCTAssertEqual(spaces[0]["profileName"] as? String, "Personal")
        XCTAssertEqual(spaces[0]["colorHex"] as? String, "#112233")
        XCTAssertEqual(spaces[0]["iconData"] as? String, "aWNvbi1h")
        XCTAssertEqual(spaces[0]["isOpen"] as? Bool, true)
        XCTAssertEqual(spaces[1]["isActive"] as? Bool, true)

        let active = service.getActiveSpace()
        let activeSpace = try XCTUnwrap(active["space"] as? [String: Any])
        XCTAssertEqual(activeSpace["id"] as? String, "space-b")
        XCTAssertEqual(activeSpace["profileId"] as? String, "Profile 1")
    }

    func testSpaceIconDataIsTwentyPointRetinaPNG() throws {
        let encoded = try XCTUnwrap(
            PhiScriptingService.spaceIconData(for: "rectangle.stack")
        )
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(bitmap.pixelsWide, 40)
        XCTAssertEqual(bitmap.pixelsHigh, 40)
    }

    func testListTabsScopesAllCurrentAndSpaceWithoutChangingRouting() throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let all = service.listTabs(scope: .all)
        let current = service.listTabs(scope: .current)
        let space = service.listTabs(scope: .space("space-b"))

        XCTAssertEqual(tabIds(in: all), ["11", "22"])
        XCTAssertEqual(tabIds(in: current), ["22"])
        XCTAssertEqual(tabIds(in: space), ["22"])
        XCTAssertEqual(pinnedTabIds(in: all), ["pin-shared"])
        XCTAssertEqual(pinnedTabIds(in: current), ["pin-shared"])
        XCTAssertEqual(pinnedTabIds(in: space), ["pin-shared"])
        XCTAssertEqual(bookmarkIds(in: all), ["bookmark-a", "bookmark-b"])
        XCTAssertEqual(bookmarkIds(in: current), ["bookmark-b"])
        XCTAssertEqual(bookmarkIds(in: space), ["bookmark-b"])
        XCTAssertTrue(all["targetSpaceId"] is NSNull)
        XCTAssertEqual(current["targetSpaceId"] as? String, "space-b")
        XCTAssertEqual(space["targetSpaceId"] as? String, "space-b")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testSavedItemQueriesUseTheRequestedSpaceBoundary() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        var requestedSpaceIds: [String?] = []
        dependencies.savedItems = { targetSpaceId in
            requestedSpaceIds.append(targetSpaceId)
            return self.savedItems(
                from: self.makeSnapshot(),
                targetSpaceId: targetSpaceId
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)

        _ = service.listTabs(scope: .all)
        _ = service.listTabs(scope: .current)
        _ = service.listTabs(scope: .space("space-a"))
        _ = service.openPinnedTab(
            spaceId: "space-a",
            pinnedTabId: "pin-shared"
        )
        _ = service.openBookmark(
            spaceId: "space-b",
            bookmarkId: "bookmark-b"
        )

        XCTAssertEqual(
            requestedSpaceIds,
            [nil, "space-b", "space-a", "space-a", "space-b"]
        )
    }

    func testCurrentScopeIncludesEveryOpenWindowForTheActiveSpace() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            let snapshot = self.makeSnapshot()
            let extraTab = PhiScriptingTabSnapshot(
                id: "33",
                windowId: "300",
                spaceId: "space-b",
                title: "Third",
                url: "https://third.example",
                isActive: false,
                isPinned: false
            )
            return PhiScriptingSnapshot(
                spaces: snapshot.spaces,
                windows: snapshot.windows + [
                    PhiScriptingWindowSnapshot(
                        id: "300",
                        spaceId: "space-b",
                        tabs: [extraTab]
                    ),
                ],
                pinnedTabs: snapshot.pinnedTabs,
                bookmarks: snapshot.bookmarks,
                activeWindowId: snapshot.activeWindowId
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)

        XCTAssertEqual(
            tabIds(in: service.listTabs(scope: .current)),
            ["22", "33"]
        )
    }

    func testTabMutationRequiresMatchingWindowAndTabPair() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let stale = service.closeTab(windowId: "100", tabId: "22")
        let valid = service.closeTab(windowId: "200", tabId: "22")

        XCTAssertEqual(errorCode(in: stale), "tab_not_found")
        XCTAssertEqual(valid["ok"] as? Bool, true)
        XCTAssertEqual(recorder.calls, ["close:200:22"])
    }

    func testPageAndSplitActionsRouteMatchingWindowAndTabPair() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let forceReload = service.forceReloadTab(windowId: "200", tabId: "22")
        let addSplit = service.addSplitView(windowId: "200", tabId: "22")

        XCTAssertEqual(forceReload["ok"] as? Bool, true)
        XCTAssertEqual(forceReload["outcome"] as? String, "completed")
        XCTAssertEqual(addSplit["ok"] as? Bool, true)
        XCTAssertEqual(addSplit["outcome"] as? String, "completed")
        XCTAssertEqual(recorder.calls, [
            "force-reload:200:22",
            "add-split:200:22",
        ])
    }

    func testSavedItemActionsRequireMatchingSpaceAndOpaqueIdentifier() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let stalePin = service.openPinnedTab(
            spaceId: "space-a",
            pinnedTabId: "missing"
        )
        let staleBookmark = service.openBookmark(
            spaceId: "space-b",
            bookmarkId: "bookmark-a"
        )
        let pin = service.openPinnedTab(
            spaceId: "space-a",
            pinnedTabId: "pin-shared"
        )
        let bookmark = service.openBookmark(
            spaceId: "space-a",
            bookmarkId: "bookmark-a"
        )

        XCTAssertEqual(errorCode(in: stalePin), "tab_not_found")
        XCTAssertEqual(errorCode(in: staleBookmark), "tab_not_found")
        XCTAssertEqual(pin["ok"] as? Bool, true)
        XCTAssertEqual(bookmark["ok"] as? Bool, true)
        XCTAssertEqual(recorder.calls, [
            "open-pin:space-a:pin-shared",
            "open-bookmark:space-a:bookmark-a",
        ])
    }

    func testClosedSpaceReturnsSuccessfulEmptyTabList() throws {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            let snapshot = self.makeSnapshot()
            let closedSpace = PhiScriptingSpaceSnapshot(
                id: "space-closed",
                title: "Closed",
                profileId: "Default",
                profileName: "Personal",
                colorHex: "#778899",
                iconData: nil,
                isActive: false,
                isOpen: false
            )
            return PhiScriptingSnapshot(
                spaces: snapshot.spaces + [closedSpace],
                windows: snapshot.windows,
                pinnedTabs: [
                    PhiScriptingPinnedTabSnapshot(
                        id: "pin-closed",
                        scope: .space,
                        ownerSpaceId: "space-closed",
                        spaceIds: ["space-closed"],
                        title: "Closed Pin",
                        url: "https://pin-closed.example",
                        secondary: nil
                    ),
                ],
                bookmarks: [
                    PhiScriptingBookmarkSnapshot(
                        id: "bookmark-closed",
                        spaceId: "space-closed",
                        title: "Closed Bookmark",
                        url: "https://bookmark-closed.example",
                        secondary: nil
                    ),
                ],
                activeWindowId: snapshot.activeWindowId
            )
        }
        let closedSnapshot = dependencies.snapshot
        dependencies.savedItems = { targetSpaceId in
            let snapshot = closedSnapshot()
            return self.savedItems(
                from: snapshot,
                targetSpaceId: targetSpaceId
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)
        let response = service.listTabs(scope: .space("space-closed"))

        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(response["tabs"] as? [[String: Any]]).count, 0)
        XCTAssertEqual(pinnedTabIds(in: response), ["pin-closed"])
        XCTAssertEqual(bookmarkIds(in: response), ["bookmark-closed"])
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testActivationAndOpenTabRouteOpaqueIdentifiersUnchanged() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        _ = service.activateSpace(spaceId: "space-b")
        _ = service.activateTab(windowId: "200", tabId: "22")
        _ = service.openTab(address: "quoted \"query\" \\ value", spaceId: "space-a")

        XCTAssertEqual(recorder.calls, [
            "space:space-b",
            "activate:200:22",
            "open:quoted \"query\" \\ value:space-a",
        ])
    }

    func testWindowAndSpaceCommandsRouteAllCreationRequests() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let normal = service.newWindow()
        let incognito = service.newIncognitoWindow()
        let kiosk = service.newKioskWindow(url: " https://example.com/path ")
        let aboutKiosk = service.newKioskWindow(url: "about:blank")
        let fileKiosk = service.newKioskWindow(url: "file:///tmp/example.html")
        let internalKiosk = service.newKioskWindow(url: "phi://version")
        let domainKiosk = service.newKioskWindow(url: "google.com")
        let searchKiosk = service.newKioskWindow(url: "kiosk browser")
        let omittedURLKiosk = service.newKioskWindow(url: nil)
        let blankURLKiosk = service.newKioskWindow(url: " \n ")
        let incognitoSpace = service.newIncognitoSpace()

        XCTAssertEqual(normal["ok"] as? Bool, true)
        XCTAssertEqual(incognito["ok"] as? Bool, true)
        XCTAssertEqual(kiosk["ok"] as? Bool, true)
        XCTAssertEqual(kiosk["outcome"] as? String, "completed")
        XCTAssertEqual(aboutKiosk["ok"] as? Bool, true)
        XCTAssertEqual(fileKiosk["ok"] as? Bool, true)
        XCTAssertEqual(internalKiosk["ok"] as? Bool, true)
        XCTAssertEqual(domainKiosk["ok"] as? Bool, true)
        XCTAssertEqual(searchKiosk["ok"] as? Bool, true)
        XCTAssertEqual(omittedURLKiosk["ok"] as? Bool, true)
        XCTAssertEqual(blankURLKiosk["ok"] as? Bool, true)
        XCTAssertEqual(incognitoSpace["ok"] as? Bool, true)
        XCTAssertEqual(incognitoSpace["outcome"] as? String, "accepted")
        XCTAssertEqual(recorder.calls, [
            "window:normal",
            "window:incognito",
            "kiosk:https://example.com/path",
            "kiosk:about:blank",
            "kiosk:file:///tmp/example.html",
            "kiosk:chrome://version",
            "kiosk:https://google.com",
            "kiosk:https://www.google.com/search?q=kiosk browser",
            "kiosk:about:blank",
            "kiosk:about:blank",
            "incognito-space",
        ])
    }

    func testIncognitoSpaceCreationIsBlockedWhileLazyRestoreDropsActivations() {
        XCTAssertFalse(PhiScriptingService.shouldBlockIncognitoSpaceCreation(
            isSessionRestoreInFlight: true,
            isLazyReopenArmed: false
        ))
        XCTAssertFalse(PhiScriptingService.shouldBlockIncognitoSpaceCreation(
            isSessionRestoreInFlight: false,
            isLazyReopenArmed: true
        ))
        XCTAssertTrue(PhiScriptingService.shouldBlockIncognitoSpaceCreation(
            isSessionRestoreInFlight: true,
            isLazyReopenArmed: true
        ))
    }

    func testInvalidScopeAndStaleSpaceReturnStableErrorCodes() throws {
        XCTAssertThrowsError(try PhiScriptingTabScope(scope: "space", spaceId: nil))
        XCTAssertThrowsError(try PhiScriptingTabScope(scope: "unexpected", spaceId: nil))

        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let list = service.listTabs(scope: .space("missing"))
        let activate = service.activateSpace(spaceId: "missing")

        XCTAssertEqual(errorCode(in: list), "space_not_found")
        XCTAssertEqual(errorCode(in: activate), "space_not_found")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testBlankArgumentsReturnInvalidArgumentWithoutInvokingDependencies() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let responses = [
            service.activateSpace(spaceId: " \n "),
            service.activateTab(windowId: nil, tabId: "22"),
            service.closeTab(windowId: "100", tabId: "\t"),
            service.reloadTab(windowId: "", tabId: "11"),
            service.forceReloadTab(windowId: "100", tabId: " "),
            service.addSplitView(windowId: nil, tabId: "11"),
            service.openPinnedTab(spaceId: "space-a", pinnedTabId: " "),
            service.openBookmark(spaceId: nil, bookmarkId: "bookmark-a"),
            service.openTab(address: " \n", spaceId: "space-a"),
        ]

        XCTAssertEqual(responses.compactMap(errorCode), Array(repeating: "invalid_argument", count: responses.count))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testDependencyFailuresReturnOperationFailedForEveryMutation() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.activateSpace = { _ in .failed }
        dependencies.activateTab = { _, _ in .failed }
        dependencies.closeTab = { _, _ in .failed }
        dependencies.reloadTab = { _, _ in .failed }
        dependencies.forceReloadTab = { _, _ in .failed }
        dependencies.addSplitView = { _, _ in .failed }
        dependencies.openPinnedTab = { _, _ in .failed }
        dependencies.openBookmark = { _, _ in .failed }
        dependencies.openTab = { _, _ in .failed }
        dependencies.createWindow = { _ in .failed }
        dependencies.createKioskWindow = { _ in .failed }
        dependencies.createIncognitoSpace = { .failed }
        let service = PhiScriptingService(dependencies: dependencies)
        let responses = [
            service.activateSpace(spaceId: "space-a"),
            service.activateTab(windowId: "100", tabId: "11"),
            service.closeTab(windowId: "100", tabId: "11"),
            service.reloadTab(windowId: "100", tabId: "11"),
            service.forceReloadTab(windowId: "100", tabId: "11"),
            service.addSplitView(windowId: "100", tabId: "11"),
            service.openPinnedTab(spaceId: "space-a", pinnedTabId: "pin-shared"),
            service.openBookmark(spaceId: "space-a", bookmarkId: "bookmark-a"),
            service.openTab(address: "https://example.com", spaceId: "space-a"),
            service.newWindow(),
            service.newIncognitoWindow(),
            service.newKioskWindow(url: nil),
            service.newIncognitoSpace(),
        ]

        XCTAssertEqual(responses.compactMap(errorCode), Array(repeating: "operation_failed", count: responses.count))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testNoWindowAndNoActiveWindowAreDistinct() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            PhiScriptingSnapshot(
                spaces: self.makeSnapshot().spaces,
                windows: [],
                activeWindowId: nil
            )
        }
        let noWindowService = PhiScriptingService(dependencies: dependencies)
        let allWithoutWindows = noWindowService.listTabs(scope: .all)
        XCTAssertEqual(allWithoutWindows["ok"] as? Bool, true)
        XCTAssertEqual(tabIds(in: allWithoutWindows), [])
        XCTAssertEqual(errorCode(in: noWindowService.activateSpace(spaceId: "space-a")), "no_windows")

        dependencies.snapshot = {
            let snapshot = self.makeSnapshot()
            return PhiScriptingSnapshot(
                spaces: snapshot.spaces,
                windows: snapshot.windows,
                activeWindowId: nil
            )
        }
        let noActiveService = PhiScriptingService(dependencies: dependencies)
        XCTAssertEqual(errorCode(in: noActiveService.listTabs(scope: .current)), "no_active_window")
    }

    func testOpenTabDelegatesWhenNoBrowserWindowIsOpen() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            PhiScriptingSnapshot(
                spaces: self.makeSnapshot().spaces,
                windows: [],
                activeWindowId: nil
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)

        let response = service.openTab(
            address: "https://example.com/history",
            spaceId: nil
        )

        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["outcome"] as? String, "completed")
        XCTAssertEqual(recorder.calls, ["open:https://example.com/history:current"])
    }

    func testActiveSpaceUsesTheActiveWindowInsteadOfAStaleSpaceFlag() throws {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            let snapshot = self.makeSnapshot()
            return PhiScriptingSnapshot(
                spaces: snapshot.spaces.map {
                    PhiScriptingSpaceSnapshot(
                        id: $0.id,
                        title: $0.title,
                        profileId: $0.profileId,
                        profileName: $0.profileName,
                        colorHex: $0.colorHex,
                        iconData: $0.iconData,
                        isActive: $0.id == "space-a",
                        isOpen: $0.isOpen
                    )
                },
                windows: snapshot.windows,
                activeWindowId: snapshot.activeWindowId
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)
        let response = service.getActiveSpace()
        let activeSpace = try XCTUnwrap(response["space"] as? [String: Any])

        XCTAssertEqual(activeSpace["id"] as? String, "space-b")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testActiveSpaceReturnsNoActiveWindowWhenNoEligibleWindowIsFocused() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.snapshot = {
            let snapshot = self.makeSnapshot()
            return PhiScriptingSnapshot(
                spaces: snapshot.spaces,
                windows: snapshot.windows,
                activeWindowId: nil
            )
        }
        let service = PhiScriptingService(dependencies: dependencies)

        XCTAssertEqual(errorCode(in: service.getActiveSpace()), "no_active_window")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testSavedItemRoutingPrefersTheFocusedSlot() {
        XCTAssertEqual(
            PhiScriptingSlotRouting.preferredSlot(
                focusedSlot: "focused",
                slots: ["target-host", "focused"],
                containsTargetSpace: { $0 == "target-host" }
            ),
            "focused"
        )
        XCTAssertEqual(
            PhiScriptingSlotRouting.preferredSlot(
                focusedSlot: nil,
                slots: ["other", "target-host"],
                containsTargetSpace: { $0 == "target-host" }
            ),
            "target-host"
        )
    }

    func testAcceptedMutationIsNotReportedAsCompleted() {
        let recorder = Recorder()
        var dependencies = makeDependencies(recorder: recorder)
        dependencies.activateSpace = { _ in .accepted }
        let service = PhiScriptingService(dependencies: dependencies)

        let response = service.activateSpace(spaceId: "space-a")

        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["outcome"] as? String, "accepted")
    }

    func testVersionResponseIncludesAPIVersionAndBundleValues() {
        let service = makeService(recorder: Recorder())
        let response = service.getVersion()

        XCTAssertEqual(response["apiVersion"] as? Int, 2)
        XCTAssertEqual(response["version"] as? String, "1.2.3")
        XCTAssertEqual(response["build"] as? String, "456")
    }

    func testChromiumDataDirectoryResponseUsesTheCurrentApplicationPath() {
        let service = makeService(recorder: Recorder())
        let response = service.getChromiumDataDirectory()

        XCTAssertEqual(response["schemaVersion"] as? Int, 1)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(
            response["chromiumDataDirectory"] as? String,
            "/Users/test/Library/Application Support/com.phibrowser.Mac"
        )
    }

    func testRaycastClientContextProducesPrivacyMinimalAttributionProperties() throws {
        let invocationId = "34A33E4B-B86E-4077-9C4A-A08BCF876472"
        let rawContext = """
        {
          "schemaVersion": 1,
          "clientId": "raycast",
          "clientCommand": "search-tabs",
          "clientAction": "activate-tab",
          "invocationId": "\(invocationId)"
        }
        """

        let context = try XCTUnwrap(PhiScriptingClientContext.parse(rawContext))
        XCTAssertEqual(context.clientCommand, "search-tabs")
        XCTAssertEqual(context.clientAction, "activate-tab")
        XCTAssertEqual(context.invocationId, invocationId.lowercased())

        let properties = PhiScriptingAnalytics.properties(
            clientContext: rawContext,
            scriptingCommand: "activate_tab",
            succeeded: true,
            operationOutcome: .accepted
        )
        XCTAssertEqual(properties["source_client"] as? String, "raycast")
        XCTAssertEqual(properties["client_command"] as? String, "search-tabs")
        XCTAssertEqual(properties["client_action"] as? String, "activate-tab")
        XCTAssertEqual(properties["scripting_command"] as? String, "activate_tab")
        XCTAssertEqual(properties["succeeded"] as? Bool, true)
        XCTAssertEqual(properties["operation_outcome"] as? String, "accepted")
        XCTAssertEqual(Set(properties.keys), Set([
            "client_action",
            "client_command",
            "operation_outcome",
            "scripting_command",
            "source_client",
            "succeeded",
        ]))
    }

    func testRaycastCreationCommandsAreAcceptedClientContextValues() throws {
        for command in ["new-kiosk-window", "new-incognito-space"] {
            let rawContext = """
            {
              "schemaVersion": 1,
              "clientId": "raycast",
              "clientCommand": "\(command)",
              "invocationId": "34A33E4B-B86E-4077-9C4A-A08BCF876472"
            }
            """

            let context = try XCTUnwrap(PhiScriptingClientContext.parse(rawContext))
            XCTAssertEqual(context.clientCommand, command)
        }
    }

    func testClientContextRejectsInvalidAttributionAndBoundsPropertyCardinality() {
        let validInvocationId = "34A33E4B-B86E-4077-9C4A-A08BCF876472"
        let unknownValues = """
        {
          "schemaVersion": 1,
          "clientId": "raycast",
          "clientCommand": "attacker-controlled-command",
          "clientAction": "attacker-controlled-action",
          "invocationId": "\(validInvocationId)"
        }
        """
        let normalized = PhiScriptingClientContext.parse(unknownValues)
        XCTAssertEqual(normalized?.clientCommand, "unknown")
        XCTAssertEqual(normalized?.clientAction, "unknown")

        let invalidContexts = [
            nil,
            "not json",
            """
            {
              "schemaVersion": 1,
              "clientId": "another-client",
              "clientCommand": "search-tabs",
              "invocationId": "\(validInvocationId)"
            }
            """,
            """
            {
              "schemaVersion": 1,
              "clientId": "raycast",
              "clientCommand": "search-tabs",
              "invocationId": "not-a-uuid"
            }
            """,
            String(repeating: "x", count: 1_025),
        ]

        for invalidContext in invalidContexts {
            let properties = PhiScriptingAnalytics.properties(
                clientContext: invalidContext,
                scriptingCommand: "list_tabs",
                succeeded: false,
                operationOutcome: .failed
            )
            XCTAssertEqual(properties["source_client"] as? String, "other")
            XCTAssertNil(properties["client_command"])
            XCTAssertNil(properties["client_action"])
        }
    }

    func testVersionCommandIsExcludedFromScriptingAnalytics() {
        XCTAssertFalse(PhiScriptingAnalytics.shouldCapture(scriptingCommand: "get_version"))
        XCTAssertTrue(PhiScriptingAnalytics.shouldCapture(scriptingCommand: "list_spaces"))
    }

    func testAppBundleExposesScriptingDefinition() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String, "Phi.sdef")

        let definitionURL = try XCTUnwrap(Bundle.main.url(forResource: "Phi", withExtension: "sdef"))
        let definition = try String(contentsOf: definitionURL, encoding: .utf8)
        XCTAssertTrue(definition.contains("<command name=\"get scripting version\""))
        XCTAssertTrue(definition.contains("<command name=\"get chromium data directory\""))
        XCTAssertTrue(definition.contains("<command name=\"create phi window\""))
        XCTAssertTrue(definition.contains("<command name=\"create phi incognito window\""))
        XCTAssertTrue(definition.contains("<command name=\"create phi kiosk window\""))
        XCTAssertTrue(definition.contains("<command name=\"create phi incognito space\""))
        XCTAssertTrue(definition.contains("<parameter name=\"url\" code=\"KURL\" type=\"text\" optional=\"yes\""))
        XCTAssertTrue(definition.contains("<command name=\"force reload tab\""))
        XCTAssertTrue(definition.contains("<command name=\"add split view\""))
        XCTAssertTrue(definition.contains("<command name=\"open pinned tab\""))
        XCTAssertTrue(definition.contains("<command name=\"open bookmark\""))
        let commandCount = definition.components(separatedBy: "<command name=").count - 1
        let clientContextCount = definition.components(separatedBy: "<parameter name=\"client context\"").count - 1
        XCTAssertEqual(clientContextCount, commandCount)
    }

    private func makeService(recorder: Recorder) -> PhiScriptingService {
        PhiScriptingService(dependencies: makeDependencies(recorder: recorder))
    }

    private func makeDependencies(recorder: Recorder) -> PhiScriptingDependencies {
        PhiScriptingDependencies(
            snapshot: makeSnapshot,
            savedItems: { targetSpaceId in
                self.savedItems(
                    from: self.makeSnapshot(),
                    targetSpaceId: targetSpaceId
                )
            },
            activateSpace: {
                recorder.calls.append("space:\($0)")
                return .completed
            },
            activateTab: {
                recorder.calls.append("activate:\($0):\($1)")
                return .completed
            },
            closeTab: {
                recorder.calls.append("close:\($0):\($1)")
                return .completed
            },
            reloadTab: {
                recorder.calls.append("reload:\($0):\($1)")
                return .completed
            },
            forceReloadTab: {
                recorder.calls.append("force-reload:\($0):\($1)")
                return .completed
            },
            addSplitView: {
                recorder.calls.append("add-split:\($0):\($1)")
                return .completed
            },
            openPinnedTab: {
                recorder.calls.append("open-pin:\($0):\($1)")
                return .completed
            },
            openBookmark: {
                recorder.calls.append("open-bookmark:\($0):\($1)")
                return .completed
            },
            openTab: {
                recorder.calls.append("open:\($0):\($1 ?? "current")")
                return .completed
            },
            createWindow: {
                switch $0 {
                case .normal:
                    recorder.calls.append("window:normal")
                case .incognito:
                    recorder.calls.append("window:incognito")
                }
                return .completed
            },
            createKioskWindow: {
                recorder.calls.append("kiosk:\($0)")
                return .completed
            },
            createIncognitoSpace: {
                recorder.calls.append("incognito-space")
                return .accepted
            },
            applicationVersion: { ("1.2.3", "456") },
            chromiumDataDirectory: {
                "/Users/test/Library/Application Support/com.phibrowser.Mac"
            }
        )
    }

    private func makeSnapshot() -> PhiScriptingSnapshot {
        let spaces = [
            PhiScriptingSpaceSnapshot(
                id: "space-a",
                title: "Work",
                profileId: "Default",
                profileName: "Personal",
                colorHex: "#112233",
                iconData: "aWNvbi1h",
                isActive: false,
                isOpen: true
            ),
            PhiScriptingSpaceSnapshot(
                id: "space-b",
                title: "工作",
                profileId: "Profile 1",
                profileName: "Work",
                colorHex: "#445566",
                iconData: "aWNvbi1i",
                isActive: true,
                isOpen: true
            ),
        ]
        let firstTab = PhiScriptingTabSnapshot(
            id: "11",
            windowId: "100",
            spaceId: "space-a",
            title: "First",
            url: "https://first.example",
            isActive: true,
            isPinned: false
        )
        let secondTab = PhiScriptingTabSnapshot(
            id: "22",
            windowId: "200",
            spaceId: "space-b",
            title: "Second",
            url: nil,
            isActive: true,
            isPinned: true
        )
        let sharedPin = PhiScriptingPinnedTabSnapshot(
            id: "pin-shared",
            scope: .profile,
            ownerSpaceId: nil,
            spaceIds: ["space-a", "space-b"],
            title: "Shared Pin",
            url: "https://pin.example",
            secondary: nil
        )
        let bookmarks = [
            PhiScriptingBookmarkSnapshot(
                id: "bookmark-a",
                spaceId: "space-a",
                title: "Bookmark A",
                url: "https://bookmark-a.example",
                secondary: nil
            ),
            PhiScriptingBookmarkSnapshot(
                id: "bookmark-b",
                spaceId: "space-b",
                title: "Bookmark B",
                url: "https://bookmark-b.example",
                secondary: nil
            ),
        ]
        return PhiScriptingSnapshot(
            spaces: spaces,
            windows: [
                PhiScriptingWindowSnapshot(id: "100", spaceId: "space-a", tabs: [firstTab]),
                PhiScriptingWindowSnapshot(id: "200", spaceId: "space-b", tabs: [secondTab]),
            ],
            pinnedTabs: [sharedPin],
            bookmarks: bookmarks,
            activeWindowId: "200"
        )
    }

    private func tabIds(in response: [String: Any]) -> [String] {
        (response["tabs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func pinnedTabIds(in response: [String: Any]) -> [String] {
        (response["pinnedTabs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func bookmarkIds(in response: [String: Any]) -> [String] {
        (response["bookmarks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func savedItems(
        from snapshot: PhiScriptingSnapshot,
        targetSpaceId: String?
    ) -> PhiScriptingSavedItemsSnapshot {
        PhiScriptingSavedItemsSnapshot(
            pinnedTabs: snapshot.pinnedTabs.filter { pin in
                targetSpaceId.map { pin.spaceIds.contains($0) } ?? true
            },
            bookmarks: snapshot.bookmarks.filter { bookmark in
                targetSpaceId.map { bookmark.spaceId == $0 } ?? true
            }
        )
    }

    private func errorCode(in response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }
}

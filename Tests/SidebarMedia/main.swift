// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import AppKit
import CoreGraphics
import struct SwiftUI.AnyView
import struct SwiftUI.Text

enum SidebarMediaPresentationMode: String, CaseIterable {
    case alwaysExpanded, alwaysCompact, dynamic
}

enum PhiPreferences {
    enum GeneralSettings: String {
        case sidebarMediaPlayerEnabled
        static let sidebarMediaPresentationModeKey = "sidebarMediaPresentationMode"
        static func loadSidebarMediaPresentationMode(from defaults: UserDefaults) -> SidebarMediaPresentationMode {
            defaults.string(forKey: sidebarMediaPresentationModeKey)
                .flatMap(SidebarMediaPresentationMode.init(rawValue:)) ?? .dynamic
        }
        static func saveSidebarMediaPresentationMode(_ mode: SidebarMediaPresentationMode, to defaults: UserDefaults) {
            defaults.set(mode.rawValue, forKey: sidebarMediaPresentationModeKey)
        }
        func loadValue(from defaults: UserDefaults) -> Bool {
            defaults.object(forKey: rawValue) == nil ? true : defaults.bool(forKey: rawValue)
        }
    }
}

@MainActor
final class FakeWrapper {
    var devToolsTargetId: String?
    private(set) var activationCount = 0
    init(_ id: String) { devToolsTargetId = id }
    func setAsActiveTab() { activationCount += 1 }
}

@MainActor
final class Tab {
    let guid: Int
    @Published var url: String?
    @Published var isLoading = false
    @Published var isCurrentlyAudible = false
    var isAudioMuted = false
    var isOpenned = true
    var title = "Fixture"
    var liveFaviconData: Data?
    var cachedFaviconData: Data?
    var webContentWrapper: FakeWrapper?
    init(_ id: Int) {
        guid = id
        url = "https://example.test/\(id)"
        webContentWrapper = FakeWrapper("target-\(id)")
    }
    func setAudioMuted(_ muted: Bool) { isAudioMuted = muted }
}

@MainActor
final class BrowserState {
    @Published var tabs: [Tab] = []
    @Published var focusingTab: Tab? {
        didSet { if let focusingTab { tabSwitchManager.recordActiveTab(focusingTab) } }
    }
    let tabSwitchManager = FakeTabSwitchManager()
    @Published var splits: [FakeSplitGroup] = []
    func splitGroup(forTabId tabId: Int) -> FakeSplitGroup? {
        splits.first { $0.contains(tabId: tabId) }
    }
}

final class FakeTabSwitchManager {
    var visitedTabIDs: [Int] = []
    func recordActiveTab(_ tab: Tab) {
        visitedTabIDs.removeAll { $0 == tab.guid }
        visitedTabIDs.insert(tab.guid, at: 0)
    }
}

struct FakeSplitGroup {
    let first: Int
    let second: Int
    func contains(tabId: Int) -> Bool { tabId == first || tabId == second }
}

@MainActor
enum SidebarMediaBridge {
    struct Playback: Equatable {
        let title: String
        let artist: String?
        let metadataIdentity: String
        let source: String
        let index: Int
        let topDocumentTimeOrigin: Double
        let mediaDocumentTimeOrigin: Double
        let currentTime: Double
        let duration: Double?
        let seekStart: Double?
        let seekEnd: Double?
        let isPlaying: Bool
        let isMuted: Bool
        let canPictureInPicture: Bool
        let isPictureInPicture: Bool
        var canSeek: Bool { duration != nil && seekStart != nil && seekEnd != nil }
    }
    enum Action { case playPause, seek(Double), pictureInPicture }
    struct Pending {
        let targetId: String
        let continuation: CheckedContinuation<Playback?, Never>
    }
    static var pending: [Pending] = []
    static var closedConnections = 0
    static var performedActions = 0
    static func inspect(targetId: String, fallbackTitle: String) async -> Playback? {
        await withCheckedContinuation { continuation in
            pending.append(Pending(targetId: targetId, continuation: continuation))
        }
    }
    static func perform(_ action: Action, targetId: String,
                        source: String, index: Int,
                        metadataIdentity: String,
                        topDocumentTimeOrigin: Double,
                        mediaDocumentTimeOrigin: Double) async -> Bool {
        performedActions += 1
        return true
    }
    @MainActor final class PollConnection {
        let targetId: String
        init(targetId: String) { self.targetId = targetId }
        func inspect(fallbackTitle: String) async -> Playback? {
            await SidebarMediaBridge.inspect(targetId: targetId,
                                             fallbackTitle: fallbackTitle)
        }
        func close() { SidebarMediaBridge.closedConnections += 1 }
    }
    static func respond(_ targetId: String, with playback: Playback?) {
        guard let index = pending.firstIndex(where: { $0.targetId == targetId }) else {
            fatalError("No pending inspection for \(targetId)")
        }
        pending.remove(at: index).continuation.resume(returning: playback)
    }
    static func hasPending(_ targetId: String) -> Bool {
        pending.contains { $0.targetId == targetId }
    }
}

@main
struct SidebarMediaHarness {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--physical-swipe") {
            await physicalTrackpadDirectionsAndSingleCommit()
            print("Sidebar media physical swipe checks passed")
            return
        }
        if CommandLine.arguments.contains("--multi-source") {
            await multiSourceVisitOrderAndCycling()
            await multiSourceSelectionLoss()
            await staleDisplayedCallbacks()
            await cachedSourcesRequireRevalidation()
            await manualChoiceSurvivesFocusedReveal()
            await cycleRejectsStaleDestinationAndModeChange()
            await cycleDirectionsAndPresentation()
            await dynamicHalfSecondHover()
            await physicalTrackpadDirectionsAndSingleCommit()
            print("Sidebar media multi-source policy checks passed")
            return
        }
        await staleNavigationAndSelection()
        await outOfOrderAudibleResponses()
        await hiddenPollResumes()
        await backgroundVisibilityAndDismissal()
        await independentPreferencesAndDisabledPolling()
        await presentationModesAndHoverCancellation()
        await teardownClosesConnection()
        print("SidebarMediaController hostless lifecycle checks passed")
    }

    @MainActor
    static func tick(_ milliseconds: UInt64 = 40) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    @MainActor
    static func waitForPending(_ targetId: String) async {
        for _ in 0..<50 {
            if SidebarMediaBridge.hasPending(targetId) { return }
            await tick(20)
        }
        fatalError("Timed out waiting for inspection of \(targetId)")
    }

    @MainActor
    static func playback(_ title: String, source: String = "fixture.wav",
                         mediaDocumentTimeOrigin: Double = 1_000,
                         metadataIdentity: String? = nil, currentTime: Double = 2,
                         isPlaying: Bool = true) -> SidebarMediaBridge.Playback {
        .init(title: title, artist: nil, metadataIdentity: metadataIdentity ?? title,
              source: source, index: 0,
              topDocumentTimeOrigin: 1_000,
              mediaDocumentTimeOrigin: mediaDocumentTimeOrigin,
              currentTime: currentTime, duration: 18, seekStart: 0, seekEnd: 18,
              isPlaying: isPlaying, isMuted: false,
              canPictureInPicture: false, isPictureInPicture: false)
    }

    @MainActor
    static func staleNavigationAndSelection() async {
        let state = BrowserState()
        let first = Tab(1)
        state.tabs = [first]
        state.focusingTab = first
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await waitForPending("target-1")

        // The response belongs to the old document even though the URL and
        // DevTools target stay the same across a reload.
        first.isLoading = true
        await tick()
        first.isLoading = false
        await tick()
        SidebarMediaBridge.respond("target-1", with: playback("Old document"))
        await tick()
        precondition(controller.item == nil, "Stale same-URL response was selected")

        state.focusingTab = nil
        await tick()
        state.focusingTab = first
        await waitForPending("target-1")
        SidebarMediaBridge.respond("target-1", with: playback("Fresh document"))
        await tick()
        precondition(controller.item?.playback.title == "Fresh document")

        let second = Tab(2)
        state.tabs.append(second)
        await tick()
        second.isCurrentlyAudible = true
        await waitForPending("target-2")
        SidebarMediaBridge.respond("target-2", with: playback("New source"))
        await tick()
        precondition(controller.item?.tabId == 2, "Newest audible tab did not take over")

        state.tabs.removeAll { $0 === second }
        second.isOpenned = false
        await tick()
        precondition(controller.item?.tabId != second.guid, "Closed tab kept its player")
        controller.setActive(false)
    }

    @MainActor
    static func hiddenPollResumes() async {
        let state = BrowserState()
        let tab = Tab(3)
        state.tabs = [tab]
        state.focusingTab = tab
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await waitForPending("target-3")
        SidebarMediaBridge.respond("target-3", with: playback("Retained media"))
        await tick()
        precondition(controller.item != nil)

        // Leave a poll unresolved while hiding the sidebar. A same-URL reload
        // is invisible to the suspended subscriptions, so the retained card
        // must stay hidden and its actions blocked until a fresh snapshot.
        await waitForPending("target-3")
        controller.setActive(false)
        tab.isLoading = true
        tab.isLoading = false
        precondition(controller.isRevalidating)
        controller.setActive(true)
        let actionsBefore = SidebarMediaBridge.performedActions
        controller.perform(.seek(10))
        await tick()
        precondition(SidebarMediaBridge.performedActions == actionsBefore,
                     "Hidden source accepted a control before revalidation")
        SidebarMediaBridge.respond("target-3", with: playback("Old poll"))
        await tick()
        precondition(controller.item?.playback.title == "Retained media")
        precondition(controller.isRevalidating,
                     "Old in-flight poll exposed the retained player")
        await waitForPending("target-3")
        SidebarMediaBridge.respond("target-3", with: playback("Fresh poll"))
        await tick()
        precondition(controller.item?.playback.title == "Fresh poll",
                     "Polling did not restart after hide/reveal")
        precondition(!controller.isRevalidating,
                     "Fresh snapshot did not restore the player")
        controller.perform(.seek(10))
        await tick()
        precondition(SidebarMediaBridge.performedActions == actionsBefore + 1,
                     "Revalidated source rejected a control")
        await waitForPending("target-3")
        SidebarMediaBridge.respond("target-3", with: playback("After action"))
        await tick()
        controller.setActive(false)
    }

    @MainActor
    static func outOfOrderAudibleResponses() async {
        for newerResponseFirst in [true, false] {
            let state = BrowserState()
            let first = Tab(newerResponseFirst ? 5 : 7)
            let second = Tab(newerResponseFirst ? 6 : 8)
            state.tabs = [first, second]
            state.tabSwitchManager.visitedTabIDs = [second.guid, first.guid]
            let controller = SidebarMediaController(browserState: state)
            controller.setActive(true)
            await tick()
            first.isCurrentlyAudible = true
            await waitForPending("target-\(first.guid)")
            second.isCurrentlyAudible = true
            await waitForPending("target-\(second.guid)")
            if newerResponseFirst {
                SidebarMediaBridge.respond("target-\(second.guid)",
                                           with: playback("Newest source"))
                await tick()
                SidebarMediaBridge.respond("target-\(first.guid)",
                                           with: playback("Stale source"))
            } else {
                SidebarMediaBridge.respond("target-\(first.guid)",
                                           with: playback("First source"))
                await tick()
                SidebarMediaBridge.respond("target-\(second.guid)",
                                           with: playback("Newest source"))
            }
            await tick()
            precondition(controller.item?.tabId == second.guid,
                         "Most recently visited source did not win both response orders")
            controller.setActive(false)
        }
    }

    @MainActor
    static func backgroundVisibilityAndDismissal() async {
        let state = BrowserState()
        let media = Tab(9)
        let other = Tab(10)
        state.tabs = [media, other]
        state.focusingTab = media
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await waitForPending("target-9")
        SidebarMediaBridge.respond("target-9", with: playback("First track"))
        await tick()
        precondition(controller.isSourceVisible, "Focused media source should hide its widget")

        state.focusingTab = other
        await tick()
        precondition(!controller.isSourceVisible, "Background media widget stayed hidden")
        if SidebarMediaBridge.hasPending("target-10") {
            SidebarMediaBridge.respond("target-10", with: nil)
            await tick()
        }
        state.splits = [FakeSplitGroup(first: media.guid, second: other.guid)]
        await tick()
        precondition(controller.isSourceVisible, "Visible split partner should hide the widget")
        state.splits = []
        await tick()
        precondition(!controller.isSourceVisible, "Removing the split should show the widget")

        let actionsAtDismiss = SidebarMediaBridge.performedActions
        controller.dismissCurrent()
        precondition(controller.isDismissed, "Dismissal should hide without media action")
        precondition(SidebarMediaBridge.performedActions == actionsAtDismiss,
                     "Dismissal changed playback")
        await waitForPending("target-9")
        SidebarMediaBridge.respond("target-9", with: playback("First track"))
        await tick()
        precondition(controller.isDismissed, "Poll remounted dismissed media")
        state.focusingTab = media
        await tick()
        state.focusingTab = other
        await tick()
        precondition(controller.isDismissed, "Tab switch remounted dismissed media")
        await waitForPending("target-9")
        SidebarMediaBridge.respond("target-9", with:
            playback("First track", mediaDocumentTimeOrigin: 2_000))
        await tick()
        precondition(!controller.isDismissed,
                     "Reloading the media owner frame should restore the same source")
        controller.dismissCurrent()
        media.isCurrentlyAudible = false
        media.isCurrentlyAudible = true
        await waitForPending("target-9")
        SidebarMediaBridge.respond("target-9", with: playback("First track", mediaDocumentTimeOrigin: 2_000,
                                                           metadataIdentity: "same-title-new-album"))
        await tick()
        precondition(!controller.isDismissed, "Metadata-only track replacement should restore the widget")

        controller.dismissCurrent()
        media.isCurrentlyAudible = true
        await waitForPending("target-9")
        SidebarMediaBridge.respond("target-9", with: playback("Next track", source: "next.wav"))
        await tick()
        precondition(!controller.isDismissed, "New source should restore the widget")
        precondition(controller.item?.playback.source == "next.wav")
        controller.setActive(true, on: .floating)
        precondition(controller.activeSurface == .floating)
        controller.setExpanded(true, on: .floating)
        controller.setActive(false, on: .docked)
        precondition(controller.activeSurface == .floating && !controller.isRevalidating,
                     "Docked teardown interrupted the visible floating player")
        controller.setExpanded(false, on: .docked)
        precondition(controller.isExpanded,
                     "Late docked hover exit collapsed the floating player")
        controller.setActive(false, on: .floating)
        precondition(controller.isRevalidating && controller.activeSurface == nil,
                     "Hidden floating sidebar kept polling a visible card")
    }

    @MainActor
    static func independentPreferencesAndDisabledPolling() async {
        let suiteName = "SidebarMediaHarness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enabledKey = PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue
        let modeKey = PhiPreferences.GeneralSettings.sidebarMediaPresentationModeKey
        defaults.set(false, forKey: enabledKey)
        defaults.set(SidebarMediaPresentationMode.alwaysCompact.rawValue, forKey: modeKey)
        let state = BrowserState()
        let tab = Tab(20)
        state.tabs = [tab]
        state.focusingTab = tab
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        let actionsBefore = SidebarMediaBridge.performedActions
        controller.setActive(true)
        await tick()
        precondition(controller.activeSurface == nil && controller.item == nil)
        precondition(!SidebarMediaBridge.hasPending("target-20"),
                     "Disabled player started a page inspection")

        defaults.set(true, forKey: enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitForPending("target-20")
        SidebarMediaBridge.respond("target-20", with: playback("Preference track"))
        await tick()
        precondition(controller.isEnabled && controller.presentationMode == .alwaysCompact,
                     "Enabling the player changed the independent display mode")
        precondition(controller.item != nil)
        let closedBefore = SidebarMediaBridge.closedConnections
        await waitForPending("target-20")
        defaults.set(false, forKey: enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await tick()
        precondition(controller.activeSurface == nil && controller.isRevalidating)
        precondition(SidebarMediaBridge.closedConnections > closedBefore,
                     "Disabling the player did not close its polling connection")
        SidebarMediaBridge.respond("target-20", with: playback("Preference track"))
        await tick(1_100)
        precondition(!SidebarMediaBridge.hasPending("target-20"),
                     "Disabled player continued polling after its pending request completed")
        controller.perform(.playPause)
        await tick()
        precondition(SidebarMediaBridge.performedActions == actionsBefore,
                     "Disabling the player issued a media command")
        precondition(controller.presentationMode == .alwaysCompact)
        controller.setActive(false)
    }

    @MainActor
    static func presentationModesAndHoverCancellation() async {
        let suite = "SidebarMediaModes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BrowserState()
        let media = Tab(30)
        let foreground = Tab(31)
        state.tabs = [media, foreground]
        state.focusingTab = foreground
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        controller.setActive(true)
        await waitForPending("target-31")
        SidebarMediaBridge.respond("target-31", with: nil)
        media.isCurrentlyAudible = true
        await waitForPending("target-30")
        SidebarMediaBridge.respond("target-30", with: playback("Mode track"))
        await tick()
        precondition(controller.presentationMode == .dynamic && !controller.isExpanded)

        controller.setHovering(true, on: .docked)
        await tick(80)
        precondition(!controller.isExpanded, "Dynamic expanded before the hover dwell")
        controller.setHovering(false, on: .docked)
        await tick(550)
        precondition(!controller.isExpanded, "Quick entry and exit allowed a late expansion")
        controller.setHovering(true, on: .docked)
        await tick(550)
        precondition(controller.isExpanded, "Sustained hover did not expand Dynamic")
        controller.setHovering(false, on: .docked)
        controller.setExpanded(false, on: .docked)

        // Pending pointer entry must not follow a surface transfer.
        controller.setHovering(true, on: .docked)
        await tick(80)
        controller.setActive(true, on: .floating)
        await tick(550)
        precondition(!controller.isExpanded, "Docked entry expanded the floating player")
        controller.setHovering(true, on: .floating)
        await tick(550)
        precondition(controller.isExpanded)
        controller.setActive(false, on: .floating)

        // A replacement source starts a fresh dwell, including owner-frame reload.
        controller.setHovering(true, on: .docked)
        await tick(80)
        media.isCurrentlyAudible = false
        media.isCurrentlyAudible = true
        await waitForPending("target-30")
        SidebarMediaBridge.respond("target-30", with: playback("Mode track", mediaDocumentTimeOrigin: 2_000))
        await tick(550)
        precondition(!controller.isExpanded, "Old-document hover expanded replacement media")

        controller.setHovering(true, on: .docked)
        await tick(80)
        media.isCurrentlyAudible = false
        media.isCurrentlyAudible = true
        await waitForPending("target-30")
        SidebarMediaBridge.respond("target-30", with: playback("Mode track", mediaDocumentTimeOrigin: 2_000,
                                                            metadataIdentity: "same-title-new-album"))
        await tick(550)
        precondition(!controller.isExpanded, "Old-track hover expanded metadata-only replacement")

        controller.setHovering(true, on: .docked)
        controller.dismissCurrent()
        await tick(550)
        precondition(!controller.isExpanded && controller.isDismissed,
                     "Dismissal did not cancel pending hover entry")
        media.isCurrentlyAudible = false
        media.isCurrentlyAudible = true
        await waitForPending("target-30")
        SidebarMediaBridge.respond("target-30", with: playback("New mode track", source: "new.wav"))
        await tick()

        for mode in SidebarMediaPresentationMode.allCases {
            controller.setHovering(true, on: .docked)
            PhiPreferences.GeneralSettings.saveSidebarMediaPresentationMode(mode, to: defaults)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            await tick(550)
            precondition(controller.presentationMode == mode)
            precondition(controller.isExpanded == (mode == .alwaysExpanded),
                         "Mode change allowed an obsolete pending hover to expand")
            controller.setExpanded(true, on: .docked)
            precondition(controller.isExpanded == (mode != .alwaysCompact),
                         "Always compact accepted keyboard/AX expansion")
            controller.setExpanded(false, on: .docked)
            precondition(controller.isExpanded == (mode == .alwaysExpanded),
                         "Always expanded accepted pointer-exit collapse")
        }
        controller.setHovering(true, on: .docked)
        defaults.set(false, forKey: PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await tick(550)
        precondition(!controller.isExpanded && controller.activeSurface == nil,
                     "Disabled player accepted late hover expansion")
        controller.setActive(false)
        while SidebarMediaBridge.hasPending("target-30") { SidebarMediaBridge.respond("target-30", with: nil) }
        while SidebarMediaBridge.hasPending("target-31") { SidebarMediaBridge.respond("target-31", with: nil) }
        await tick()
    }

    @MainActor
    static func drain(_ controller: SidebarMediaController, targets: [Int]) async {
        controller.setActive(false)
        for id in targets {
            while SidebarMediaBridge.hasPending("target-\(id)") {
                SidebarMediaBridge.respond("target-\(id)", with: nil)
            }
        }
        await tick()
    }

    @MainActor
    static func multiSourceVisitOrderAndCycling() async {
        let state = BrowserState()
        let media = (40...47).map(Tab.init)
        let foreground = Tab(48)
        state.tabs = media + [foreground]
        state.focusingTab = foreground
        state.tabSwitchManager.visitedTabIDs = [foreground.guid] + media.reversed().map(\.guid)
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await waitForPending("target-48")
        SidebarMediaBridge.respond("target-48", with: nil)
        for tab in media { tab.isCurrentlyAudible = true }
        for tab in media.reversed() {
            await waitForPending("target-\(tab.guid)")
            SidebarMediaBridge.respond("target-\(tab.guid)", with: playback("Media \(tab.guid)"))
        }
        await tick()
        precondition(controller.item?.tabId == 47 && controller.backgroundSourceCount == 8,
                     "Visit order must beat reply/audible order and retain more than five sources")
        let original = controller.item!
        controller.cycleSource(for: original, from: .docked)
        await waitForPending("target-46")
        precondition(controller.item?.tabId == 47, "Cached cycle destination was exposed before revalidation")
        SidebarMediaBridge.respond("target-46", with: playback("Media 46"))
        await tick()
        precondition(controller.item?.tabId == 46, "Left cycle did not follow full visit order")
        // A selected poll and unrelated audible replacement must not undo it.
        await waitForPending("target-46")
        SidebarMediaBridge.respond("target-46", with: playback("Media 46", currentTime: 6))
        media[0].isCurrentlyAudible = false
        await waitForPending("target-40")
        SidebarMediaBridge.respond("target-40", with: playback("Media 40", currentTime: 8))
        await tick()
        precondition(controller.item?.tabId == 46, "Ordinary polling/audible events reset explicit cycle choice")
        // Known source becomes silent/paused: remove it from the playing stack.
        media[0].isCurrentlyAudible = true
        await waitForPending("target-40")
        SidebarMediaBridge.respond("target-40", with: playback("Media 40", isPlaying: false))
        await tick()
        precondition(controller.backgroundSourceCount == 7,
                     "Nonselected paused source kept a stale playing stack entry")
        // Visiting a playing source resets the manual choice, and it is excluded while visible.
        state.focusingTab = media[1]
        await tick()
        precondition(controller.item?.tabId != 41 && !controller.isSourceVisible)
        while SidebarMediaBridge.hasPending("target-41") {
            SidebarMediaBridge.respond("target-41", with: playback("Media 41"))
        }
        state.focusingTab = foreground
        await tick()
        precondition(controller.item?.tabId == 41, "Leaving a visited playing source did not make it MRU")
        // Pause keeps this card available, but a later media visit wins MRU.
        await waitForPending("target-41")
        SidebarMediaBridge.respond("target-41", with: playback("Media 41", isPlaying: false))
        await tick()
        precondition(controller.item?.tabId == 41 && controller.item?.playback.isPlaying == false)
        state.focusingTab = media[2]
        await tick()
        state.focusingTab = foreground
        await tick()
        precondition(controller.item?.tabId == 42, "Retained paused card defeated a newer media visit")
        state.splits = [FakeSplitGroup(first: foreground.guid, second: 42)]
        await tick()
        precondition(controller.item?.tabId != 42, "Visible split media stayed in background choices")
        state.splits = []
        await tick()
        // Rapid requests advance past a pending destination; only the latest can publish.
        let beforeRapid = controller.item!
        let firstCount = SidebarMediaBridge.pending.count
        controller.cycleSource(for: beforeRapid, from: .docked)
        await tick()
        let firstDestination = SidebarMediaBridge.pending[firstCount].targetId
        let secondCount = SidebarMediaBridge.pending.count
        controller.cycleSource(for: beforeRapid, from: .docked)
        await tick()
        let secondDestination = SidebarMediaBridge.pending[secondCount].targetId
        precondition(firstDestination != secondDestination)
        let secondId = Int(secondDestination.dropFirst("target-".count))!
        SidebarMediaBridge.respond(secondDestination, with: playback("Media \(secondId)"))
        await tick()
        let chosenAfterRapid = controller.item?.tabId
        let firstId = Int(firstDestination.dropFirst("target-".count))!
        SidebarMediaBridge.respond(firstDestination, with: playback("Media \(firstId)"))
        await tick()
        precondition(controller.item?.tabId == chosenAfterRapid, "Cancelled cycle published an old destination")
        // Repeated focused playing snapshots must not reset a background cycle.
        state.focusingTab = media[7]
        await tick()
        while SidebarMediaBridge.hasPending("target-47") {
            SidebarMediaBridge.respond("target-47", with: playback("Media 47"))
        }
        await tick()
        let background = controller.item!
        controller.cycleSource(for: background, from: .docked)
        await tick()
        let destination = SidebarMediaBridge.pending.last!.targetId
        let destinationId = Int(destination.dropFirst("target-".count))!
        SidebarMediaBridge.respond(destination, with: playback("Media \(destinationId)"))
        await tick()
        let cycled = controller.item?.tabId
        media[7].isCurrentlyAudible = false
        await waitForPending("target-47")
        SidebarMediaBridge.respond("target-47", with: playback("Media 47", currentTime: 9))
        await tick()
        precondition(controller.item?.tabId == cycled, "Repeated focused playing inspection reset cycle without a visit")
        await drain(controller, targets: media.map(\.guid) + [foreground.guid])
    }

    @MainActor
    static func multiSourceSelectionLoss() async {
        for ends in [false, true] {
            for pendingOlder in [false, true] {
                let base = 60 + (ends ? 4 : 0) + (pendingOlder ? 2 : 0)
                let state = BrowserState()
                let older = Tab(base), newer = Tab(base + 1)
                state.tabs = [older, newer]
                state.tabSwitchManager.visitedTabIDs = [newer.guid, older.guid]
                let controller = SidebarMediaController(browserState: state)
                controller.setActive(true)
                await tick()
                older.isCurrentlyAudible = true
                await waitForPending("target-\(older.guid)")
                if !pendingOlder {
                    SidebarMediaBridge.respond("target-\(older.guid)", with: playback("Older"))
                    await tick()
                }
                newer.isCurrentlyAudible = true
                await waitForPending("target-\(newer.guid)")
                SidebarMediaBridge.respond("target-\(newer.guid)", with: playback("Newer"))
                await tick()
                precondition(controller.item?.tabId == newer.guid)
                if ends {
                    for _ in 0..<2 {
                        await waitForPending("target-\(newer.guid)")
                        SidebarMediaBridge.respond("target-\(newer.guid)", with: nil)
                        await tick()
                    }
                } else {
                    newer.isOpenned = false
                    state.tabs.removeAll { $0 === newer }
                    await tick()
                }
                await waitForPending("target-\(older.guid)")
                SidebarMediaBridge.respond("target-\(older.guid)", with: playback("Older"))
                await tick()
                precondition(controller.item?.tabId == older.guid,
                             "Selection loss did not restore a still-audible source, including an older pending reply")
                await drain(controller, targets: [older.guid, newer.guid])
            }
        }
    }

    @MainActor
    static func staleDisplayedCallbacks() async {
        let state = BrowserState()
        let first = Tab(80), second = Tab(81)
        state.tabs = [first, second]
        state.tabSwitchManager.visitedTabIDs = [81, 80]
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await tick()
        first.isCurrentlyAudible = true
        await waitForPending("target-80")
        SidebarMediaBridge.respond("target-80", with: playback("Same title", metadataIdentity: "album-one"))
        await tick()
        let old = controller.item!
        first.isCurrentlyAudible = false
        await waitForPending("target-80")
        SidebarMediaBridge.respond("target-80", with: playback("Same title", metadataIdentity: "album-two"))
        await tick()
        let actions = SidebarMediaBridge.performedActions
        controller.perform(.seek(5), for: old)
        controller.toggleMute(for: old)
        controller.showTab(for: old)
        controller.dismissCurrent(for: old)
        await tick()
        precondition(SidebarMediaBridge.performedActions == actions && !first.isAudioMuted
                     && first.webContentWrapper?.activationCount == 0 && !controller.isDismissed,
                     "Stale displayed metadata callbacks affected the newly published track")
        let fresh = controller.item!
        first.liveFaviconData = Data([1, 2, 3])
        await waitForPending("target-80")
        SidebarMediaBridge.respond("target-80", with: playback("Same title", metadataIdentity: "album-two", currentTime: 9))
        await tick()
        controller.toggleMute(for: fresh)
        controller.showTab(for: fresh)
        controller.perform(.seek(5), for: fresh)
        await tick()
        precondition(controller.matchesCurrentSource(fresh) && first.isAudioMuted
                     && first.webContentWrapper?.activationCount == 1
                     && SidebarMediaBridge.performedActions == actions + 1,
                     "Ordinary time/favicon/mute updates rejected a fresh source callback")
        second.isCurrentlyAudible = true
        await waitForPending("target-81")
        SidebarMediaBridge.respond("target-81", with: playback("Second tab"))
        await tick()
        controller.perform(.playPause, for: fresh)
        controller.toggleMute(for: fresh)
        controller.showTab(for: fresh)
        controller.dismissCurrent(for: fresh)
        await tick()
        precondition(SidebarMediaBridge.performedActions == actions + 1 && !second.isAudioMuted
                     && second.webContentWrapper?.activationCount == 0 && !controller.isDismissed)
        controller.dismissCurrent(for: controller.item!)
        precondition(controller.item?.tabId != 81 || controller.isDismissed)
        await drain(controller, targets: [80, 81])
    }

    @MainActor
    static func cachedSourcesRequireRevalidation() async {
        let state = BrowserState()
        let first = Tab(90), second = Tab(91)
        state.tabs = [first, second]
        state.tabSwitchManager.visitedTabIDs = [91, 90]
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        await tick()
        first.isCurrentlyAudible = true
        await waitForPending("target-90")
        // Keep the older candidate discovery pending through activation loss.
        second.isCurrentlyAudible = true
        await waitForPending("target-91")
        SidebarMediaBridge.respond("target-91", with: playback("Retained"))
        await tick()
        let old = controller.item!
        controller.setActive(false)
        first.isLoading = true; first.isLoading = false
        second.isLoading = true; second.isLoading = false
        controller.setActive(true)
        await tick()
        precondition(controller.isRevalidating && controller.backgroundSourceCount == 0,
                     "Cached choices bypassed hidden same-URL revalidation")
        let actions = SidebarMediaBridge.performedActions
        controller.perform(.playPause, for: old)
        controller.toggleMute(for: old)
        controller.showTab(for: old)
        precondition(SidebarMediaBridge.performedActions == actions && !second.isAudioMuted
                     && second.webContentWrapper?.activationCount == 0)
        SidebarMediaBridge.respond("target-90", with: playback("Old activation"))
        await waitForPending("target-90")
        precondition(controller.isRevalidating, "An old activation discovery exposed retained media")
        SidebarMediaBridge.respond("target-90", with: playback("Fresh older", mediaDocumentTimeOrigin: 2_000))
        await tick()
        precondition(controller.item?.tabId == 91 && controller.isRevalidating,
                     "Another fresh source exposed the retained card before its own revalidation")
        while SidebarMediaBridge.hasPending("target-91") {
            SidebarMediaBridge.respond("target-91", with: playback("Fresh newer", mediaDocumentTimeOrigin: 2_000))
        }
        await tick()
        precondition(controller.item?.tabId == 91)
        await drain(controller, targets: [90, 91])
    }

    @MainActor
    static func manualChoiceSurvivesFocusedReveal() async {
        let state = BrowserState()
        let a = Tab(100), focused = Tab(101), c = Tab(102)
        state.tabs = [a, focused, c]
        state.focusingTab = focused
        state.tabSwitchManager.visitedTabIDs = [101, 102, 100]
        for tab in state.tabs { tab.isCurrentlyAudible = true }
        let controller = SidebarMediaController(browserState: state)
        controller.setActive(true)
        for id in [101, 102, 100] {
            await waitForPending("target-\(id)")
            SidebarMediaBridge.respond("target-\(id)", with: playback("Media \(id)"))
        }
        await tick()
        precondition(controller.item?.tabId == 102)
        controller.cycleSource(for: controller.item!, from: .docked)
        await waitForPending("target-100")
        SidebarMediaBridge.respond("target-100", with: playback("Media 100"))
        await tick()
        precondition(controller.item?.tabId == 100)
        controller.setActive(false)
        controller.setActive(true)
        await waitForPending("target-101")
        SidebarMediaBridge.respond("target-101", with: playback("Media 101", currentTime: 5))
        await tick()
        precondition(controller.item?.tabId == 100 && controller.isRevalidating,
                     "Focused fresh response replaced a concealed manual source on reveal")
        await waitForPending("target-100")
        while SidebarMediaBridge.hasPending("target-100") {
            SidebarMediaBridge.respond("target-100", with: playback("Media 100", currentTime: 6))
        }
        await tick()
        while SidebarMediaBridge.hasPending("target-102") {
            SidebarMediaBridge.respond("target-102", with: playback("Media 102", currentTime: 7))
        }
        await tick()
        precondition(controller.item?.tabId == 100 && !controller.isRevalidating,
                     "Cache refill or ongoing focused playback erased the user's cycle choice")
        await drain(controller, targets: [100, 101, 102])
    }

    @MainActor
    static func cycleRejectsStaleDestinationAndModeChange() async {
        let suite = "SidebarMediaCycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BrowserState()
        let a = Tab(110), b = Tab(111), foreground = Tab(112)
        state.tabs = [a, b, foreground]
        state.focusingTab = foreground
        state.tabSwitchManager.visitedTabIDs = [112, 111, 110]
        a.isCurrentlyAudible = true; b.isCurrentlyAudible = true
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        controller.setActive(true)
        for id in [112, 111, 110] {
            await waitForPending("target-\(id)")
            SidebarMediaBridge.respond("target-\(id)", with: id == 112 ? nil : playback("Media \(id)"))
        }
        await tick()
        let original = controller.item!
        controller.cycleSource(for: original, from: .docked)
        await waitForPending("target-110")
        SidebarMediaBridge.respond("target-110", with: playback("Changed destination", metadataIdentity: "new-album"))
        await tick()
        precondition(controller.item?.tabId == 111, "A changed destination was published as the old queued cycle")
        controller.cycleSource(for: original, from: .docked)
        await waitForPending("target-110")
        PhiPreferences.GeneralSettings.saveSidebarMediaPresentationMode(.alwaysCompact, to: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await tick()
        SidebarMediaBridge.respond("target-110", with: playback("Changed destination", metadataIdentity: "new-album"))
        await tick()
        precondition(controller.item?.tabId == 111, "A cycle completed after a presentation-mode cancellation")
        controller.cycleSource(for: original, from: .docked)
        await waitForPending("target-110")
        SidebarMediaBridge.respond("target-110", with: nil)
        await tick()
        precondition(controller.item?.tabId == 111 && controller.backgroundSourceCount == 1,
                     "An ended cycle destination kept a stale stacked card")
        await drain(controller, targets: [110, 111, 112])
    }

    @MainActor
    static func cycleDirectionsAndPresentation() async {
        let suite = "SidebarMediaDirections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BrowserState()
        let media = (120...122).map(Tab.init), foreground = Tab(123)
        state.tabs = media + [foreground]
        state.focusingTab = foreground
        state.tabSwitchManager.visitedTabIDs = [123, 122, 121, 120]
        for tab in media { tab.isCurrentlyAudible = true }
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        controller.setActive(true)
        for id in [123, 122, 121, 120] {
            await waitForPending("target-\(id)")
            SidebarMediaBridge.respond("target-\(id)", with: id == 123 ? nil : playback("Media \(id)"))
        }
        await tick()
        controller.setExpanded(true, on: .docked)
        var expansionPublications: [Bool] = []
        let subscription = controller.$isExpanded.dropFirst().sink { expansionPublications.append($0) }
        for (direction, destination) in [(SidebarMediaController.CycleDirection.next, 121),
                                         (.previous, 122), (.previous, 120), (.next, 122)] {
            controller.cycleSource(for: controller.item!, direction: direction, from: .docked)
            await waitForPending("target-\(destination)")
            SidebarMediaBridge.respond("target-\(destination)", with: playback("Media \(destination)"))
            await tick()
            precondition(controller.item?.tabId == destination && controller.cycleDirection == direction,
                         "Bidirectional cycle or wrap did not follow visit order")
            precondition(controller.isExpanded && !expansionPublications.contains(false),
                         "Expanded cycling published an intermediate collapse")
        }
        // Exit while destination validation is pending must stay collapsed.
        controller.cycleSource(for: controller.item!, from: .docked)
        await waitForPending("target-121")
        controller.setHovering(false, on: .docked)
        controller.setExpanded(false, on: .docked)
        expansionPublications.removeAll()
        SidebarMediaBridge.respond("target-121", with: playback("Media 121"))
        await tick()
        precondition(controller.item?.tabId == 121 && !controller.isExpanded
                     && !expansionPublications.contains(true),
                     "Delayed cycle reopened details after pointer exit")
        // Mixed rapid directions return from the pending destination. Its
        // older response must not publish after the reversed request succeeds.
        let original = controller.item!
        controller.cycleSource(for: original, direction: .next, from: .docked)
        await waitForPending("target-120")
        controller.cycleSource(for: original, direction: .previous, from: .docked)
        await waitForPending("target-121")
        SidebarMediaBridge.respond("target-121", with: playback("Media 121"))
        await tick()
        SidebarMediaBridge.respond("target-120", with: playback("Media 120"))
        await tick()
        precondition(controller.item?.tabId == 121 && controller.cycleDirection == .previous,
                     "An older mixed-direction cycle displaced the latest destination")
        subscription.cancel()
        await drain(controller, targets: [120, 121, 122, 123])
    }

    @MainActor
    static func dynamicHalfSecondHover() async {
        let suite = "SidebarMediaHalfSecond.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BrowserState(), media = Tab(130), foreground = Tab(131)
        state.tabs = [media, foreground]
        state.focusingTab = foreground
        media.isCurrentlyAudible = true
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        controller.setActive(true)
        for id in [131, 130] {
            await waitForPending("target-\(id)")
            SidebarMediaBridge.respond("target-\(id)", with: id == 131 ? nil : playback("Hover media"))
        }
        await tick()
        controller.setHovering(true, on: .docked)
        await tick(400)
        precondition(!controller.isExpanded, "Dynamic expanded before the 500ms dwell")
        await tick(150)
        precondition(controller.isExpanded, "Dynamic did not expand after the 500ms dwell")
        controller.setExpanded(false, on: .docked)
        controller.setHovering(true, on: .docked)
        await tick(80)
        controller.setHovering(false, on: .docked)
        await tick(550)
        precondition(!controller.isExpanded, "Short hover exit allowed delayed expansion")
        await drain(controller, targets: [130, 131])
    }

    @MainActor
    static func physicalTrackpadDirectionsAndSingleCommit() async {
        let suite = "SidebarMediaPhysicalSwipe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BrowserState()
        let a = Tab(140), b = Tab(141), c = Tab(142), foreground = Tab(143)
        state.tabs = [a, b, c, foreground]
        state.focusingTab = foreground
        state.tabSwitchManager.visitedTabIDs = [143, 140, 141, 142]
        for tab in [a, b, c] { tab.isCurrentlyAudible = true }
        let controller = SidebarMediaController(browserState: state, defaults: defaults)
        controller.setActive(true)
        for id in [143, 140, 141, 142] {
            await waitForPending("target-\(id)")
            SidebarMediaBridge.respond("target-\(id)", with: id == 143 ? nil : playback("Media \(id)"))
        }
        await tick()
        let host = SidebarMediaHostingView(rootView: AnyView(Text(verbatim: "Trackpad test")))
        host.frame.size = NSSize(width: 193, height: 124)
        host.mediaController = controller
        let oldRemoval = SidebarMediaCardTransition(controller: controller, isInsertion: false,
                                                     progress: 1, width: 193)
        let oldInsertion = SidebarMediaCardTransition(controller: controller, isInsertion: true,
                                                       progress: 1, width: 193)
        var publications = 0
        let subscription = controller.$cycleAnimationGeneration.dropFirst().sink { _ in publications += 1 }
        @MainActor
        func send(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                  momentum: NSEvent.Phase, timestamp: TimeInterval,
                  isDirectionInvertedFromDevice inverted: Bool) -> Bool {
            if inverted {
                return host.handleMediaSwipe(deltaX: deltaX, deltaY: deltaY, phase: phase,
                    momentum: momentum, timestamp: timestamp, isDirectionInvertedFromDevice: true)
            }
            // Exercise the actual NSEvent→scrollWheel entry, without posting
            // input to macOS or any running application. CGEvent construction
            // exposes uninverted device deltas; the inverted case above uses
            // the same production boundary with the opposite raw signs.
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let scrollPhase: CGScrollPhase? = phase == .began ? .began
                : phase == .changed ? .changed : phase == .ended ? .ended : nil
            let momentumPhase: CGMomentumScrollPhase = momentum == .began ? .begin
                : momentum == .changed ? .continuous : momentum == .ended ? .end : .none
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
            cg.timestamp = UInt64(timestamp * 1_000_000_000)
            let event = NSEvent(cgEvent: cg)!
            precondition(event.phase == phase && event.momentumPhase == momentum
                         && !event.isDirectionInvertedFromDevice && event.scrollingDeltaX == deltaX,
                         "Native event construction did not preserve the intended raw input")
            host.scrollWheel(with: event)
            return true
        }
        var timestamp: TimeInterval = 0
        for inverted in [true, false] {
            // Device deltas are positive for physical left; natural scrolling
            // inverts those values before NSEvent exposes them to this host.
            for (physicalLeft, destination) in [(true, 141), (true, 142), (false, 141), (false, 140)] {
                let rawDelta: CGFloat = (physicalLeft ? 50 : -50) * (inverted ? -1 : 1)
                let pendingBefore = SidebarMediaBridge.pending.count
                let previousTarget = controller.item!.targetId
                let publicationsBefore = publications
                timestamp += 1
                precondition(send(deltaX: 0, deltaY: 0, phase: .began,
                    momentum: [], timestamp: timestamp, isDirectionInvertedFromDevice: inverted))
                precondition(send(deltaX: rawDelta, deltaY: 1, phase: .changed,
                    momentum: [], timestamp: timestamp + 0.05, isDirectionInvertedFromDevice: inverted))
                precondition(send(deltaX: 0, deltaY: 0, phase: .ended,
                    momentum: [], timestamp: timestamp + 0.1, isDirectionInvertedFromDevice: inverted))
                // A duplicate release and its momentum cannot advance a
                // pending destination twice or enqueue another inspection.
                _ = send(deltaX: 0, deltaY: 0, phase: .ended,
                    momentum: [], timestamp: timestamp + 0.11, isDirectionInvertedFromDevice: inverted)
                _ = send(deltaX: rawDelta, deltaY: 0, phase: [],
                    momentum: .began, timestamp: timestamp + 0.12, isDirectionInvertedFromDevice: inverted)
                _ = send(deltaX: rawDelta, deltaY: 0, phase: [],
                    momentum: .changed, timestamp: timestamp + 0.13, isDirectionInvertedFromDevice: inverted)
                _ = send(deltaX: 0, deltaY: 0, phase: [],
                    momentum: .ended, timestamp: timestamp + 0.14, isDirectionInvertedFromDevice: inverted)
                await tick()
                let newCandidates = SidebarMediaBridge.pending.dropFirst(pendingBefore)
                    .filter { $0.targetId != previousTarget }.map(\.targetId)
                precondition(newCandidates == ["target-\(destination)"],
                             "One physical swipe dispatched an incorrect or duplicate candidate inspection")
                await waitForPending("target-\(destination)")
                while SidebarMediaBridge.hasPending("target-\(destination)") {
                    SidebarMediaBridge.respond("target-\(destination)", with: playback("Media \(destination)"))
                }
                await tick()
                let direction: SidebarMediaController.CycleDirection = physicalLeft ? .next : .previous
                precondition(controller.item?.tabId == destination && controller.cycleDirection == direction,
                             "Physical left-left-right-right must follow A→B→C→B→A")
                precondition(publications == publicationsBefore + 1,
                             "A physical swipe published more than one source transition")
                precondition(oldRemoval.horizontalOffset == (physicalLeft ? -193 : 193)
                             && oldInsertion.horizontalOffset == (physicalLeft ? 193 : -193),
                             "An outgoing transition retained its previous cycle direction")
            }
        }
        subscription.cancel()
        await drain(controller, targets: [140, 141, 142, 143])
    }

    @MainActor
    static func teardownClosesConnection() async {
        let state = BrowserState()
        let tab = Tab(4)
        state.tabs = [tab]
        state.focusingTab = tab
        var controller: SidebarMediaController? = SidebarMediaController(browserState: state)
        weak var weakController = controller
        controller?.setActive(true)
        await waitForPending("target-4")
        SidebarMediaBridge.respond("target-4", with: playback("Teardown media"))
        await waitForPending("target-4") // first poll owns a connection
        let before = SidebarMediaBridge.closedConnections
        controller = nil
        await tick()
        precondition(weakController == nil)
        precondition(SidebarMediaBridge.closedConnections > before,
                     "Controller teardown leaked the CDP connection")
        SidebarMediaBridge.respond("target-4", with: nil)
    }
}

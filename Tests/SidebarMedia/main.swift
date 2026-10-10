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
    @Published private(set) var webContentWrapper: (WebContentWrapper & NSObject)?
    init(_ id: Int) {
        guid = id
        url = "https://example.test/\(id)"
        webContentWrapper = FakeWrapper()
    }
    func setWebContentsWrapper(wrapper: (WebContentWrapper & NSObject)?) {
        webContentWrapper = wrapper
    }
    func setAudioMuted(_ muted: Bool) { isAudioMuted = muted }
    var fakeWrapper: FakeWrapper {
        guard let wrapper = webContentWrapper as? FakeWrapper else { fatalError("Expected fake wrapper") }
        return wrapper
    }
    var controls: FakeMediaControls { fakeWrapper.fakeControls }
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

@main
struct SidebarMediaHarness {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--window-source-order") {
            await backgroundFocusDoesNotReorderSources()
            print("Window media source-order checks passed")
            return
        }
        if CommandLine.arguments.contains("--physical-swipe") {
            await physicalTrackpadDirectionsAndSingleCommit()
            print("Sidebar media physical swipe checks passed")
            return
        }
        if !CommandLine.arguments.contains("--multi-source") {
            await observationSurvivesPresentationExit()
            await windowSourcesAndPresentation()
            await crossSpaceReturnValidation()
            await backgroundFocusDoesNotReorderSources()
            nativeDecodeAndOldFramework()
            nativeActionIntentAndCapabilities()
            nativeTrackActions()
            await volumeInteractionAndValidation()
            nativeObservationLifecycle()
            await trackChangeKeepsCardStable()
            await missingTrackExpiresAndRejectedTrackDoesNotHold()
            await pictureInPictureHidesAndRestoresSource()
            await sourceIdentityAndDismissal()
            await navigationWrapperReplacementAndTeardown()
            await disabledObservationResumes()
            await immediateRemovedTabActionsAreRejected()
            await reentrantWrapperObservationTeardown()
        }
        await visitOrderCyclingFocusAndSplit()
        await cycleRevalidationAndStaleCallbacks()
        await preferencesPresentationAndHover()
        await volumeClosesOnHoverExit()
        await heightAnimationReversesAndCancels()
        await physicalTrackpadDirectionsAndSingleCommit()
        await gestureCancellation()
        print("Sidebar native adapter, controller and gesture checks passed")
    }

    @MainActor
    static func observationSurvivesPresentationExit() async {
        let f = Fixture([190, 191]); defer { f.stop() }
        await tick()
        let controls = f.tabs[0].controls
        let starts = controls.startCount, stops = controls.stopCount
        f.controller.setActive(false)
        precondition(controls.stopCount == stops,
                     "Leaving a Space sidebar must not tear down window-wide media observation")
        controls.emit(snapshot("Background update"))
        await tick()
        f.controller.setActive(true)
        precondition(controls.startCount == starts && f.controller.item?.playback.title == "Background update")
    }

    @MainActor
    static func windowSourcesAndPresentation() async {
        let f = Fixture([200, 201]); defer { f.stop() }
        let b = BrowserState(), mediaB = Tab(200), blankB = Tab(202)
        b.tabs = [mediaB, blankB]; b.focusingTab = blankB
        mediaB.controls.snapshotValue = snapshot("Space B", token: "b-token", source: "b-source")
        let c = f.controller
        let aSurface = SidebarMediaController.Surface(session: f.state, kind: .docked)
        let bSurface = SidebarMediaController.Surface(session: b, kind: .docked)
        f.state.focusingTab = f.tabs[0]
        c.setSessions([f.state, b], presented: b)
        c.setActive(true, on: bSurface)
        await tick()
        precondition(c.backgroundSourceCount == 2 && !c.isSourceVisible,
                     "An inactive Space's focused media must remain a background source")
        precondition(c.item?.sessionID == ObjectIdentifier(f.state))
        let starts = f.tabs[0].controls.startCount
        c.setActive(false, on: aSurface)
        c.setHovering(false, on: aSurface)
        precondition(c.activeSurface == bSurface, "Late outgoing presentation must not deactivate the incoming player")
        let old = require(c.item), actions = f.tabs[0].controls.actions.count
        c.perform(.playPause, for: old, from: aSurface)
        precondition(f.tabs[0].controls.actions.count == actions)
        c.perform(.playPause, for: old, from: bSurface)
        precondition(f.tabs[0].controls.actions.count == actions + 1 && mediaB.controls.actions.isEmpty,
                     "Commands must reach the source session even when tab IDs collide")
        c.cycleSource(for: require(c.item), from: bSurface)
        await tick()
        precondition(c.item?.sessionID == ObjectIdentifier(b))
        c.setSessions([f.state, b], presented: f.state)
        c.setActive(true, on: aSurface)
        c.setActive(false, on: bSurface)
        await tick()
        precondition(c.item?.sessionID == ObjectIdentifier(b) && c.backgroundSourceCount == 1)
        precondition(f.tabs[0].controls.startCount == starts, "Space switching must not restart media subscriptions")
        var pip = snapshot("Space B", token: "b-pip", source: "b-source")
        pip["isPictureInPicture"] = true
        mediaB.controls.emit(pip)
        await tick()
        precondition(c.backgroundSourceCount == 0 && c.isSourceVisible)
        pip["isPictureInPicture"] = false
        mediaB.controls.emit(pip)
        await tick()
        precondition(c.backgroundSourceCount == 1 && !c.isSourceVisible)
        let replacement = BrowserState(), replacementMedia = Tab(200)
        replacement.tabs = [replacementMedia]
        replacementMedia.controls.snapshotValue = snapshot("Replacement", source: "replacement")
        c.setSessions([f.state, replacement], presented: f.state)
        await tick()
        precondition(!mediaB.controls.isObserving && replacementMedia.controls.isObserving)
        mediaB.controls.emitStopped(snapshot("Stale removed session"))
        await tick()
        precondition(c.item?.sessionID == ObjectIdentifier(replacement))
        let other = Fixture([200, 203]); defer { other.stop() }
        await tick()
        precondition(other.controller.backgroundSourceCount == 1 && other.controller.item?.sessionID == ObjectIdentifier(other.state))
        c.setSessions([f.state], presented: f.state)
        precondition(!replacementMedia.controls.isObserving)
    }

    @MainActor
    static func backgroundFocusDoesNotReorderSources() async {
        let f = Fixture([220, 221, 222, 223]); defer { f.stop() }
        let b = BrowserState(), blank = Tab(224)
        b.tabs = [blank]; b.focusingTab = blank
        let c = f.controller, surface = SidebarMediaController.Surface(session: b, kind: .docked)
        c.setSessions([f.state, b], presented: b)
        c.setActive(true, on: surface)
        await tick()
        precondition(c.item?.tabId == 220)
        f.state.focusingTab = f.tabs[1]
        await tick()
        c.cycleSource(for: require(c.item), from: surface)
        await tick()
        precondition(c.item?.tabId == 221, "Background focus must not reorder sources without a presented visit")
    }

    @MainActor
    static func crossSpaceReturnValidation() async {
        let f = Fixture([210, 211]); defer { f.stop() }
        let b = BrowserState(), blank = Tab(212)
        b.tabs = [blank]; b.focusingTab = blank
        let c = f.controller
        let surface = SidebarMediaController.Surface(session: b, kind: .docked)
        var completions: [(Bool) -> Void] = []
        c.activateSession = { sessionID, completion in
            precondition(sessionID == ObjectIdentifier(f.state))
            completions.append(completion)
        }
        func presentB() {
            c.setSessions([f.state, b], presented: b)
            c.setActive(true, on: surface)
        }
        presentB()
        await tick()
        let wrapper = f.tabs[0].fakeWrapper
        c.showTab(for: require(c.item), from: surface)
        precondition(completions.count == 1 && wrapper.activationCount == 0)
        c.setSessions([f.state, b], presented: f.state)
        let settled = completions.removeFirst()
        settled(true)
        settled(true)
        precondition(wrapper.activationCount == 1, "A successful return completion must activate the tab only once")
        presentB()
        c.showTab(for: require(c.item), from: surface)
        completions.removeFirst()(false)
        precondition(wrapper.activationCount == 1)
        c.showTab(for: require(c.item), from: surface)
        let superseded = completions.removeFirst()
        c.showTab(for: require(c.item), from: surface)
        c.setSessions([f.state, b], presented: f.state)
        superseded(true)
        precondition(wrapper.activationCount == 1)
        completions.removeFirst()(true)
        precondition(wrapper.activationCount == 2)
        presentB()
        c.showTab(for: require(c.item), from: surface)
        let delayed = completions.removeFirst()
        let third = BrowserState()
        c.setSessions([f.state, b, third], presented: third)
        c.setSessions([f.state, b, third], presented: f.state)
        delayed(true)
        precondition(wrapper.activationCount == 2, "A newer Space switch cancels delayed return navigation")
        presentB()
        c.showTab(for: require(c.item), from: surface)
        let supersededByTab = completions.removeFirst()
        c.setSessions([f.state, b], presented: f.state)
        let newerTab = Tab(214)
        f.state.tabs.append(newerTab)
        f.state.focusingTab = newerTab
        await tick()
        supersededByTab(true)
        precondition(wrapper.activationCount == 2, "Return must not override a newer tab choice in the target Space")
        presentB()
        c.showTab(for: require(c.item), from: surface)
        let closed = completions.removeFirst()
        f.state.tabs.removeAll { $0 === f.tabs[0] }
        c.setSessions([f.state, b], presented: f.state)
        closed(true)
        precondition(wrapper.activationCount == 2, "A closed target must not be activated or reopened")
    }

    static func require<T>(_ value: T?, _ message: String = "Missing test value") -> T {
        guard let value else { fatalError(message) }
        return value
    }

    @MainActor
    static func tick(_ milliseconds: UInt64 = 40) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    static func snapshot(_ title: String = "Native title", token: String = "token-1",
                         source: String = "source-1", playing: Bool = true) -> [String: Any] {
        ["token": token, "sourceToken": source, "title": title, "artist": "Native artist",
         "currentTime": 2.0, "duration": 18.0, "playing": playing,
         "muted": false, "tabMuted": false, "canPlay": true, "canPause": true,
         "canSeek": true, "canEnterPictureInPicture": true,
         "canExitPictureInPicture": false, "isPictureInPicture": false]
    }

    @MainActor
    final class Fixture {
        let state = BrowserState()
        let tabs: [Tab]
        let defaults: UserDefaults
        let suite = "SidebarNative.\(UUID().uuidString)"
        let controller: SidebarMediaController
        init(_ ids: [Int]) {
            defaults = require(UserDefaults(suiteName: suite))
            tabs = ids.map(Tab.init)
            state.tabs = tabs
            state.focusingTab = tabs.last
            state.tabSwitchManager.visitedTabIDs = [ids.last].compactMap { $0 } + ids.dropLast()
            for tab in tabs.dropLast() {
                tab.isCurrentlyAudible = true
                tab.controls.snapshotValue = snapshot("Media \(tab.guid)", token: "token-\(tab.guid)", source: "source-\(tab.guid)")
            }
            controller = SidebarMediaController(browserState: state, defaults: defaults)
            controller.setActive(true)
        }
        func stop() {
            controller.setActive(false, on: .docked)
            controller.setActive(false, on: .floating)
            controller.setSessions([], presented: nil)
            defaults.removePersistentDomain(forName: suite)
        }
        func mode(_ value: SidebarMediaPresentationMode) {
            PhiPreferences.GeneralSettings.saveSidebarMediaPresentationMode(value, to: defaults)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        func enabled(_ value: Bool) {
            defaults.set(value, forKey: PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
    }

    @MainActor
    static func missingTrackExpiresAndRejectedTrackDoesNotHold() async {
        let f = Fixture([951, 952]); defer { f.stop() }
        await tick()
        var value = require(f.tabs[0].controls.snapshotValue)
        value["canNextTrack"] = true
        f.tabs[0].controls.emit(value)
        f.controller.perform(.nextTrack, for: require(f.controller.item), from: .docked)
        f.tabs[0].controls.emit(nil)
        await tick(5200)
        precondition(f.controller.item == nil && !f.controller.isChangingTrack,
                     "A track that never arrives must not leave a permanent ghost player")
        f.tabs[0].controls.emit(value)
        f.tabs[0].controls.acceptsActions = false
        f.controller.perform(.nextTrack, for: require(f.controller.item), from: .docked)
        f.tabs[0].controls.emit(nil)
        precondition(f.controller.item == nil && !f.controller.isChangingTrack,
                     "Rejected native track commands must not change the normal removal policy")
    }

    @MainActor
    static func volumeInteractionAndValidation() async {
        let f = Fixture([921, 922]); defer { f.stop() }
        await tick()
        var value = require(f.tabs[0].controls.snapshotValue)
        value["volume"] = 0.8
        value["canSetVolume"] = true
        f.tabs[0].controls.emit(value)
        let controller = f.controller, item = require(controller.item)
        controller.volumeButtonClicked(for: item, from: .docked, optionPressed: false)
        precondition(controller.isVolumeExpanded && !f.tabs[0].isAudioMuted,
                     "Ordinary volume clicks show a slider without muting")
        controller.volumeButtonClicked(for: item, from: .docked, optionPressed: true)
        precondition(controller.isVolumeExpanded && f.tabs[0].isAudioMuted,
                     "Option-click toggles mute without toggling the slider")
        controller.setVolume(0.35, for: require(controller.item), from: .docked)
        precondition(controller.item?.playback.volume == 0.35 && f.tabs[0].isAudioMuted)
        let count = f.tabs[0].controls.actions.count
        controller.setVolume(.nan, for: require(controller.item), from: .docked)
        precondition(f.tabs[0].controls.actions.count == count)
        controller.setVolume(2, for: require(controller.item), from: .docked)
        precondition(controller.item?.playback.volume == 1)
        let stale = require(controller.item)
        value["sourceToken"] = "new-source"
        value["token"] = "new-token"
        f.tabs[0].controls.emit(value)
        let afterChange = f.tabs[0].controls.actions.count
        controller.setVolume(0, for: stale, from: .docked)
        precondition(f.tabs[0].controls.actions.count == afterChange)
    }

    @MainActor
    static func trackChangeKeepsCardStable() async {
        let f = Fixture([901, 902, 903]); defer { f.stop() }
        await tick()
        var value = require(f.tabs[0].controls.snapshotValue)
        value["canNextTrack"] = true
        f.tabs[0].controls.emit(value)
        let controller = f.controller
        controller.setExpanded(true, on: .docked)
        let before = require(controller.item)
        controller.perform(.nextTrack, for: before, from: .docked)
        f.tabs[0].controls.emit(nil)
        precondition(controller.item?.tabId == 901 && controller.isExpanded,
                     "A requested track change must retain the card during a native session gap")
        let count = f.tabs[0].controls.actions.count
        controller.perform(.playPause, for: before, from: .docked)
        precondition(f.tabs[0].controls.actions.count == count, "Retained controls must not act on stale media")
        f.tabs[0].controls.emit(snapshot("Second track", token: "second", source: "second"))
        precondition(controller.item?.tabId == 901 && controller.item?.playback.title == "Second track"
                     && controller.isExpanded, "Track metadata must update without collapsing the card")
        // Metadata can reach the browser before the replacement player exists.
        f.tabs[0].controls.emit(nil)
        precondition(controller.item?.tabId == 901 && controller.isExpanded,
                     "A late native gap after new metadata must not flash the card")
        f.tabs[0].controls.emit(snapshot("Second track", token: "second", source: "second"))
        await tick(350)
        f.tabs[0].controls.emit(nil)
        precondition(controller.item?.tabId == 902,
                     "Ordinary media removal must still apply the existing visibility policy")
        value["sourceToken"] = "third"
        value["token"] = "third"
        f.tabs[0].controls.emit(value)
        let anchor = require(controller.item)
        controller.perform(.nextTrack, for: anchor, from: .docked)
        controller.cycleSource(for: anchor, from: .docked)
        await tick()
        precondition(controller.item?.tabId == 902 && !controller.isChangingTrack,
                     "An explicit source cycle must cancel the pending track hold")
        f.tabs[0].controls.emit(snapshot("Late track", token: "late", source: "late"))
        precondition(controller.item?.tabId == 902, "Late track completion must not steal a manually cycled card")
    }

    @MainActor
    static func pictureInPictureHidesAndRestoresSource() async {
        let f = Fixture([801, 802]); defer { f.stop() }
        await tick()
        let controller = f.controller
        var video = require(f.tabs[0].controls.snapshotValue)
        video["isPictureInPicture"] = true
        video["canExitPictureInPicture"] = true
        f.tabs[0].controls.emit(video)
        await tick()
        precondition(controller.isSourceVisible && controller.backgroundSourceCount == 0,
                     "PiP must hide the duplicate sidebar player and exclude it from cycling")
        precondition(!controller.isDismissed && f.tabs[0].controls.stopCount == 0,
                     "PiP must not dismiss the source or stop observing its exit")
        controller.setExpanded(true, on: .docked)
        precondition(!controller.isExpanded)
        video["playing"] = false
        f.tabs[0].controls.emit(video)
        video["isPictureInPicture"] = false
        f.tabs[0].controls.emit(video)
        await tick()
        precondition(!controller.isSourceVisible && controller.backgroundSourceCount == 1,
                     "Exiting PiP must restore the retained source even while paused")

        let multi = Fixture([811, 812, 813]); defer { multi.stop() }
        await tick()
        var first = require(multi.tabs[0].controls.snapshotValue)
        first["playing"] = false
        multi.tabs[0].controls.emit(first)
        first["isPictureInPicture"] = true
        multi.tabs[0].controls.emit(first)
        await tick()
        precondition(multi.controller.item?.tabId == 812 && multi.controller.backgroundSourceCount == 1,
                     "Other background media must remain available while a video owns PiP")
        first["isPictureInPicture"] = false
        multi.tabs[0].controls.emit(first)
        await tick()
        precondition(multi.controller.item?.tabId == 811 && multi.controller.backgroundSourceCount == 2)
    }

    @MainActor
    static func nativeTrackActions() {
        let wrapper = FakeWrapper(), controls = wrapper.fakeControls
        var value = snapshot()
        controls.snapshotValue = value
        let subscription = require(NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: "") { _ in })
        defer { subscription.close() }
        var displayed = require(subscription.snapshot(fallbackTitle: ""))
        precondition(!displayed.canPreviousTrack && !displayed.canNextTrack,
                     "Frameworks without track capabilities must retain playback but disable skipping")
        precondition(!subscription.perform(.nextTrack, expected: displayed))
        precondition(!subscription.perform(.previousTrack, expected: displayed))
        value["canPreviousTrack"] = true
        value["canNextTrack"] = true
        value["canSeek"] = false
        value.removeValue(forKey: "duration")
        controls.snapshotValue = value
        displayed = require(subscription.snapshot(fallbackTitle: ""))
        precondition(subscription.perform(.previousTrack, expected: displayed))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.previousTrack.rawValue)
        precondition(subscription.perform(.nextTrack, expected: displayed))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.nextTrack.rawValue)
        let count = controls.actions.count
        value["canNextTrack"] = false
        controls.snapshotValue = value
        precondition(!subscription.perform(.nextTrack, expected: displayed), "Recheck live queue capabilities")
        value["token"] = "new-track"
        controls.snapshotValue = value
        precondition(!subscription.perform(.previousTrack, expected: displayed), "Do not skip a replacement track")
        precondition(controls.actions.count == count)
    }

    @MainActor
    static func nativeDecodeAndOldFramework() {
        let legacy = LegacyWrapper()
        precondition(!legacy.responds(to: NSSelectorFromString("mediaControls")))
        precondition(NativeMediaAdapter.Subscription(wrapper: legacy, fallbackTitle: "") { _ in
            fatalError("Legacy framework cannot observe native media")
        } == nil)

        let wrapper = FakeWrapper(), controls = wrapper.fakeControls
        var received: [NativeMediaAdapter.Playback?] = []
        controls.snapshotValue = snapshot("  Song \n")
        let subscription = require(NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: "Fallback") {
            received.append($0)
        })
        precondition(controls.startCount == 1 && received.count == 1, "Observation must start immediately")
        let decoded = require(received.last.flatMap { $0 })
        precondition(decoded.title == "Song" && decoded.artist == "Native artist")
        precondition(decoded.currentTime == 2 && decoded.duration == 18 && decoded.canSeek)
        precondition(decoded.canPlayPause && decoded.canPictureInPicture && !decoded.isTabMuted)
        var value = snapshot("  ")
        value["artist"] = " \n"
        value["currentTime"] = -3.0
        value["tabMuted"] = true
        controls.emit(value)
        let fallback = require(received.last.flatMap { $0 })
        precondition(fallback.title == "Fallback" && fallback.artist == nil && fallback.currentTime == 0)
        precondition(fallback.isTabMuted)
        for field in ["token", "sourceToken", "playing", "muted", "tabMuted", "canPlay", "canPause",
                      "canSeek", "canEnterPictureInPicture", "canExitPictureInPicture", "isPictureInPicture"] {
            var malformed = snapshot()
            malformed.removeValue(forKey: field)
            controls.emit(malformed)
            precondition(received.last.flatMap { $0 } == nil, "Missing \(field) must fail closed")
        }
        for field in ["token", "sourceToken"] {
            var malformed = snapshot()
            malformed[field] = ""
            controls.emit(malformed)
            precondition(received.last.flatMap { $0 } == nil)
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            value = snapshot()
            value["currentTime"] = invalid
            controls.emit(value)
            let unavailable = require(received.last.flatMap { $0 })
            precondition(unavailable.currentTime == nil && !unavailable.canSeek)
            value = snapshot()
            value["duration"] = invalid
            controls.emit(value)
            precondition(require(received.last.flatMap { $0 }).duration == nil)
            precondition(!require(received.last.flatMap { $0 }).canSeek)
        }
        value = snapshot()
        value.removeValue(forKey: "currentTime")
        value.removeValue(forKey: "duration")
        controls.emit(value)
        precondition(!require(received.last.flatMap { $0 }).canSeek, "Sessions without position remain valid")
        controls.emit(nil)
        precondition(received.last.flatMap { $0 } == nil)
        subscription.close()
    }

    @MainActor
    static func nativeActionIntentAndCapabilities() {
        let wrapper = FakeWrapper(), controls = wrapper.fakeControls
        var value = snapshot()
        controls.snapshotValue = value
        let subscription = require(NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: "") { _ in })
        let displayedPlaying = require(subscription.snapshot(fallbackTitle: ""))
        value["playing"] = false
        controls.snapshotValue = value
        precondition(subscription.perform(.playPause, expected: displayedPlaying))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.pause.rawValue,
                     "A displayed pause intent must stay pause if native state changes")
        let displayedPaused = require(subscription.snapshot(fallbackTitle: ""))
        value["playing"] = true
        controls.snapshotValue = value
        precondition(subscription.perform(.playPause, expected: displayedPaused))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.play.rawValue)

        func rejected(_ action: NativeMediaAdapter.Action, expected: NativeMediaAdapter.Playback) {
            let count = controls.actions.count
            precondition(!subscription.perform(action, expected: expected))
            precondition(controls.actions.count == count, "Rejected action crossed the native boundary")
        }
        value["canPause"] = false
        controls.snapshotValue = value
        rejected(.playPause, expected: displayedPlaying)
        value["canPause"] = true
        value["canPlay"] = false
        controls.snapshotValue = value
        rejected(.playPause, expected: displayedPaused)
        value = snapshot()
        controls.snapshotValue = value
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            rejected(.seek(seconds), expected: displayedPlaying)
        }
        precondition(subscription.perform(.seek(-10), expected: displayedPlaying))
        precondition((controls.actions.last?["seconds"] as? Double) == 0)
        precondition(subscription.perform(.seek(30), expected: displayedPlaying))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.seekTo.rawValue)
        precondition((controls.actions.last?["seconds"] as? Double) == 18)
        value["canSeek"] = false
        controls.snapshotValue = value
        rejected(.seek(5), expected: displayedPlaying)
        value = snapshot(token: "replacement")
        controls.snapshotValue = value
        rejected(.seek(5), expected: displayedPlaying)
        value = snapshot(source: "other-source")
        controls.snapshotValue = value
        rejected(.playPause, expected: displayedPlaying)

        value = snapshot()
        controls.snapshotValue = value
        precondition(subscription.perform(.pictureInPicture, expected: displayedPlaying))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.enterPictureInPicture.rawValue)
        value["canEnterPictureInPicture"] = false
        controls.snapshotValue = value
        rejected(.pictureInPicture, expected: displayedPlaying)
        value["isPictureInPicture"] = true
        value["canExitPictureInPicture"] = true
        controls.snapshotValue = value
        let displayedPiP = require(subscription.snapshot(fallbackTitle: ""))
        precondition(subscription.perform(.pictureInPicture, expected: displayedPiP))
        precondition((controls.actions.last?["action"] as? NSNumber)?.intValue == PhiMediaControlAction.exitPictureInPicture.rawValue)
        value["canExitPictureInPicture"] = false
        controls.snapshotValue = value
        rejected(.pictureInPicture, expected: displayedPiP)
        value["canExitPictureInPicture"] = true
        value["isPictureInPicture"] = false
        controls.snapshotValue = value
        precondition(!require(subscription.snapshot(fallbackTitle: "")).canExitPictureInPicture)
        rejected(.pictureInPicture, expected: displayedPiP)
        controls.snapshotValue = snapshot()
        controls.acceptsActions = false
        precondition(!subscription.perform(.playPause, expected: displayedPlaying), "Native dispatch failure must propagate")
        subscription.close()
    }

    @MainActor
    static func nativeObservationLifecycle() {
        let wrapper = FakeWrapper(), controls = wrapper.fakeControls
        controls.snapshotValue = snapshot()
        controls.rotateTokenOnStart = true
        var deliveries = 0
        var subscription: NativeMediaAdapter.Subscription? = require(
            NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: "") { _ in deliveries += 1 })
        let original = require(subscription?.snapshot(fallbackTitle: ""))
        precondition(original.token == "observation-1")
        subscription?.close()
        subscription?.close()
        precondition(controls.stopCount == 1, "Close must be idempotent")
        controls.emitStopped(snapshot("Obsolete observer"))
        precondition(deliveries == 1, "Stopped observer callback escaped generation guard")
        precondition(subscription?.snapshot(fallbackTitle: "") == nil)
        precondition(subscription?.perform(.playPause, expected: original) == false)
        subscription = nil
        precondition(controls.stopCount == 1)
        subscription = NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: "") { _ in deliveries += 1 }
        let restarted = require(subscription?.snapshot(fallbackTitle: ""))
        precondition(restarted.token != original.token && restarted.sourceToken == original.sourceToken)
        precondition(subscription?.perform(.playPause, expected: original) == false)
        precondition(subscription?.perform(.playPause, expected: restarted) == true)
        controls.emitStopped(snapshot("Late old generation"))
        precondition(deliveries == 2)
        subscription = nil
        precondition(controls.stopCount == 2, "Subscription deinit must stop native observation")
    }

    @MainActor
    static func sourceIdentityAndDismissal() async {
        let f = Fixture([1, 2]); defer { f.stop() }
        await tick()
        let tab = f.tabs[0], controller = f.controller
        precondition(controller.item?.tabId == 1 && !controller.isSourceVisible)
        let old = require(controller.item)
        controller.dismissCurrent(for: old, from: .docked)
        precondition(controller.isDismissed)
        var value = snapshot("Changed presentation", token: "fresh-control-token", source: "source-1")
        tab.controls.emit(value)
        await tick()
        precondition(controller.isDismissed, "Presentation/token refresh must preserve source dismissal")
        f.state.focusingTab = tab
        await tick()
        f.state.focusingTab = f.tabs[1]
        await tick()
        precondition(controller.isDismissed, "Tab switching must preserve dismissal")
        value = snapshot("Replacement track", token: "track-token", source: "new-track")
        tab.controls.emit(value)
        await tick()
        precondition(!controller.isDismissed && controller.item?.playback.title == "Replacement track")
        let before = tab.controls.actions.count
        controller.perform(.seek(8), for: old, from: .docked)
        controller.showTab(for: old, from: .docked)
        controller.toggleMute(for: old, from: .docked)
        controller.dismissCurrent(for: old, from: .docked)
        precondition(tab.controls.actions.count == before && tab.fakeWrapper.activationCount == 0)
        precondition(!tab.isAudioMuted && !controller.isDismissed, "Stale rendered callbacks affected replacement source")
        let fresh = require(controller.item)
        controller.perform(.seek(8), for: fresh, from: .floating)
        precondition(tab.controls.actions.count == before, "Wrong-surface action must be rejected")
        controller.perform(.seek(8), for: fresh, from: .docked)
        await tick()
        precondition(tab.controls.actions.count == before + 1)
        controller.showTab(for: fresh, from: .docked)
        precondition(tab.fakeWrapper.activationCount == 1)
        controller.toggleMute(for: fresh, from: .docked)
        precondition(tab.isAudioMuted && controller.item?.isTabMuted == true)
        value["token"] = "same-source-new-token"
        tab.controls.emit(value)
        await tick()
        precondition(!controller.matchesCurrentSource(fresh), "Control token changes must invalidate rendered callbacks")
        let actionsAfterRefresh = tab.controls.actions.count
        controller.perform(.playPause, for: fresh, from: .docked)
        precondition(tab.controls.actions.count == actionsAfterRefresh)
    }

    @MainActor
    static func navigationWrapperReplacementAndTeardown() async {
        let f = Fixture([10, 11]); defer { f.stop() }
        await tick()
        let tab = f.tabs[0], oldControls = tab.controls
        let oldItem = require(f.controller.item)
        tab.isLoading = true
        await tick()
        precondition(f.controller.item == nil, "Same-URL document replacement must invalidate selection")
        oldControls.emitStopped(snapshot("Old document"))
        await tick()
        precondition(f.controller.item == nil)
        oldControls.snapshotValue = snapshot("New document", token: "new-document-token", source: "new-document")
        tab.isLoading = false
        await tick()
        precondition(f.controller.item?.playback.title == "New document")
        precondition(!f.controller.matchesCurrentSource(oldItem))
        let wrapper = FakeWrapper()
        wrapper.fakeControls.snapshotValue = snapshot("New wrapper", token: "new-wrapper-token", source: "new-wrapper")
        tab.setWebContentsWrapper(wrapper: wrapper)
        await tick()
        precondition(f.controller.item?.wrapperId == ObjectIdentifier(wrapper))
        precondition(f.controller.item?.playback.title == "New wrapper")
        oldControls.emitStopped(snapshot("Obsolete wrapper"))
        await tick()
        precondition(f.controller.item?.playback.title == "New wrapper")
        tab.url = "https://example.test/same-document-route"
        await tick()
        precondition(f.controller.item?.pageURL == tab.url
                     && f.controller.item?.playback.title == "New wrapper",
                     "Same-document URL changes must re-read native state without awaiting another media event")
        tab.url = "https://example.test/new-page"
        tab.isLoading = true
        await tick()
        precondition(f.controller.item == nil)
        tab.setWebContentsWrapper(wrapper: LegacyWrapper())
        tab.isLoading = false
        await tick()
        precondition(f.controller.item == nil, "Older framework must fail closed")
        tab.setWebContentsWrapper(wrapper: nil)
        await tick()
        precondition(f.controller.item == nil)
        tab.setWebContentsWrapper(wrapper: wrapper)
        await tick()
        precondition(f.controller.item?.wrapperId == ObjectIdentifier(wrapper),
                     "Restoring a wrapper must restart observation after a nil wrapper")

        let state = BrowserState(), media = Tab(12), foreground = Tab(13)
        media.controls.snapshotValue = snapshot()
        media.isCurrentlyAudible = true
        state.tabs = [media, foreground]
        state.focusingTab = foreground
        var controller: SidebarMediaController? = SidebarMediaController(browserState: state)
        weak let weakController = controller
        controller?.setActive(true)
        await tick()
        let stops = media.controls.stopCount
        controller = nil
        await tick()
        precondition(weakController == nil && media.controls.stopCount == stops + 1,
                     "Controller teardown must release observer ownership")
    }

    @MainActor
    static func immediateRemovedTabActionsAreRejected() async {
        let f = Fixture([14, 15]); defer { f.stop() }
        await tick()
        let controller = f.controller, tab = f.tabs[0]
        let displayed = require(controller.item)
        let actions = tab.controls.actions.count
        let activations = tab.fakeWrapper.activationCount
        let muted = tab.isAudioMuted
        f.state.tabs.removeAll { $0 === tab }
        // The queued Combine removal has not run. Live membership must gate actions.
        controller.perform(.playPause, for: displayed, from: .docked)
        controller.showTab(for: displayed, from: .docked)
        controller.toggleMute(for: displayed, from: .docked)
        precondition(tab.controls.actions.count == actions,
                     "Removed tab accepted playback before the queued state update")
        precondition(tab.fakeWrapper.activationCount == activations,
                     "Removed tab accepted activation before the queued state update")
        precondition(tab.isAudioMuted == muted,
                     "Removed tab accepted mute before the queued state update")
        await tick()
        precondition(controller.item == nil && !tab.controls.isObserving)
    }

    @MainActor
    static func reentrantWrapperObservationTeardown() async {
        let f = Fixture([16, 17]); defer { f.stop() }
        await tick()
        let replacement = FakeWrapper(), controls = replacement.fakeControls
        controls.snapshotValue = snapshot("Synchronous replacement", token: "reentrant-token", source: "reentrant-source")
        var deactivated = false
        let observer = f.controller.$item.dropFirst().sink { item in
            guard item?.wrapperId == ObjectIdentifier(replacement), !deactivated else { return }
            deactivated = true
            f.controller.setSessions([], presented: nil)
        }
        defer { observer.cancel() }
        f.tabs[0].setWebContentsWrapper(wrapper: replacement)
        await tick()
        precondition(deactivated && f.controller.activeSurface == nil,
                     "Replacement's synchronous initial publication must trigger teardown")
        precondition(controls.startCount == 1 && controls.stopCount == 1 && !controls.isObserving,
                     "Reentrant teardown must close the newly registered native subscription exactly once")
        precondition(f.controller.item == nil,
                     "A removed session must not leave an actionable source")
        let retained = f.controller.item
        controls.emit(snapshot("Unexpected live event", token: "live-late", source: "live-late"))
        controls.emitStopped(snapshot("Late initial observer", token: "stopped-late", source: "stopped-late"))
        await tick()
        precondition(f.controller.item == retained && controls.stopCount == 1 && !controls.isObserving,
                     "Stopped replacement observer must not revive the inactive controller")
    }

    @MainActor
    static func disabledObservationResumes() async {
        let f = Fixture([20, 21]); defer { f.stop() }
        await tick()
        let tab = f.tabs[0], controls = tab.controls, controller = f.controller
        let old = require(controller.item)
        let starts = controls.startCount, stops = controls.stopCount
        f.enabled(false)
        await tick()
        precondition(controller.isRevalidating && controls.stopCount == stops + 1)
        let actions = controls.actions.count
        controller.perform(.playPause, for: old, from: .docked)
        controls.emitStopped(snapshot("Late old callback"))
        await tick()
        precondition(controls.actions.count == actions && controller.item?.playback.title == old.playback.title)
        controls.snapshotValue = snapshot("After hidden navigation", token: "after-hidden", source: "after-hidden")
        f.enabled(true)
        await tick()
        await tick()
        precondition(controls.startCount == starts + 1 && !controller.isRevalidating)
        precondition(controller.item?.playback.title == "After hidden navigation")
        controls.emitStopped(snapshot("Older activation"))
        await tick()
        precondition(controller.item?.playback.title == "After hidden navigation")
        controller.setActive(true, on: .floating)
        controller.setActive(false, on: .docked)
        await tick()
        precondition(controller.activeSurface == .floating && controls.startCount == starts + 1,
                     "Surface handoff must preserve the native observation")
    }

    @MainActor
    static func visitOrderCyclingFocusAndSplit() async {
        let f = Fixture([30, 31, 32, 33, 34, 35, 36, 37]); defer { f.stop() }
        await tick()
        let controller = f.controller
        precondition(controller.item?.tabId == 30 && controller.backgroundSourceCount == 7,
                     "Full visit history must discover sources beyond the five-tab switcher")
        for destination in [31, 32, 33, 34, 35, 36, 30] {
            controller.cycleSource(for: require(controller.item), from: .docked)
            await tick()
            precondition(controller.item?.tabId == destination)
        }
        controller.cycleSource(for: require(controller.item), direction: .previous, from: .docked)
        await tick()
        precondition(controller.item?.tabId == 36 && controller.cycleDirection == .previous)
        precondition(f.state.focusingTab === f.tabs.last && f.tabs.allSatisfy { $0.controls.actions.isEmpty },
                     "Cycling must change only the presented source")
        f.tabs[0].controls.emit(snapshot("Routine update", token: "fresh-30", source: "source-30"))
        await tick()
        precondition(controller.item?.tabId == 36, "Native updates must preserve explicit source choice")
        f.state.focusingTab = f.tabs[6]
        await tick()
        precondition(controller.item?.tabId == 30 && controller.backgroundSourceCount == 6)
        f.state.splits = [FakeSplitGroup(first: 30, second: 36)]
        await tick()
        precondition(controller.item?.tabId == 31 && controller.backgroundSourceCount == 5,
                     "Both visible split panes must be excluded")
        f.state.splits = []
        f.state.focusingTab = f.tabs.last
        await tick()
        precondition(controller.item?.tabId == 36, "Playing media visits must restore MRU selection")
        f.tabs[6].controls.emit(snapshot("Paused", token: "pause-36", source: "source-36", playing: false))
        await tick()
        precondition(controller.item?.tabId == 36, "Selected paused source must remain available")
        f.tabs[6].controls.emit(nil)
        await tick()
        precondition(controller.item?.tabId == 30, "Ended session must fall back to next visited source")
        f.state.tabs.removeAll { $0.guid == 30 }
        await tick()
        precondition(controller.item?.tabId == 31, "Closed tab must fall back without stale cache selection")
    }

    @MainActor
    static func cycleRevalidationAndStaleCallbacks() async {
        let f = Fixture([40, 41, 42, 43]); defer { f.stop() }
        await tick()
        let controller = f.controller
        let first = require(controller.item)
        f.tabs[1].controls.snapshotValue = snapshot("Replaced before click", token: "replacement", source: "replacement")
        controller.cycleSource(for: first, from: .docked)
        await tick()
        precondition(controller.item?.tabId == 40, "Cycle must revalidate the cached destination identity")
        f.tabs[1].controls.emit(snapshot("Media 41", token: "token-41", source: "source-41"))
        await tick()
        controller.cycleSource(for: first, from: .docked)
        controller.setActive(true, on: .floating)
        await tick()
        precondition(controller.item?.tabId == 40, "Surface transfer must cancel queued cycling")
        controller.cycleSource(for: require(controller.item), from: .floating)
        controller.cycleSource(for: require(controller.item), from: .floating)
        await tick()
        precondition(controller.item?.tabId == 42, "Rapid cycle intents must advance from the pending destination")
        let chosen = require(controller.item)
        controller.perform(.playPause, for: first, from: .floating)
        controller.dismissCurrent(for: first, from: .floating)
        precondition(f.tabs[0].controls.actions.isEmpty && !controller.isDismissed)
        f.tabs[2].controls.emit(snapshot("New source 42", token: "new-42", source: "new-source-42"))
        await tick()
        precondition(!controller.matchesCurrentSource(chosen))
        controller.perform(.seek(9), for: chosen, from: .floating)
        precondition(f.tabs[2].controls.actions.isEmpty)
    }

    @MainActor
    static func preferencesPresentationAndHover() async {
        let f = Fixture([50, 51]); defer { f.stop() }
        await tick()
        let controller = f.controller, controls = f.tabs[0].controls
        controller.setHovering(true, on: .docked)
        await tick(40)
        precondition(!controller.isExpanded, "A passing pointer must not expand the player immediately")
        await tick(180)
        precondition(controller.isExpanded, "Hover should reveal details within 220ms")
        controller.setExpanded(false, on: .docked)
        controller.setHovering(true, on: .docked)
        await tick(40)
        controller.setHovering(false, on: .docked)
        await tick(180)
        precondition(!controller.isExpanded, "Short hover must cancel delayed expansion")
        f.mode(.alwaysExpanded)
        await tick()
        precondition(controller.isExpanded && controller.presentationMode == .alwaysExpanded)
        controller.setExpanded(false, on: .docked)
        precondition(controller.isExpanded)
        f.mode(.alwaysCompact)
        await tick()
        controller.setExpanded(true, on: .docked)
        precondition(!controller.isExpanded)
        f.mode(.dynamic)
        await tick()
        controller.setHovering(true, on: .docked)
        controller.setActive(true, on: .floating)
        await tick(180)
        precondition(!controller.isExpanded, "Surface transfer must cancel dwell")
        controller.setHovering(true, on: .floating)
        f.mode(.alwaysCompact)
        await tick(180)
        precondition(!controller.isExpanded, "Preference changes must cancel dwell")
        let starts = controls.startCount, actions = controls.actions.count
        f.enabled(false)
        await tick()
        precondition(!controller.isEnabled && controller.activeSurface == nil)
        f.tabs[0].isCurrentlyAudible = false
        f.tabs[0].isCurrentlyAudible = true
        controls.emitStopped(snapshot("Stopped"))
        await tick()
        precondition(controls.startCount == starts && controls.actions.count == actions,
                     "Disabled player must neither observe nor change playback")
        precondition(controller.presentationMode == .alwaysCompact)
        f.enabled(true)
        await tick()
        precondition(controller.isEnabled && controller.presentationMode == .alwaysCompact)
        precondition(controls.startCount == starts + 1 && !controller.isExpanded)
    }

    @MainActor
    static func volumeClosesOnHoverExit() async {
        let f = Fixture([50, 51]); defer { f.stop() }
        await tick()
        let controller = f.controller
        for surface: SidebarMediaController.Surface in [.docked, .floating] {
            controller.setActive(true, on: surface)
            for mode: SidebarMediaPresentationMode in [.dynamic, .alwaysExpanded, .alwaysCompact] {
                f.mode(mode)
                await tick()
                controller.setHovering(true, on: surface)
                controller.volumeButtonClicked(for: require(controller.item), from: surface,
                                               optionPressed: false)
                precondition(controller.isVolumeExpanded)
                let expanded = controller.isExpanded
                let otherSurface: SidebarMediaController.Surface = surface == .docked ? .floating : .docked
                controller.setHovering(false, on: otherSurface)
                precondition(controller.isVolumeExpanded, "An inactive surface must not close the slider")
                controller.setHovering(false, on: surface)
                precondition(!controller.isVolumeExpanded, "Hover exit must close volume immediately in every mode")
                precondition(controller.isExpanded == expanded, "Volume collapse must preserve the presentation mode")
            }
        }
    }

    @MainActor
    static func heightAnimationReversesAndCancels() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 193, height: 200))
        let host = SidebarMediaHostingView(rootView: AnyView(Text(verbatim: "Animated player")))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        let height = host.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor), height
        ])
        container.layoutSubtreeIfNeeded()
        let bottom = host.frame.minY
        var renderedHeights: [CGFloat] = []
        let update: (CGFloat) -> Void = { value in
            height.constant = value
            container.layoutSubtreeIfNeeded()
            renderedHeights.append(host.frame.height)
            precondition(abs(host.frame.minY - bottom) < 0.5, "Resizing must keep the player above the footer")
        }
        host.animateHeight(to: 124, update: update)
        await tick(65)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(host.frame.height > 38 && host.frame.height < 124,
                         "Expansion must render intermediate content heights")
        }
        let turnHeight = host.frame.height
        host.animateHeight(to: 38, update: update)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(host.frame.height == turnHeight, "Reversing must start at the visible height")
        }
        await tick(260)
        precondition(abs(host.frame.height - 38) < 0.5, "Collapse must reach the compact height")
        host.animateHeight(to: 124, update: update)
        await tick(65)
        host.cancelHeightAnimation()
        let cancelledHeight = host.frame.height, updates = renderedHeights.count
        await tick(240)
        precondition(host.frame.height == cancelledHeight && renderedHeights.count == updates,
                     "A removed or hidden player's cancelled animation must stop updating layout")
    }

    @MainActor
    static func physicalTrackpadDirectionsAndSingleCommit() async {
        let f = Fixture([140, 141, 142, 143]); defer { f.stop() }
        await tick()
        let controller = f.controller
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
                  inverted: Bool) -> Bool {
            if inverted {
                return host.handleMediaSwipe(deltaX: deltaX, deltaY: deltaY, phase: phase,
                    momentum: momentum, timestamp: timestamp, isDirectionInvertedFromDevice: true)
            }
            // Construct unposted native events; no input is sent to the desktop.
            let cg = require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let scrollPhase: CGScrollPhase? = phase == .began ? .began
                : phase == .changed ? .changed : phase == .ended ? .ended : nil
            let momentumPhase: CGMomentumScrollPhase = momentum == .began ? .begin
                : momentum == .changed ? .continuous : momentum == .ended ? .end : .none
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
            cg.timestamp = UInt64(timestamp * 1_000_000_000)
            let event = require(NSEvent(cgEvent: cg))
            precondition(event.phase == phase && event.momentumPhase == momentum
                         && !event.isDirectionInvertedFromDevice && event.scrollingDeltaX == deltaX)
            host.scrollWheel(with: event)
            return true
        }
        var timestamp: TimeInterval = 0
        for inverted in [true, false] {
            for (physicalLeft, destination) in [(true, 141), (true, 142), (false, 141), (false, 140)] {
                let rawDelta: CGFloat = (physicalLeft ? 50 : -50) * (inverted ? -1 : 1)
                let publicationsBefore = publications
                timestamp += 1
                precondition(send(deltaX: 0, deltaY: 0, phase: .began,
                    momentum: [], timestamp: timestamp, inverted: inverted))
                precondition(send(deltaX: rawDelta, deltaY: 1, phase: .changed,
                    momentum: [], timestamp: timestamp + 0.05, inverted: inverted))
                precondition(send(deltaX: 0, deltaY: 0, phase: .ended,
                    momentum: [], timestamp: timestamp + 0.1, inverted: inverted))
                _ = send(deltaX: 0, deltaY: 0, phase: .ended,
                    momentum: [], timestamp: timestamp + 0.11, inverted: inverted)
                _ = send(deltaX: rawDelta, deltaY: 0, phase: [],
                    momentum: .began, timestamp: timestamp + 0.12, inverted: inverted)
                _ = send(deltaX: rawDelta, deltaY: 0, phase: [],
                    momentum: .changed, timestamp: timestamp + 0.13, inverted: inverted)
                _ = send(deltaX: 0, deltaY: 0, phase: [],
                    momentum: .ended, timestamp: timestamp + 0.14, inverted: inverted)
                await tick()
                let direction: SidebarMediaController.CycleDirection = physicalLeft ? .next : .previous
                precondition(controller.item?.tabId == destination && controller.cycleDirection == direction,
                             "Physical left-left-right-right must follow A→B→C→B→A")
                precondition(publications == publicationsBefore + 1,
                             "A physical swipe published more than one source transition")
                precondition(oldRemoval.horizontalOffset == (physicalLeft ? -193 : 193)
                             && oldInsertion.horizontalOffset == (physicalLeft ? 193 : -193),
                             "Existing transitions must read the latest direction")
            }
        }
        subscription.cancel()
    }

    @MainActor
    static func gestureCancellation() async {
        let f = Fixture([150, 151, 152]); defer { f.stop() }
        await tick()
        let controller = f.controller
        let host = SidebarMediaHostingView(rootView: AnyView(Text(verbatim: "Cancellation test")))
        host.frame.size = NSSize(width: 193, height: 124)
        host.mediaController = controller
        func send(_ x: CGFloat, _ y: CGFloat, _ phase: NSEvent.Phase, _ time: Double) -> Bool {
            host.handleMediaSwipe(deltaX: x, deltaY: y, phase: phase,
                                  momentum: [], timestamp: time, isDirectionInvertedFromDevice: true)
        }
        precondition(send(0, 0, .began, 1))
        precondition(!send(1, 40, .changed, 1.05), "Vertical scrolling must pass through")
        _ = send(0, 0, .ended, 1.1)
        precondition(send(0, 0, .began, 2))
        precondition(send(-50, 0, .changed, 2.05))
        f.tabs[0].controls.emit(snapshot("Replacement during gesture", token: "gesture-new", source: "gesture-new"))
        await tick()
        precondition(host.isMediaSwipeCancelled, "Source replacement must cancel the claimed gesture")
        precondition(send(-30, 0, .changed, 2.1))
        precondition(send(0, 0, .ended, 2.15))
        await tick()
        precondition(controller.item?.tabId == 150 && controller.cycleAnimationGeneration == 0,
                     "Cancelled gesture must not adopt or cycle the replacement source")
    }
}

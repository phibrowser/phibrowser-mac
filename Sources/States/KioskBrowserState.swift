// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// Decides how an external URL should combine URL Rules with the user's Kiosk
/// preference. A deterministic user-Space rule supplies the identity for the
/// Kiosk, while Ask, Incognito, explicit Kiosk, and unmatched URLs retain their
/// established routing paths. "Ask every time" is checked before the rule's
/// target, including the Kiosk target, matching Chromium's URL router: the
/// target is only the chooser's suggested default.
enum ExternalKioskURLRuleResolver {
    enum Decision: Equatable {
        case useKiosk
        case useKioskWithSpaceIdentity(String)
        case ask(defaultSpaceId: String)
        case openInSpace(String)
    }

    static func decision(
        for url: URL,
        rules: [SpaceRoutingRule]
    ) -> Decision {
        guard let rule = URLRouter.matchingRule(for: url, rules: rules) else {
            return .useKiosk
        }
        if rule.askBeforeRouting {
            return .ask(defaultSpaceId: rule.spaceId)
        }
        if rule.spaceId == SpaceManager.kioskRuleTargetId {
            return .useKiosk
        }
        if SpaceManager.isIncognitoSpaceId(rule.spaceId) {
            return .openInSpace(rule.spaceId)
        }
        return .useKioskWithSpaceIdentity(rule.spaceId)
    }

    /// The destination for an external open claimed by an App rule. App rules
    /// ignore the Kiosk preference, so a Space target opens in that Space;
    /// "Ask every time" still wins over every target, Kiosk included.
    static func sourceAppRuleDecision(
        for rule: SpaceRoutingRule
    ) -> Decision {
        if rule.askBeforeRouting {
            return .ask(defaultSpaceId: rule.spaceId)
        }
        if rule.spaceId == SpaceManager.kioskRuleTargetId {
            return .useKiosk
        }
        return .openInSpace(rule.spaceId)
    }
}

/// Window-scoped state for the ephemeral Kiosk browser surface.
///
/// It deliberately remains a BrowserState so Chromium tab events keep using
/// the established EventBus and window registry. The overrides remove the
/// persisted tab-order, bookmark, split, and Space behavior that does not
/// belong in a single-WebContents window.
final class KioskBrowserState: BrowserState {
    /// The URL Rule's preferred Open in Space destination, not Space membership.
    /// Keep it window-scoped even when several Spaces share the same profile.
    @Published var preferredSpaceId: String? = nil

    @MainActor
    init(windowId: Int,
         localStore: LocalStore,
         profileId: String,
         isIncognito: Bool) {
        super.init(
            windowId: windowId,
            localStore: localStore,
            profileId: profileId,
            spaceId: SpaceManager.shared.currentDefaultSpaceId,
            isIncognito: isIncognito,
            isIncognitoSpace: false,
            isKioskWindow: true
        )
        aiChatCollapsed = true
    }

    override func handleNewTabFromChromium(
        _ tab: Tab,
        context: NativeTabCreationContext? = nil
    ) {
        guard !tabs.contains(where: { $0.guid == tab.guid }) else { return }
        tab.profileId = profileId
        tabs.append(tab)
        normalTabs = tabs
        if focusingTab == nil {
            setFocusedTab(tab)
        }
    }

    @MainActor
    override func handleRestoredWindowSnapshot(
        _ snapshot: BrowserState.RestoredWindowSnapshot
    ) {
        for item in snapshot.tabs {
            handleNewTabFromChromium(item.tab, context: item.context)
        }
        if let activeTabId = snapshot.activeTabId {
            handleChromiumActiveTabChanged(activeTabId)
        }
    }

    @MainActor
    override func handleInsertedTabsSnapshot(_ snapshot: BrowserState.RestoredWindowSnapshot) {
        handleRestoredWindowSnapshot(snapshot)
    }

    @MainActor
    override func handleChromiumActiveTabChanged(_ tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else { return }
        setFocusedTab(tab)
    }

    @MainActor
    override func closeTab(_ tabId: Int) {
        applyTabsRemoved([tabId])
    }

    @MainActor
    override func applyTabsRemoved(_ tabIds: [Int], indices: [Int: Int]? = nil,
                                   activeTabId: Int? = nil) {
        let removed = Set(tabIds)
        tabs.removeAll { removed.contains($0.guid) }
        normalTabs = tabs
        if let activeTabId {
            setFocusedTab(tabs.first { $0.guid == activeTabId })
        } else if let focusedID = focusingTab?.guid, removed.contains(focusedID) {
            setFocusedTab(tabs.first)
        }
    }

    override func updateTabTitle(tabId: Int, newTitle: String) {
        tabs.first(where: { $0.guid == tabId })?.title = newTitle
    }

    override func handleTabReadyToDisplay(tabId: Int) {
        guard tabs.contains(where: { $0.guid == tabId }) else { return }
        windowController?.handleTabReadyToDisplay(tabId: tabId)
    }

    private func setFocusedTab(_ tab: Tab?) {
        for candidate in tabs {
            candidate.isActive = candidate === tab
        }
        focusingTab = tab
    }
}

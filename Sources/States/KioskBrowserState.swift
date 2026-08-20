// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Window-scoped state for the ephemeral Kiosk browser surface.
///
/// It deliberately remains a BrowserState so Chromium tab events keep using
/// the established EventBus and window registry. The overrides remove the
/// persisted tab-order, bookmark, split, and Space behavior that does not
/// belong in a single-WebContents window.
final class KioskBrowserState: BrowserState {
    @MainActor
    init(windowId: Int,
         localStore: LocalStore,
         profileId: String,
         isIncognito: Bool) {
        super.init(
            windowId: windowId,
            localStore: localStore,
            profileId: profileId,
            spaceId: LocalStore.defaultSpaceId,
            isIncognito: isIncognito,
            isIncognitoSpace: false,
            isKioskWindow: true
        )
        sidebarCollapsed = true
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
    override func handleChromiumActiveTabChanged(_ tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else { return }
        setFocusedTab(tab)
    }

    @MainActor
    override func closeTab(_ tabId: Int) {
        tabs.removeAll { $0.guid == tabId }
        normalTabs = tabs
        if focusingTab?.guid == tabId {
            setFocusedTab(tabs.first)
        }
    }

    override func updateTabTitle(tabId: Int, newTitle: String) {
        tabs.first(where: { $0.guid == tabId })?.title = newTitle
    }

    override func handlePreviousTabReadyForCleanup(tabId: Int) {
        windowController?.handlePreviousTabReadyForCleanup(tabId: tabId)
    }

    override func handleTabReadyToDisplay(tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else { return }
        tab.hasFirstPaint = true
        windowController?.handleTabReadyToDisplay(tabId: tabId)
    }

    func navigateCurrentWebContents(to userInput: String) {
        let normalizedURL = URLProcessor.processUserInput(userInput)
        focusingTab?.webContentWrapper?.navigate(toURL: normalizedURL)
    }

    private func setFocusedTab(_ tab: Tab?) {
        for candidate in tabs {
            candidate.isActive = candidate === tab
        }
        focusingTab = tab
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
/// Routes bridge events to the owning window-scoped state.
enum EventScope {
    case window(browserId: Int)
    case profile(profileId: Int)
    case global
}

protocol AppEvent {
    var scope: EventScope { get }
}

protocol WindowEvent: AppEvent {
    var browserId: Int? { get }
}

struct TabEvent: WindowEvent {
    var browserId: Int?
    var scope: EventScope {
        if let browserId {
            return .window(browserId: browserId)
        } else {
            return .global
        }
    }
    let action: TabAction

    enum TabAction {
        case newTab(_ tab: Tab)
        case newTabWithContext(_ tab: Tab, context: NativeTabCreationContext)
        case closeTab(_ tabId: Int)
        case focusTab(_ tab: Tab)
        case focusTabWithTabId(_ tabId: Int)
        case createTab(_ url: String)
        case openTab(_ url: String)
        case updateTabTitle(tabId: Int, newTitle: String)
        case updateTabIndex(_ indexesMap: [Int: Int])
        case updateTabRelationships(_ snapshot: NativeTabRelationshipSnapshot)
        case move(tab: Tab, toNewIndex: Int, selectAfterMove: Bool)

        /// Chromium has hidden the previous tab and the native view can be released.
        case previousTabReadyForCleanup(_ tabId: Int)

        /// Chromium produced the first non-empty paint for the tab.
        case tabReadyToDisplay(_ tabId: Int)

        /// Content-fullscreen entered/exited on a tab (HTML5 requestFullscreen).
        case tabContentFullscreenChanged(tabId: Int, isFullscreen: Bool)
    }
}

struct OmniEvent: WindowEvent {
    var browserId: Int?
    var scope: EventScope {
        if let browserId {
            return .window(browserId: browserId)
        } else {
            return .global
        }
    }
    
    let action: OmniAction
    
    enum OmniAction {
        case searchSuggestionResultChanged(suggestions: [[String: Any]], originalInput: String)
    }
}

struct BookmarkEvent: WindowEvent {
    var browserId: Int?
    var scope: EventScope {
        if let browserId {
            return .window(browserId: browserId)
        } else {
            return .global
        }
    }
    let action: BookmarkAction
    
    enum BookmarkAction {
        case bookmarksLoaded
        case bookmarksChanged(_ newNodes: [any BookmarkWrapper])
        case bookmarkInfoChanged(id: Int64, title: String?, url: String?, faviconUrl: String?)
    }
}

struct ExtensionEvent: WindowEvent {
    var browserId: Int?
    var scope: EventScope {
        if let browserId {
            return .window(browserId: browserId)
        } else {
            return .global
        }
    }
    let action: ExtensionAction
    
    enum ExtensionAction {
        case extensionChanged(info: [[AnyHashable : Any]])
    }
}


class EventBus {
    static let shared = EventBus()
    func send<T: AppEvent>(_ event: T) {
             switch event.scope {
             case .window(let windowId):
                 Task { @MainActor in
                     handleWindowEvent(event, windowId: windowId)
                 }

             case .profile:
                 fatalError("not support")

             case .global: fatalError("not support")
             }
    }
    
    @MainActor
    private func handleWindowEvent<T: AppEvent>(_ event: T, windowId: Int) {
        guard let browserState = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId) else {
            AppLogWarn("Window not found for id: \(windowId)")
            return
        }
        switch event {
        case let tabEvent as TabEvent:
            handleTabEvent(tabEvent, in: browserState)
        case let omniEvent as OmniEvent:
            handleOmniEvent(omniEvent, in: browserState)
        case let bookmarkEvent as BookmarkEvent:
            handleBookmarkEvent(bookmarkEvent, in: browserState)
        case let extensionEvent as ExtensionEvent:
            handleExtensionEvent(extensionEvent, in: browserState)
        default:  fatalError("not support")
        }
    }
    
    @MainActor
    private func handleTabEvent(_ event: TabEvent, in state: BrowserState) {
        switch event.action {
        case .newTab(let tab):
            state.handleNewTabFromChromium(tab)
        case .newTabWithContext(let tab, let context):
            state.handleNewTabFromChromium(tab, context: context)
        case .closeTab(let tabId):
            state.closeTab(tabId)
        case .focusTab(let tab):
            state.focuseTab(tab)
        case .focusTabWithTabId(let tabId):
            state.handleChromiumActiveTabChanged(tabId)
        case .createTab(let url):
            state.createTab(url)
        case .openTab(let url):
            state.openTab(url)
        case .updateTabTitle(let tabId, let newTitle):
            state.updateTabTitle(tabId: tabId, newTitle: newTitle)
        case .updateTabIndex(let indexesMap):
            state.reorderTabs(indexesMap)
        case .updateTabRelationships(let snapshot):
            state.applyRelationshipSnapshot(snapshot)
        case .move(let tab, let toNewIndex, let selectAfterMove):
            state.move(tab: tab, to: toNewIndex, selectAfterMove: selectAfterMove)
        case .previousTabReadyForCleanup(let tabId):
            state.handlePreviousTabReadyForCleanup(tabId: tabId)
        case .tabReadyToDisplay(let tabId):
            state.handleTabReadyToDisplay(tabId: tabId)
        case .tabContentFullscreenChanged(let tabId, let isFullscreen):
            state.handleTabContentFullscreen(tabId: tabId, isFullscreen: isFullscreen)
        }
    }

    private func handleOmniEvent(_ event: OmniEvent, in state: BrowserState) {
        switch event.action {
        case .searchSuggestionResultChanged(let suggestions, let input):
            state.searchSuggestionChanged.send((suggestions, input))
        }
    }
    
    private func handleBookmarkEvent(_ event: BookmarkEvent, in state: BrowserState) {
        switch event.action {
        case .bookmarksLoaded:
            state.bookmarkManager.fetchBookmarks()
        case .bookmarksChanged(let newNodes):
            state.bookmarkManager.bookmarksChanged(with: newNodes)
        case .bookmarkInfoChanged(let id, let title, let url, let faviconUrl):
            return
        @unknown default: fatalError()
        }
    }
    
    private func handleExtensionEvent(_ event: ExtensionEvent, in state: BrowserState) {
        switch event.action {
        case .extensionChanged(let info):
            if let typedInfo = info as? [[String: Any]] {
                state.extensionManager.extensionChanged(typedInfo)
            }
        }
    }
}

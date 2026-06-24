// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>
#include <objc/objc.h>
#ifndef PhiChromiumBridgeHeader_h
#define PhiChromiumBridgeHeader_h
NS_ASSUME_NONNULL_BEGIN
@protocol WebContentWrapper;
@protocol BookmarkWrapper;
@protocol DownloadItemWrapper;
@class ASWebAuthenticationSessionRequest;
// Window types reported by Chromium bridge.
// Note: ChromiumBrowserTypeIncognito means TYPE_NORMAL + incognito profile.
// Non-normal incognito windows (e.g. DevTools, Popup opened from incognito)
// are reported as their actual type (DevTools, Popup, etc.), not as Incognito.
typedef NS_ENUM(NSUInteger, ChromiumBrowserType) {
    ChromiumBrowserTypeNormal = 0,
    ChromiumBrowserTypePopup,
    ChromiumBrowserTypeAppPopup,
    ChromiumBrowserTypePIP,
    ChromiumBrowserTypeIncognito,  // TYPE_NORMAL + incognito profile
    ChromiumBrowserTypeApp,
    ChromiumBrowserTypeDevTools,
    ChromiumBrowserTypeShadow
};

typedef NS_ENUM(NSUInteger, BrowserType) {
    BrowserTypeSafari = 0,
    BrowserTypeChrome,
    BrowserTypeArc
};

/// Loading state mapped from Chromium TabNetworkState.
typedef NS_ENUM(NSInteger, PhiTabLoadingState) {
    PhiTabLoadingStateNone = 0,
    PhiTabLoadingStateWaiting = 1,
    PhiTabLoadingStateLoading = 2,
    PhiTabLoadingStateError = 3
};

/// Download event types for notifications from Chromium to Phi
typedef NS_ENUM(NSUInteger, DownloadEventType) {
    DownloadEventTypeCreated = 0,
    DownloadEventTypeUpdated,
    DownloadEventTypeCompleted,
    DownloadEventTypeCancelled,
    DownloadEventTypeInterrupted,
    DownloadEventTypePaused,
    DownloadEventTypeResumed,
    DownloadEventTypeRemoved,
    DownloadEventTypeDestroyed,
    DownloadEventTypeOpened
};

typedef NS_ENUM(NSUInteger, PhiOmniboxSuggestionDisposition) {
    PhiOmniboxSuggestionDispositionDefault = 0,
    PhiOmniboxSuggestionDispositionCurrentTab,
    PhiOmniboxSuggestionDispositionNewForegroundTab,
    PhiOmniboxSuggestionDispositionNewBackgroundTab,
    PhiOmniboxSuggestionDispositionSwitchToTab
};

@protocol PhiChromiumBridgeDelegate <NSObject>
@property (nonatomic, copy, readonly, nullable) void (^extensionChangedCallback)(NSArray<NSDictionary *> *list, int64_t windowId);
- (NSView * _Nullable)getWebContentSuperView;
// lift cycle
- (void)initApplication;
- (void)mainBrowserWindowCreated:(NSWindow *)window
                            type:(ChromiumBrowserType)browserType
                       profileId:(NSString *)profileId
                        windowId:(int64_t)windowId;
- (BOOL)runQuitConfirmAlert;

// tab service
- (void)newTabCreatedWithInfo:(NSDictionary *)tabInfo windowId:(int64_t)windowId;
- (void)tabWillBeRemove:(int64_t)tabId windowId:(int64_t)windowId;
- (void)tabTitleUpdated:(int64_t)tabId title:(NSString *)title windowId:(int64_t)windowId;
- (void)activeTabChanged:(int64_t)tabId index:(int)index windowId:(int64_t)windowId;
- (void)tabIndicesUpdated:(NSDictionary<NSNumber *, NSNumber *> *)tabIndices windowId:(int64_t)windowId;

// ==========================================================================
// DevTools embedding (Chromium → Mac notification)
// ==========================================================================

/// Called when DevTools has attached (docked) to a tab.
/// Mac should add the devToolsNativeView to the tab's hostView (full-size, Z-below content).
/// @param tabId The inspected tab's Chromium tab ID
/// @param windowId The window ID containing the tab
/// @param devToolsNativeView The DevTools frontend NSView to embed
- (void)devToolsDidAttachToTab:(int64_t)tabId
                      windowId:(int64_t)windowId
                  devToolsView:(NSView*)devToolsNativeView;

/// Called when DevTools has detached from a tab (closed or switched to undocked).
/// Mac should remove the devToolsView and restore webContentView to full size.
- (void)devToolsDidDetachFromTab:(int64_t)tabId
                        windowId:(int64_t)windowId;

/// Called when the inspected page bounds change (DevTools JS resizes the content area).
/// Mac should update webContentView.frame accordingly.
/// @param bounds The rect where the content NSView should be placed (relative to hostView)
/// @param hide If YES, the content NSView should be completely hidden (e.g. device emulation fullscreen)
- (void)updateInspectedPageBounds:(CGRect)bounds
                         forTabId:(int64_t)tabId
                         windowId:(int64_t)windowId
             hideInspectedContents:(BOOL)hide;

// ==========================================================================
// Flicker fix: Tab visibility synchronization (Chromium → Mac notification)
// ==========================================================================

/// Called after Chromium has hidden the previous WebContents.
/// Mac should remove the previous tab's NSView from the view hierarchy.
/// @param tabId The Chromium tab ID that was hidden
/// @param windowId The window ID containing the tab
- (void)previousTabReadyForCleanup:(int64_t)tabId windowId:(int64_t)windowId;

/// Called when a new tab has completed its first visually non-empty paint.
/// Mac should bring the new tab's view to the front when receiving this.
/// This is used for scenario 2: switching to a newly created tab that hasn't rendered yet.
/// @param tabId The Chromium tab ID that is ready to display
/// @param windowId The window ID containing the tab
- (void)tabReadyToDisplay:(int64_t)tabId windowId:(int64_t)windowId;

// Content fullscreen
- (void)tabContentFullscreenChanged:(int64_t)tabId
                           windowId:(int64_t)windowId
                       isFullscreen:(BOOL)isFullscreen;

// ==========================================================================
// Tab groups (Chromium → Mac notification)
// ==========================================================================

/// A new tab group exists in `windowId`. tokenHex is the 32-char uppercase
/// hex token (base::Token::ToString format). color is a lowercase wire
/// string ("blue"/"red"/...). initialTabIds enumerates the Phi-stable tab
/// ids placed into the group at creation time. May fire from a normal user
/// "Add to new group" action or from a cross-window detach (token preserved).
- (void)tabGroupCreated:(int64_t)windowId
                tokenHex:(NSString *)tokenHex
                   title:(NSString *)title
                   color:(NSString *)color
             isCollapsed:(BOOL)isCollapsed
           initialTabIds:(NSArray<NSNumber *> *)initialTabIds;

/// Tab group's visuals changed (title / color / isCollapsed). Fires both
/// from explicit user actions and from an auto-bookkeeping event right
/// after group creation. Mac side should overwrite the cached visual data
/// idempotently.
- (void)tabGroupVisualDataChanged:(int64_t)windowId
                          tokenHex:(NSString *)tokenHex
                             title:(NSString *)title
                             color:(NSString *)color
                       isCollapsed:(BOOL)isCollapsed;

/// Tab group closed. Mac side should drop the group entry from the
/// per-window groups dict. Closure reason is intentionally not propagated.
- (void)tabGroupClosed:(int64_t)windowId tokenHex:(NSString *)tokenHex;

/// A tab joined a tab group. windowId and tabId are pre-resolved (the
/// underlying WebContents may be in transition during teardown). Mac side
/// should set the tab's groupToken and append it to the group's
/// orderedTabIds (idempotent).
- (void)tabJoinedGroup:(int64_t)windowId
                 tabId:(int64_t)tabId
              tokenHex:(NSString *)tokenHex;

/// A tab left a tab group. Mac side should clear the tab's groupToken and
/// remove it from the group's orderedTabIds; if orderedTabIds becomes
/// empty, also drop the group entry (defensive cleanup, see spec § 1.4).
- (void)tabLeftGroup:(int64_t)windowId
               tabId:(int64_t)tabId
            tokenHex:(NSString *)tokenHex;

// bookmark service
- (void)bookmarksLoaded:(int64_t)windowId;
- (void)bookmarksChanged:(NSArray <id<BookmarkWrapper>> *)newNodes windowId:(int64_t)windowId;
- (void)bookmarkInfoChangedWithWindowId:(int64_t)windowId bookmarkId:(int64_t)id title:(NSString * _Nullable)title url:(NSString * _Nullable)url facicon:(NSString * _Nullable)favicon_url;

// extension service 
- (void)extensionsLoaded:(NSArray<NSDictionary *> *)extensions;
- (void)extensionTriggered:(NSString *)extensionId;
- (void)extensionPinned:(NSString *)extensionId;
- (void)extensionUnpinned:(NSString *)extensionId;
- (void)extensionMoved:(NSString *)extensionId toIndex:(int)newIndex;

/// Called when an extension install request completes for a single extension.
/// @param extensionId The Chrome Web Store extension ID
/// @param status One of: @"success", @"skipped", @"disabled", @"blocked", @"failed"
- (void)extensionInstallResult:(NSString *)extensionId status:(NSString *)status;

// auto completion
- (void)omniboxResultChanged:(NSArray<NSDictionary *> *)matches originalInput:(NSString *)originalInput windowId:(int64_t)windowId;

// Status/Link hover management
- (void)targetURLChanged:(int64_t)tabId windowId:(int64_t)windowId url:(NSString *)url;

- (BOOL)commandDispatch:(id)sender window:(NSWindow*)window;
- (BOOL)handleKeyEquivalent:(NSEvent*)event window:(NSWindow*)window;
- (BOOL)dispatchCommand:(int)commandId window:(NSWindow*)window;

// Login management
- (BOOL)isUserLoggedIn;
- (void)showLoginUI;
- (NSString *)getAuth0AccessTokenSyncly;

// Import management
- (void)importStarted:(BrowserType)browserType;
- (void)importItemProgress:(BrowserType)browserType started:(BOOL)started;
- (void)importCompleted:(BrowserType)browserType success:(BOOL)success;

// Download management - notifications from Chromium to Phi
/// Called when a download event occurs. The Phi app should query download details if needed.
/// @param eventType The type of download event
/// @param guid The unique identifier of the download item
/// @param downloadItem The download item wrapper containing meta information (may be nil for REMOVED/DESTROYED events)
- (void)downloadEventOccurred:(DownloadEventType)eventType
                         guid:(NSString *)guid
                 downloadItem:(id<DownloadItemWrapper> _Nullable)downloadItem;

- (NSString *)getNativeSettings;
/// Returns whether Phi extensions should be kept enabled (Mac is source of truth).
/// Called synchronously by the policy provider — must not block.
- (BOOL)shouldEnablePhiExtensions;
- (BOOL)handleDeeplinkWithUrlString:(NSString *)urlString windowId:(int64_t)windowId;
- (void)toggleChatSidebar:(NSNumber * _Nullable)show;
- (void)showFeedbackDialog;

// ==========================================================================
// Split view notifications (Chromium → Mac)
// splitId is a SplitTabId serialized via base::Token::ToString()
// ==========================================================================

/// Called when a split is created. primaryTabId is at position 0, secondaryTabId at position 1.
- (void)splitCreated:(NSString *)splitId
        primaryTabId:(int64_t)primaryTabId
      secondaryTabId:(int64_t)secondaryTabId
              layout:(NSString *)layout   // @"vertical" | @"horizontal"
               ratio:(double)ratio        // 0.0–1.0, proportion of primary pane
            windowId:(int64_t)windowId;

/// Called when a split's layout or ratio changes.
- (void)splitVisualsChanged:(NSString *)splitId
                     layout:(NSString *)layout
                      ratio:(double)ratio
                   windowId:(int64_t)windowId;

/// Called when one or both sides of a split change (e.g. after reverseTabsInSplit).
- (void)splitContentsChanged:(NSString *)splitId
               primaryTabId:(int64_t)primaryTabId
             secondaryTabId:(int64_t)secondaryTabId
                   windowId:(int64_t)windowId;

/// Called when a split is disbanded.
- (void)splitRemoved:(NSString *)splitId windowId:(int64_t)windowId;

/// Right-click "Open link in split view" — Chromium asks Mac to open `url`
/// as a fresh pane paired with the tab identified by `partnerTabId`. Routed
/// through Swift so the pendingSplitPartner marker dance can prevent the
/// partner pane from bouncing HIDDEN → VISIBLE and rendering blank.
- (void)openLinkAsSplitPartnerWithPartnerTabId:(int64_t)partnerTabId
                                           url:(NSString *)url
                                      windowId:(int64_t)windowId;

@optional
// Per-window extension action badge state (text/colors/visibility/enabled).
// Keys: windowId, extensionId, tabId, badgeText, backgroundColor, textColor,
// visible, enabled.
- (void)badgeInfoChanged:(NSDictionary *)info;
// Per-window dynamic extension action icon. Keys: windowId, extensionId, tabId,
// iconData (PNG NSData, empty => no dynamic icon), dipSize, scale.
- (void)actionIconChanged:(NSDictionary *)info;
// Optional metadata-rich variants for richer native tab orchestration.
- (void)tabWillBeRemove:(int64_t)tabId
               windowId:(int64_t)windowId
                 context:(NSDictionary<NSString *, id> *)context;
// Relationship snapshot version increases monotonically per window.
- (void)tabRelationshipSnapshotChanged:(NSDictionary *)snapshot
                             windowId:(int64_t)windowId
                               version:(int64_t)version;
// Returns a custom shortcut override, or nil to use Chromium defaults.
- (nullable NSDictionary<NSString*, id>*)keyEquivalentOverrideForCommand:
    (int)commandId;

/// Handle a message from an extension synchronously.
/// @param type Message type from the extension
/// @param payload Message payload (JSON string)
/// @param requestId The unique request ID for response correlation
/// @param senderId The extension ID that sent the message
/// @return Response string if handled synchronously, nil for async handling
- (NSString * _Nullable)handleExtensionMessage:(NSString *)type
                                      payload:(NSString *)payload
                                    requestId:(NSString *)requestId
                                      senderId:(NSString *)senderId;

// ==========================================================================
// Placeholder mode (Chromium → Mac notification)
// ==========================================================================

/// Window entered placeholder mode: the TabStripModel just became empty and
/// the Browser is showing an out-of-band `chrome://dino` WebContents.
/// Mac must:
///   1. Attach wrapper.nativeView to the content area.
///   2. Set BrowserState.isInPlaceholderMode = true (UI bindings respond).
///   3. Retain wrapper for the duration of placeholder mode.
/// @param windowId The window's session id.
/// @param wrapper The WebContentWrapper for the placeholder WebContents.
- (void)windowDidEnterPlaceholderMode:(int64_t)windowId
                      placeholderView:(id<WebContentWrapper>)wrapper;

/// Window exited placeholder mode: a real tab was inserted into TabStripModel.
/// Mac must SYNCHRONOUSLY before returning:
///   1. Detach the placeholder NSView from the view hierarchy.
///   2. Release the wrapper (lifetime owned by Chromium; nativeView dies on return).
///   3. Set BrowserState.isInPlaceholderMode = false.
/// A subsequent newTabCreatedWithInfo + activeTabChanged provides the new tab.
/// @param windowId The window's session id.
- (void)windowDidExitPlaceholderMode:(int64_t)windowId;
@end

@protocol PhiChromiumBridgeProtocol <NSObject>
@property (nonatomic, weak) id<PhiChromiumBridgeDelegate> delegate;

- (id<WebContentWrapper>)newWebContentsForUrl:(NSString *)urlString;

- (void)createNewTabWithUrl:(NSString*)urlString
                   windowId:(int64_t)windowId
                 customGuid:(NSString* _Nullable)customGuid
           focusAfterCreate:(BOOL)focus;
- (void)createQuickLookupTabWithWindowId:(int64_t)windowId
                               customGuid:(NSString* _Nullable)customGuid;
- (void)createNewTabWithUrl:(NSString*)urlString
                    atIndex:(NSInteger)index
                   windowId:(NSInteger)windowId
                 customGuid:(NSString* _Nullable)customGuid;
                 
// Unlike createNewTabWithUrl, this reuses an existing tab for the same URL when possible.
- (void)openTabWithUrl:(NSString *)urlString windowId:(int64_t)windowId;

- (NSDictionary<NSString *, id> *)getSearchTabsDataWithWindowId:(int64_t)windowId;

- (BOOL)activateSearchTabWithTabId:(int64_t)tabId
                          windowId:(int64_t)windowId;

- (BOOL)openRecentlyClosedSearchEntryWithSessionId:(int64_t)sessionId
                                          windowId:(int64_t)windowId;

- (void)moveTabWithWindowId:(int64_t)windowId
                      tabId:(int64_t)tabId
                beforeTabId:(int64_t)anchorTabId;
- (void)moveTabWithWindowId:(int64_t)windowId
                      tabId:(int64_t)tabId
                 afterTabId:(int64_t)anchorTabId;
- (void)moveTabToFirstWithWindowId:(int64_t)windowId
                             tabId:(int64_t)tabId;
- (void)moveTabToLastWithWindowId:(int64_t)windowId
                            tabId:(int64_t)tabId;

/// Create a new tab group containing the given Phi-stable tab ids in
/// `windowId`. Returns the new group's 32-char uppercase hex token, or an
/// empty string on failure. `title` and `color` are optional (pass nil to
/// keep Chromium default); `color` is the lowercase wire string
/// ("blue"/"red"/...).
- (NSString *)createGroupFromTabsWithWindowId:(int64_t)windowId
                                       tabIds:(NSArray<NSNumber *> *)tabIds
                                        title:(NSString * _Nullable)title
                                        color:(NSString * _Nullable)color;

/// Add the given Phi-stable tab ids to an existing group identified by
/// `tokenHex` in `windowId`.
- (void)addTabsToGroupWithWindowId:(int64_t)windowId
                            tabIds:(NSArray<NSNumber *> *)tabIds
                          tokenHex:(NSString *)tokenHex;

/// Remove the given Phi-stable tab ids from whichever group they belong
/// to (the group is preserved unless the last tab leaves).
- (void)removeTabsFromGroupWithWindowId:(int64_t)windowId
                                 tabIds:(NSArray<NSNumber *> *)tabIds;

/// Atomically create a new tab inside the group identified by `tokenHex`,
/// inserted at the end of the group's range in the strip. The new tab
/// loads the New Tab URL and is foregrounded.
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex;

- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex
                                  url:(NSString *)url
                           groupIndex:(NSInteger)groupIndex
                     focusAfterCreate:(BOOL)focusAfterCreate;

/// Close the group identified by `tokenHex` (closes all of its tabs).
- (void)closeGroupWithWindowId:(int64_t)windowId
                      tokenHex:(NSString *)tokenHex;

/// Reposition the group identified by `tokenHex` so that it starts at
/// `toIndex` in the strip.
- (void)moveGroupWithWindowId:(int64_t)windowId
                     tokenHex:(NSString *)tokenHex
                      toIndex:(NSInteger)toIndex;

/// Reposition the group identified by `tokenHex` so that its **last**
/// member lands immediately before `anchorTabId` in the strip.
/// `anchorTabId` MUST NOT be a member of the group; if it is, the call
/// logs WARNING and is a no-op. Anchor-based analog of
/// moveTabWithWindowId:tabId:beforeTabId: for whole groups; lets Mac
/// avoid computing absolute TabStripModel indices.
- (void)moveGroupWithWindowId:(int64_t)windowId
                     tokenHex:(NSString *)tokenHex
                  beforeTabId:(int64_t)anchorTabId;

/// Reposition the group identified by `tokenHex` so that its **first**
/// member lands immediately after `anchorTabId` in the strip. Same
/// constraints as the beforeTabId variant.
- (void)moveGroupWithWindowId:(int64_t)windowId
                     tokenHex:(NSString *)tokenHex
                   afterTabId:(int64_t)anchorTabId;

/// Cross-window: move the group identified by `tokenHex` from
/// `sourceWindowId` to `targetWindowId`, landing **before** the tab
/// identified by `anchorTabId` in the target strip. Group identity
/// (TabGroupId/token), active member, and member order are preserved —
/// Chromium runs an atomic detach + insert via
/// `TabStripModel::DetachTabGroupForInsertion` +
/// `InsertDetachedTabGroupAt`. If the target index would fall inside
/// another group on the target strip, it is clamped to the nearest
/// boundary. Failure paths (window/group/anchor lookup miss, same
/// source/target window) log WARNING and no-op.
- (void)moveGroupWithWindowId:(int64_t)sourceWindowId
                     tokenHex:(NSString *)tokenHex
                   toWindowId:(int64_t)targetWindowId
                  beforeTabId:(int64_t)anchorTabId;

/// Cross-window: same constraints as the beforeTabId variant; lands
/// **after** the anchor in the target strip.
- (void)moveGroupWithWindowId:(int64_t)sourceWindowId
                     tokenHex:(NSString *)tokenHex
                   toWindowId:(int64_t)targetWindowId
                   afterTabId:(int64_t)anchorTabId;

/// Tear-off: move the group identified by `tokenHex` into a new
/// Browser window. Group identity, active member, and member order
/// are preserved. Mirrors upstream `MoveGroupToNewWindow` helper in
/// chrome/browser/ui/browser_commands.cc. New window inherits the
/// source profile; placement is left to the caller (Mac side uses
/// `TabDraggingSession.recordPendingTearOffWindowPlacement` +
/// `.mainBrowserWindowCreated` notification, identical to single-tab
/// tear-off).
- (void)moveGroupToNewWindowWithWindowId:(int64_t)sourceWindowId
                                tokenHex:(NSString *)tokenHex;

/// Update the group's display title (empty string clears to Chromium auto).
- (void)updateTabGroupTitleWithWindowId:(int64_t)windowId
                                tokenHex:(NSString *)tokenHex
                                   title:(NSString *)title;

/// Update the group's color via lowercase wire string ("blue"/"red"/...).
- (void)updateTabGroupColorWithWindowId:(int64_t)windowId
                                tokenHex:(NSString *)tokenHex
                                   color:(NSString *)color;

/// Update the group's collapsed state (YES collapses, NO expands).
- (void)updateTabGroupCollapsedWithWindowId:(int64_t)windowId
                                    tokenHex:(NSString *)tokenHex
                                 isCollapsed:(BOOL)isCollapsed;
// Wrapped by base::apple::CallWithEHFrame for Chromium-side exception handling.
- (void)callWithEHFrame:(void (^)(void))block;
- (void)openURLInNewWindow:(NSString *)url;
// Returns a dictionary with keys: @"window", @"windowId", @"windowType".
- (NSDictionary<NSString *, id> *)createBrowserWithWindowType:(ChromiumBrowserType)browserType;
- (void)tryToTerminateApplication:(NSApplication*)app;
- (void)stopTryingToTerminateApplication:(NSApplication*)app;
- (void)applicationWillFinishLaunching:(NSNotification*)notification;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
- (void)applicationWillTerminate:(NSNotification*)aNotification;
- (void)application:(NSApplication*)sender openURLs:(NSArray<NSURL*>*)urls;
- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication
                    hasVisibleWindows:(BOOL)hasVisibleWindows;
// Phi: Route a main-menu command (and its validation) to PhiAppController for
// the no-key-window case, so File-menu items like New Tab/New Window work when
// no browser window is open. Mirrors upstream AppController acting as NSApp's
// delegate; here NSApp's delegate is the Swift AppController, which forwards.
- (void)commandDispatchFromMenu:(id)sender;
- (BOOL)validateUserInterfaceItemFromMenu:(id<NSValidatedUserInterfaceItem>)item;
- (NSMenu*)applicationDockMenu:(NSApplication*)sender;
- (BOOL)application:(NSApplication*)application 
    willContinueUserActivityWithType:(NSString*)userActivityType;
- (BOOL)application:(NSApplication*)application 
    continueUserActivity:(NSUserActivity*)userActivity 
      restorationHandler:(void (^)(NSArray<id<NSUserActivityRestoring>>*))restorationHandler;

- (void)getAllExtensionsWithCompletion:(void (^)(NSArray<NSDictionary *> *))completion windowId:(int64_t)windowId;
- (void)triggerExtensionWithId:(NSString *)extensionId pointInScreen:(NSPoint)pointInScreen windowId:(int64_t)windowId;
- (void)triggerExtensionContextMenuWithId:(NSString *)extensionId pointInScreen:(NSPoint)pointInScreen windowId:(int64_t)windowId;
- (void)pinExtensionWithId:(NSString *)extensionId windowId:(int64_t)windowId;
- (void)unpinExtensionWithId:(NSString *)extensionId windowId:(int64_t)windowId;
- (void)movePinnedExtensionWithId:(NSString *)extensionId toIndex:(int)newIndex windowId:(int64_t)windowId;

/// Enable all three Phi built-in extensions.
/// Mac must update its own state before calling this so that
/// shouldEnablePhiExtensions returns YES during policy checks.
- (void)enablePhiExtensions;

/// Disable all three Phi built-in extensions.
/// @param clearData If YES, also clear all extension storage data
///        (IndexedDB, localStorage, cookies, chrome.storage, Cache Storage, etc.)
/// Mac must update its own state before calling this so that
/// shouldEnablePhiExtensions returns NO during policy checks.
- (void)disablePhiExtensions:(BOOL)clearData;

/// Install one or more extensions from Chrome Web Store by their IDs.
/// Results are reported per-extension via extensionInstallResult:status: delegate callback.
/// Status values: @"success", @"skipped", @"disabled", @"blocked", @"failed"
/// @param extensionIds Array of Chrome Web Store extension IDs to install
/// @param windowId The window ID (used to resolve target Profile)
- (void)installExtensionsWithIds:(NSArray<NSString *> *)extensionIds
                        windowId:(int64_t)windowId;

- (NSArray <id<BookmarkWrapper>> *)getAllBookmarksWithWindowId:(int64_t)windowId;
- (void)removeAllBookmarksWithWindowId:(int64_t)windowId;
- (void)bookmarkCurrentTabWithWindowId:(int64_t)windowId;
- (void)addBookmarkWithURL:(NSString *)urlString title:(NSString *)title parent:(NSInteger)parentId windowId:(int64_t)windowId;
- (void)removeBookmarkWithId:(NSInteger)bookmarkId windowId:(int64_t)windowId;
- (void)moveBookmarkWithId:(NSInteger)bookmarkId toParent:(NSInteger)newParentId index:(NSInteger)newIndex windowId:(int64_t)windowId;
- (void)addBookmarkFolderWithTitle:(NSString *)title parent:(NSInteger)parentId windowId:(int64_t)windowId;

- (void)clearWebsiteCache:(NSString *)website windowId:(int64_t)windowId;
- (void)clearWebsiteCookies:(NSString *)website windowId:(int64_t)windowId;

// Autocomplete
- (void)requestAutoCompleteSuggestionsForText:(NSString *)text preventInlineAutoComplete:(BOOL)preventInlineAutoComplete windowId:(int64_t)windowId;
- (void)stopAutoCompleteSuggestions:(int64_t)windowId;
- (void)selectSuggestionAtLine:(size_t)line
                       windowId:(int64_t)windowId
                    disposition:(PhiOmniboxSuggestionDisposition)disposition;
- (void)deleteSuggestionAtLine:(size_t)line windowId:(int64_t)windowId;

// ==========================================================================
// Flicker fix: Tab visibility synchronization (Mac → Chromium confirmation)
// ==========================================================================

/// Called by Mac to confirm that the view switch has completed.
/// After receiving this, Chromium will hide the previous WebContents
/// and send previousTabReadyForCleanup notification.
/// @param windowId The window ID where the view switch occurred
- (void)confirmViewSwitchCompleted:(int64_t)windowId;

/// Execute a Chromium command on the specified window.
/// Goes through Chromium's internal command handling (e.g. chrome::ExecuteCommand),
/// which includes beforeunload checks and proper lifecycle management.
/// @param commandId The Chromium command ID (e.g. IDC_CLOSE_TAB = 34015)
/// @param windowId The window ID to execute the command on
- (void)executeCommand:(int)commandId windowId:(int64_t)windowId;

// Favicon service
- (void)getFaviconForURL:(NSString *)urlString completion:(void (^)(NSData * _Nullable faviconData))completion;
- (void)getFaviconForURL:(NSString *)urlString profileId:(NSString * _Nullable)profileId completion:(void (^)(NSData * _Nullable faviconData))completion;

// Thumbnail service
/// Returns cached JPEG thumbnail data for a tab, or nil if unavailable.
/// This is a synchronous call that reads from in-memory cache.
/// @param tabId The Chromium tab ID
- (NSData * _Nullable)thumbnailForTab:(int64_t)tabId;

- (void)submitFeedbackWithParams:(NSDictionary *)params windowId:(int64_t)windowId;
- (void)getFeedbackSystemLogsTextWithWindowId:(int64_t)windowId
                                   completion:(void (^ _Nonnull)(NSString * _Nullable text))completion;

- (void)notifyLoginCompleted;
- (void)notifyRebuildMenuAfterLogin;

- (void)beginHandlingWebAuthenticationSessionRequest:
    (ASWebAuthenticationSessionRequest*)request;
- (void)cancelWebAuthenticationSessionRequest:
    (ASWebAuthenticationSessionRequest*)request;

// Import management
- (void)importBrowserDataFromBrowserType:(BrowserType)browserType profile:(NSString *)profile dataTypes:(nullable NSArray<NSString *> *)dataTypes windowId:(int64_t)windowId;

// Download management
/// Get all download items with full metadata
/// @param windowId The window ID (used to find the Browser object)
/// @return Array of DownloadItemWrapper objects
- (NSArray<id<DownloadItemWrapper>> *)getAllDownloadItemsWithWindowId:(int64_t)windowId;

/// Get a single download item by GUID
/// @param guid The unique identifier of the download item
/// @param windowId The window ID (used to find the Browser object)
/// @return The download item wrapper, or nil if not found
- (id<DownloadItemWrapper> _Nullable)getDownloadItemWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Pause a download
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)pauseDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Resume a paused download
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)resumeDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Cancel a download
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)cancelDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Remove a download from the list (does not delete the file)
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)removeDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Open a downloaded file
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)openDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Show a downloaded file in Finder
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)showDownloadInFinderWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Validate (keep) a dangerous download, allowing it to proceed
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)validateDangerousDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

/// Validate (keep) an insecure download, allowing it to proceed
/// @param guid The unique identifier of the download item
/// @param windowId The window ID
- (void)validateInsecureDownloadWithGuid:(NSString *)guid windowId:(int64_t)windowId;

- (void)nativeSettingsChanged:(NSString *)settings;

// Asks Chromium to rebuild the main menu after shortcut settings change.
- (void)requestRebuildMainMenu;

#pragma mark - Security / Certificate

/// Get security state and certificate chain for a tab.
/// @param tabId The tab ID. Pass <= 0 to use active tab in the window.
/// @param windowId The window ID. Pass <= 0 to use the active window.
/// @return Dictionary containing security_state/SSLStatus fields and cert chain
///         DER encoded as Base64 strings.
- (NSDictionary<NSString *, id> * _Nullable)getTabSecurityInfo:(int64_t)tabId
                                                       windowId:(int64_t)windowId;

#pragma mark - Extension Messaging

/// Post a message from the native app to all extensions
/// @param type Message type to broadcast
/// @param payload Message payload (JSON string) to broadcast
/// @return YES if accepted for broadcast; NO if payload invalid or too large
- (BOOL)broadcastMessageToExtensionsWithType:(NSString *)type
                                   payload:(NSString *)payload;

/// Send a response back to an extension's pending request
/// @param requestId The request ID from the original extension message
/// @param response The response message
- (void)sendResponseForExtensionRequest:(NSString *)requestId response:(NSString *)response;

/// Send an error back to an extension's pending request (extension can catch with try/catch)
/// @param requestId The request ID from the original extension message
/// @param error The error message
- (void)sendErrorForExtensionRequest:(NSString *)requestId error:(NSString *)error;

/// Handle a message from an extension. Tries handling via delegate.
/// If delegate returns a string, responds immediately (sync).
/// If delegate returns nil, delegate must call sendResponseForExtensionRequest later (async).
/// If delegate not implemented, responds with error immediately.
/// @param type Message type from the extension
/// @param payload Message payload (JSON string)
/// @param requestId The unique request ID for response correlation
/// @param senderId The extension ID that sent the message
- (void)onExtensionMessage:(NSString *)type
                   payload:(NSString *)payload
                 requestId:(NSString *)requestId
                  senderId:(NSString *)senderId;

// ==========================================================================
// Split view control (Mac → Chromium)
// ==========================================================================

/// Create a split from two existing tabs. Returns the split ID string, or nil on failure.
- (NSString * _Nullable)createSplitWithTabId:(int64_t)primaryTabId
                                  secondTabId:(int64_t)secondaryTabId
                                       layout:(NSString *)layout
                                     windowId:(int64_t)windowId;

/// Disband a split (tabs remain open, just no longer side-by-side).
- (void)removeSplit:(NSString *)splitId windowId:(int64_t)windowId;

/// Change split orientation (@"vertical" side-by-side, @"horizontal" stacked).
- (void)updateSplitLayout:(NSString *)splitId layout:(NSString *)layout windowId:(int64_t)windowId;

/// Adjust the divider position (ratio 0.0–1.0 is the fraction occupied by the primary pane).
- (void)updateSplitRatio:(NSString *)splitId ratio:(double)ratio windowId:(int64_t)windowId;

/// Swap the positions of the two tabs within the split.
- (void)reverseTabsInSplit:(NSString *)splitId windowId:(int64_t)windowId;

/// Mark `tabId` as the soon-to-be partner of a split currently being formed.
/// While marked, the active-tab visibility path skips the OCCLUDED transition
/// and the deferred-HIDDEN flip for that tab. Used by "Open as Split" so the
/// existing tab does not bounce through HIDDEN (which RenderWidgetHostViewCocoa
/// does not always cleanly resume from) before its pane is mounted in the
/// split. The mark is cleared automatically when the split is established
/// (CreateSplit) or the tab leaves the strip; callers should also clear
/// explicitly on timeout or failure paths.
- (void)markPendingSplitPartnerWithTabId:(int64_t)tabId
                                windowId:(int64_t)windowId;
- (void)clearPendingSplitPartnerWithTabId:(int64_t)tabId
                                 windowId:(int64_t)windowId;

/// Cross-tab reordering: replace or swap one side of a split with another tab in the strip.
/// @param splitId   Target split.
/// @param slotIndex 0 = primary slot, 1 = secondary slot.
/// @param otherTabId The tab outside the split that moves in.
/// @param swap      YES → other tab takes the slot; the evicted tab moves right
///                  next to the split and joins its tab group, if any.
///                  NO  → kReplace (evicted tab is closed).
/// If neither side of the split is currently active, the targeted slot is
/// activated first so Chromium's "split contains the active tab" invariant
/// holds. Callers should not rely on focus being preserved across this call.
- (void)swapTabInSplit:(NSString *)splitId
              slotIndex:(int)slotIndex
              withTabId:(int64_t)otherTabId
                   swap:(BOOL)swap
               windowId:(int64_t)windowId;

/// Move the entire split (both tabs) as a block to a new position in the tab strip.
/// Pin/group state of the split is preserved.
- (void)moveSplit:(NSString *)splitId
          toIndex:(int)toIndex
         windowId:(int64_t)windowId;

/// Returns the split ID for a tab, or nil if the tab is not currently in a split.
- (NSString * _Nullable)getSplitIdForTabId:(int64_t)tabId windowId:(int64_t)windowId;

/// Returns all active split ID strings in the given window.
- (NSArray<NSString *> *)listSplitsInWindow:(int64_t)windowId;

@end

@protocol WebContentWrapper <NSObject>

@property(nonatomic, weak, readonly, nullable) NSView *nativeView;
@property(nonatomic, assign, readonly) BOOL isLoading;
@property(nonatomic, assign, readonly) PhiTabLoadingState loadingState;
@property(nonatomic, assign, readonly) BOOL isFocused;
@property(nonatomic, assign, readonly) CGFloat loadProgress;
@property(nonatomic, copy, readonly, nullable) NSString *favIconURL;
@property(nonatomic, copy, readonly, nullable) NSData *favIconData;
@property(nonatomic, assign, readonly) NSInteger favIconRevision;
@property(nonatomic, assign, readonly) BOOL canGoBack;
@property(nonatomic, assign, readonly) BOOL canGoForward;
@property(nonatomic, copy, readonly, nullable) NSString *title;
@property(nonatomic, copy, readonly, nullable) NSString *urlString;
@property(nonatomic, copy, readonly, nullable)
    NSDictionary<NSString*, id>* securityInfo;
@property(nonatomic, assign, readonly) BOOL isCurrentlyAudible;
@property(nonatomic, assign, readonly) BOOL isAudioMuted;
@property(nonatomic, assign, readonly) BOOL isCapturingAudio;
@property(nonatomic, assign, readonly) BOOL isCapturingVideo;
@property(nonatomic, assign, readonly) BOOL isCapturingWindow;
@property(nonatomic, assign, readonly) BOOL isCapturingDisplay;
@property(nonatomic, assign, readonly) BOOL isCapturingTab;
@property(nonatomic, assign, readonly) BOOL isBeingMirrored;
@property(nonatomic, assign, readonly) BOOL isSharingScreen;
@property(nonatomic, assign, readonly) BOOL isInContentFullscreen;

- (void)close;
- (void)reload;
- (void)reloadBypassingCache;
- (void)goBack;
- (void)goForward;
- (void)stopLoading;
- (void)navigateToURL:(NSString *)urlString;
- (void)setAsActiveTab;
- (void)moveSelfToIndex:(NSInteger)newIndex selectAfterMove:(BOOL)selectAfterMove;
- (void)moveSelfToNewWindow:(BOOL)activateNewWindow;
- (void)moveSelfToWindow:(int64_t)targetWindowId atIndex:(NSInteger)insertIndex;

/// Cross-window: move this tab to `targetWindowId`, inserting it
/// immediately before `anchorTabId` and joining `targetGroupTokenHex`.
- (void)moveSelfToWindow:(int64_t)targetWindowId
   andAddToGroupTokenHex:(NSString *)targetGroupTokenHex
             beforeTabId:(int64_t)anchorTabId;

/// Cross-window: same as above but inserts after `anchorTabId`.
- (void)moveSelfToWindow:(int64_t)targetWindowId
   andAddToGroupTokenHex:(NSString *)targetGroupTokenHex
              afterTabId:(int64_t)anchorTabId;

/// Split-aware tear-off: when the receiver belongs to a split, move BOTH tabs
/// of the split (preserving layout and ratio) into a new window as a single
/// user-visible operation. The move is not transactional — the source split is
/// dissolved, both tabs are detached, a new window is created, and the tabs
/// are re-inserted and re-grouped; observers see those intermediate states.
/// When the receiver is not in a split, behaves identically to moveSelfToNewWindow:.
- (void)moveSplitToNewWindow:(BOOL)activateNewWindow;
/// Split-aware cross-window move: when the receiver belongs to a split, move
/// BOTH tabs of the split into the target window starting at insertIndex,
/// preserving layout and ratio. Same intermediate-state caveat as
/// moveSplitToNewWindow:. When not in a split, behaves identically to
/// moveSelfToWindow:atIndex:.
- (void)moveSplitToWindow:(int64_t)targetWindowId atIndex:(NSInteger)insertIndex;
- (void)updateTabCustomValue:(NSString *)customValue;
- (void)focus;
- (void)restoreFocus;
- (void)updateSecurityState:(NSDictionary *)securityState;
- (void)setAudioMuted:(BOOL)muted;
- (void)muteAudio;
- (void)unmuteAudio;
@end

@protocol BookmarkWrapper <NSObject> 
@property(nonatomic, copy, readonly, nullable) NSString *title;
@property(nonatomic, copy, readonly, nullable) NSString *urlString;
@property(nonatomic, copy, readonly, nullable) NSString *favIconURL;
@property(nonatomic, assign, readonly) NSInteger guid;
@property(nonatomic, assign, readonly) BOOL isFolder;
@property(nonatomic, assign, readonly) NSInteger indexInParent;
@property(nonatomic, copy, readonly) NSArray<id<BookmarkWrapper>> *children;
@end

/// Protocol for download item metadata wrapper
/// Provides read-only access to download item information
@protocol DownloadItemWrapper <NSObject>

// Identification
@property(nonatomic, copy, readonly) NSString *guid;
@property(nonatomic, copy, readonly) NSString *url;
@property(nonatomic, copy, readonly) NSString *mimeType;

// Progress info
@property(nonatomic, assign, readonly) NSInteger state;  // DownloadItem::DownloadState (0=IN_PROGRESS, 1=COMPLETE, 2=CANCELLED, 3=INTERRUPTED)
@property(nonatomic, assign, readonly) int64_t totalBytes;
@property(nonatomic, assign, readonly) int64_t receivedBytes;
@property(nonatomic, assign, readonly) NSInteger percentComplete;  // -1 if unknown
@property(nonatomic, assign, readonly) int64_t currentSpeed;  // bytes per second

// Time info
@property(nonatomic, assign, readonly) int64_t startTime;  // milliseconds since epoch
@property(nonatomic, assign, readonly) int64_t endTime;    // milliseconds since epoch, 0 if not complete

// File operation capabilities
@property(nonatomic, assign, readonly) BOOL canShowInFolder;
@property(nonatomic, assign, readonly) BOOL canOpenDownload;
@property(nonatomic, assign, readonly) BOOL fileExternallyRemoved;
@property(nonatomic, assign, readonly) BOOL shouldOpenFileBasedOnExtension;

// Download control capabilities
@property(nonatomic, assign, readonly) BOOL canResume;
@property(nonatomic, assign, readonly) BOOL isPaused;
@property(nonatomic, assign, readonly) BOOL isDone;
@property(nonatomic, assign, readonly) BOOL isTemporary;

// Safety state
@property(nonatomic, assign, readonly) BOOL isDangerous;
@property(nonatomic, assign, readonly) NSInteger dangerType;
@property(nonatomic, assign, readonly) BOOL isInsecure;
@property(nonatomic, assign, readonly) NSInteger insecureDownloadStatus;

// Progress state
@property(nonatomic, assign, readonly) BOOL allDataSaved;
@property(nonatomic, assign, readonly) BOOL totalBytesKnown;

// Special types
@property(nonatomic, assign, readonly) BOOL isSavePackageDownload;

// Download metadata
@property(nonatomic, assign, readonly) NSInteger downloadSource;
@property(nonatomic, copy, readonly) NSString *remoteAddress;

// File paths and names
@property(nonatomic, copy, readonly) NSString *targetFilePath;
@property(nonatomic, copy, readonly) NSString *fileNameToReportUser;
@property(nonatomic, copy, readonly) NSString *currentPath;

/// Convert to NSDictionary for JSON serialization
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END
#endif /* PhiChromiumBridgeHeader_h */

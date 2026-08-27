// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

struct ExtensionMessageContext {
    let type: String
    let payload: String
    let requestId: String
    /// The sender's extension id, or a synthetic id for non-extension origins
    /// ("cdp" for the PhiAgentSpace DevTools tunnel, "debug-extension" for the
    /// debug panel). Empty when the bridge didn't attribute a sender.
    let senderId: String
    /// The authenticated identity of the connecting code agent (signing id or
    /// process name), for a direct `/phi-agent` connection. Empty for the
    /// Chromium tunnel and extension senders. Used to badge the Space with who
    /// is driving it (see `agentSpace.create`).
    let agentName: String
    /// Opaque app-issued identity for one logical external-agent session.
    /// Shared by that agent's reconnecting/sandboxed helpers, distinct from
    /// every other approved agent session. Nil for extensions and the legacy
    /// Chromium message tunnel, which therefore cannot own CDP tasks.
    let driverPrincipalId: String?

    init(type: String, payload: String, requestId: String,
         senderId: String, agentName: String = "", driverPrincipalId: String? = nil) {
        self.type = type
        self.payload = payload
        self.requestId = requestId
        self.senderId = senderId
        self.agentName = agentName
        self.driverPrincipalId = driverPrincipalId
    }
}

typealias ExtensionMessageHandler = (ExtensionMessageContext) -> String?

final class ExtensionMessageRouter {
    static let shared = ExtensionMessageRouter()

    private var handlers: [String: ExtensionMessageHandler] = [:]
    private var configured = false

    /// Registers a management type that operates the USER's browsing data
    /// (Spaces, profiles, URL rules, pinned tabs, bookmarks). The Developer
    /// settings "Agent permissions" toggle gates them as one unit. Tab-layout
    /// types register plainly: only their spaceId path is user-space, gated
    /// inside `AgentSpaceRouter.withLayoutWindow` so the agent-window path
    /// keeps working with the toggle off.
    private func registerUserSpaceManaged(type: String,
                                          handler: @escaping ExtensionMessageHandler) {
        register(type: type) { context in
            if let denied = AgentSpaceRouter.userSpaceOperationsRefusal() {
                return denied
            }
            PostHogSDK.shared.capture("agent_user_space_command", properties: [
                "command": context.type,
                "agent_name": AgentDriverBadge.telemetryName(context.agentName),
            ])
            return handler(context)
        }
    }

    func register(type: String, handler: @escaping ExtensionMessageHandler) {
        handlers[type] = handler
    }

    func handle(type: String, payload: String, requestId: String, senderId: String = "",
                agentName: String = "", driverPrincipalId: String? = nil) -> String? {
        configureIfNeeded()
        let context = ExtensionMessageContext(
            type: type, payload: payload, requestId: requestId, senderId: senderId,
            agentName: agentName, driverPrincipalId: driverPrincipalId)
        if let handler = handlers[type] {
            return handler(context)
        }
        return CommonMessageRouter.shared.handle(context)
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        register(type: "notification") { context in
            NotificationCardManager.shared.handleRequest(context: context)
            return nil
        }

        register(type: "imagePreview") { context in
            ImagePreviewMessageHandler.handle(context)
            return nil
        }

        register(type: "showDialog") { context in
            ExtensionDialogManager.shared.handleRequest(context: context)
            return nil
        }

        register(type: "getServiceExports") { context in
            Task {
                do {
                    let exports = try await SentinelIPCClient.shared.getComponentExports()
                    await ExtensionMessaging.shared.sendResponse(exports.exportsJSON, requestId: context.requestId)
                } catch {
                    await ExtensionMessaging.shared.sendError(error.localizedDescription, requestId: context.requestId)
                }
            }
            return nil
        }

        for type in ServiceBrokerExtensionProtocol.messageTypes {
            register(type: type) { context in
                Task {
                    let reply = await ServiceBrokerExtensionProtocol.shared.handle(context)
                    await ExtensionMessaging.shared.sendResponse(reply, requestId: context.requestId)
                }
                return nil
            }
        }

        // Both reader types ack synchronously — the extension's reports are
        // fire-and-forget, and a nil return would leave its sendMessageToApp
        // promise pending until the bridge's 30s timeout rejects it.
        register(type: "reader.offerable") { context in
            ReaderExtensionBridge.handleOfferable(context)
            return "{}"
        }
        register(type: "reader.state") { context in
            ReaderExtensionBridge.handleState(context)
            return "{}"
        }
        register(type: "reader.getStyle") { context in
            return ReaderExtensionBridge.handleGetStyle(context)
        }
        register(type: "reader.setStyle") { context in
            ReaderExtensionBridge.handleSetStyle(context)
            return "{}"
        }
        register(type: "reader.extractResult") { context in
            ReaderExtensionBridge.handleExtractResult(context)
            return "{}"
        }

        register(type: "sidecar.aiOutputState") { context in
            MainActor.assumeIsolated {
                SidecarAIOutputStateStore.shared.handle(context)
            }
            return "{}"
        }

        register(type: "agentSpace.create") { context in
            AgentSpaceRouter.handleCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.list") { context in
            return AgentSpaceRouter.handleList(context: context)
        }
        register(type: "agentSpace.listProfiles") { context in
            return AgentSpaceRouter.handleListProfiles(context: context)
        }
        register(type: "agentSpace.setState") { context in
            return AgentSpaceRouter.handleSetState(context: context)
        }
        register(type: "agentSpace.cursor") { context in
            return AgentSpaceRouter.handleCursor(context: context)
        }
        register(type: "agentSpace.effect") { context in
            return AgentSpaceRouter.handleEffect(context: context)
        }
        register(type: "agentSpace.log") { context in
            return AgentSpaceRouter.handleLog(context: context)
        }
        register(type: "agentSpace.readUserMessages") { context in
            return AgentSpaceRouter.handleReadUserMessages(context: context)
        }
        register(type: "agentSpace.markError") { context in
            return AgentSpaceRouter.handleMarkError(context: context)
        }
        register(type: "agentSpace.complete") { context in
            return AgentSpaceRouter.handleComplete(context: context)
        }
        register(type: "agentSpace.getOwnership") { context in
            return AgentSpaceRouter.handleGetOwnership(context: context)
        }
        register(type: "agentSpace.panelSize") { context in
            return AgentSpaceRouter.handlePanelSize(context: context)
        }
        register(type: "agentSpace.ping") { context in
            return AgentSpaceRouter.handlePing(context: context)
        }
        register(type: "agentSpace.handoff") { context in
            return AgentSpaceRouter.handleHandoff(context: context)
        }
        register(type: "agentSpace.takeover") { context in
            return AgentSpaceRouter.handleTakeover(context: context)
        }
        register(type: "agentSpace.openTab") { context in
            return AgentSpaceRouter.handleOpenTab(context: context)
        }
        register(type: "agentSpace.readerArticle") { context in
            AgentSpaceRouter.handleReaderArticle(context: context)
        }
        register(type: "agentSpace.readerDocument") { context in
            AgentSpaceRouter.handleReaderDocument(context: context)
        }

        register(type: "agentSpace.captureWindow") { context in
            return AgentSpaceRouter.handleCaptureWindow(context: context)
        }

        // Shadow windows (AgentSpaceRouter+Shadow.swift): invisible background
        // windows with no pip, no transcript and no takeover. Registered as
        // user-space-managed so the whole feature sits behind the same "Agent
        // control" consent as operating the user's Spaces — a user who has not
        // granted agents reach beyond their own visible Spaces must not get
        // invisible ones.
        registerUserSpaceManaged(type: "agentSpace.shadow.create") { context in
            AgentSpaceRouter.handleShadowCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        registerUserSpaceManaged(type: "agentSpace.shadow.list") { context in
            return AgentSpaceRouter.handleShadowList(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.shadow.openTab") { context in
            return AgentSpaceRouter.handleShadowOpenTab(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.shadow.ping") { context in
            return AgentSpaceRouter.handleShadowPing(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.shadow.close") { context in
            return AgentSpaceRouter.handleShadowClose(context: context)
        }

        // Management surface (AgentSpaceRouter+Management.swift): browser
        // features operated over the same tunnel — Spaces, profiles, URL
        // rules, tab groups, split view, pinned tabs, bookmarks. User-data
        // types register through the "Agent permissions" gate.
        registerUserSpaceManaged(type: "agentSpace.spaces.list") { context in
            return AgentSpaceRouter.handleSpacesList(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.create") { context in
            return AgentSpaceRouter.handleSpacesCreate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.update") { context in
            return AgentSpaceRouter.handleSpacesUpdate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.delete") { context in
            return AgentSpaceRouter.handleSpacesDelete(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.listTabs") { context in
            return AgentSpaceRouter.handleSpacesListTabs(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.openTab") { context in
            return AgentSpaceRouter.handleSpacesOpenTab(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.activate") { context in
            return AgentSpaceRouter.handleSpacesActivate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.spaces.focus") { context in
            return AgentSpaceRouter.handleSpacesFocus(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.profiles.create") { context in
            AgentSpaceRouter.handleProfilesCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        registerUserSpaceManaged(type: "agentSpace.profiles.rename") { context in
            AgentSpaceRouter.handleProfilesRename(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        registerUserSpaceManaged(type: "agentSpace.urlRules.list") { context in
            return AgentSpaceRouter.handleUrlRulesList(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.urlRules.add") { context in
            return AgentSpaceRouter.handleUrlRulesAdd(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.urlRules.update") { context in
            return AgentSpaceRouter.handleUrlRulesUpdate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.urlRules.delete") { context in
            return AgentSpaceRouter.handleUrlRulesDelete(context: context)
        }
        register(type: "agentSpace.tabGroups.list") { context in
            return AgentSpaceRouter.handleTabGroupsList(context: context)
        }
        register(type: "agentSpace.tabGroups.create") { context in
            return AgentSpaceRouter.handleTabGroupsCreate(context: context)
        }
        register(type: "agentSpace.tabGroups.update") { context in
            return AgentSpaceRouter.handleTabGroupsUpdate(context: context)
        }
        register(type: "agentSpace.tabGroups.addTabs") { context in
            return AgentSpaceRouter.handleTabGroupsAddTabs(context: context)
        }
        register(type: "agentSpace.tabGroups.removeTabs") { context in
            return AgentSpaceRouter.handleTabGroupsRemoveTabs(context: context)
        }
        register(type: "agentSpace.tabGroups.ungroup") { context in
            return AgentSpaceRouter.handleTabGroupsUngroup(context: context)
        }
        register(type: "agentSpace.tabGroups.close") { context in
            return AgentSpaceRouter.handleTabGroupsClose(context: context)
        }
        register(type: "agentSpace.splitView.list") { context in
            return AgentSpaceRouter.handleSplitViewList(context: context)
        }
        register(type: "agentSpace.splitView.create") { context in
            return AgentSpaceRouter.handleSplitViewCreate(context: context)
        }
        register(type: "agentSpace.splitView.update") { context in
            return AgentSpaceRouter.handleSplitViewUpdate(context: context)
        }
        register(type: "agentSpace.splitView.swap") { context in
            return AgentSpaceRouter.handleSplitViewSwap(context: context)
        }
        register(type: "agentSpace.splitView.remove") { context in
            return AgentSpaceRouter.handleSplitViewRemove(context: context)
        }
        // Downloads are per-profile; the target window (agent task or a user
        // Space via {spaceId}) selects the profile. Gating lives inside
        // withLayoutWindow, so these register plain like the tab-layout ops.
        register(type: "agentSpace.downloads.list") { context in
            return AgentSpaceRouter.handleDownloadsList(context: context)
        }
        register(type: "agentSpace.downloads.get") { context in
            return AgentSpaceRouter.handleDownloadsGet(context: context)
        }
        register(type: "agentSpace.downloads.pause") { context in
            return AgentSpaceRouter.handleDownloadsPause(context: context)
        }
        register(type: "agentSpace.downloads.resume") { context in
            return AgentSpaceRouter.handleDownloadsResume(context: context)
        }
        register(type: "agentSpace.downloads.cancel") { context in
            return AgentSpaceRouter.handleDownloadsCancel(context: context)
        }
        register(type: "agentSpace.downloads.remove") { context in
            return AgentSpaceRouter.handleDownloadsRemove(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.pinnedTabs.list") { context in
            return AgentSpaceRouter.handlePinnedTabsList(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.pinnedTabs.add") { context in
            return AgentSpaceRouter.handlePinnedTabsAdd(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.pinnedTabs.update") { context in
            return AgentSpaceRouter.handlePinnedTabsUpdate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.pinnedTabs.remove") { context in
            return AgentSpaceRouter.handlePinnedTabsRemove(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.list") { context in
            return AgentSpaceRouter.handleBookmarksList(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.add") { context in
            return AgentSpaceRouter.handleBookmarksAdd(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.addFolder") { context in
            return AgentSpaceRouter.handleBookmarksAddFolder(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.update") { context in
            return AgentSpaceRouter.handleBookmarksUpdate(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.move") { context in
            return AgentSpaceRouter.handleBookmarksMove(context: context)
        }
        registerUserSpaceManaged(type: "agentSpace.bookmarks.remove") { context in
            return AgentSpaceRouter.handleBookmarksRemove(context: context)
        }

        // Credential surface (AgentSpaceRouter+Credentials.swift): an agent can
        // check provider readiness and, after an explicit user approval, fetch a
        // credential or TOTP. User data, so gated by the "Agent permissions"
        // switch and, inside the handlers, by the Bitwarden enable toggle; each
        // secret-returning call replies asynchronously after the approval
        // prompt and provider lookup resolve.
        registerUserSpaceManaged(type: "credentials.status") { context in
            return AgentSpaceRouter.handleCredentialsStatus(context: context)
        }
        registerUserSpaceManaged(type: "credentials.get") { context in
            return AgentSpaceRouter.handleCredentialsGet(context: context)
        }
        registerUserSpaceManaged(type: "credentials.getTotp") { context in
            return AgentSpaceRouter.handleCredentialsGetTotp(context: context)
        }
        registerUserSpaceManaged(type: "credentials.autofill") { context in
            return AgentSpaceRouter.handleCredentialsAutofill(context: context)
        }

        register(type: "farringdon.organizeDidFinish") { _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .farringdonOrganizeDidFinish, object: nil)
            }
            return #"{"ok":true}"#
        }
    }
}

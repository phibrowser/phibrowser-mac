// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Cocoa
import Combine

struct TravelBackDestination: Codable {
    let tabId: Int
    let windowId: Int
    let sidebar: TravelBackSidebar
    let sourceSidebar: TravelBackSidebar?
    let sameSidecar: Bool
}

struct SidecarProfileMoveRequest {
    let operationId: String
    let destination: TravelBackDestination
    let snapshot: TravelBackScene
    let expiresAt: Double
    let finishBefore: Double
    var claimed = false
    var completed: Bool?
}

@MainActor
extension BrowserState {
    static let travelBackTabPrefix = "travel-back-pending:"

    var travelBackAllowed: Bool { travelBackWindowAllowed && !isInPlaceholderMode }

    /// Empty Spaces can be activated; their normal spawn path supplies an NTP.
    var travelBackWindowAllowed: Bool {
        !isIncognito && !isKioskWindow
            && !AgentSpaceManager.shared.isAgentSpace(spaceId)
            && ApplicationState.shared.isAuthenticated
            && PhiPreferences.AISettings.phiAIEnabled.loadValue()
    }

    /// Resolve through the existing binding, not just the original content ID:
    /// closing one split pane migrates the chat but keeps its fixed URL.
    func travelBackSource(boundTabId: Int?) -> (tab: Tab?, sidebar: TravelBackSidebar?) {
        guard let boundTabId else { return (focusingTab, nil) }
        for (identifier, chat) in aiChatTabs {
            guard travelBackBoundTabId(chat) == boundTabId,
                  let owner = tab(forChatIdentifier: identifier) else { continue }
            let content: Tab
            if let group = splitGroup(forTabId: owner.guid),
               let focused = focusingTab, group.contains(tabId: focused.guid) {
                content = focused
            } else {
                content = owner
            }
            return (content, TravelBackSidebar(windowId: windowId, chatTabId: chat.guid,
                                               boundTabId: boundTabId, profileId: profileId))
        }
        return (resolveTab(boundTabId), nil)
    }

    private func travelBackBoundTabId(_ chat: Tab) -> Int? {
        guard let url = chat.url,
              let parts = URLComponents(string: url),
              let value = parts.queryItems?.first(where: { $0.name == "tabId" })?.value else {
            return nil
        }
        return Int(value)
    }

    func travelBackScene(for tab: Tab?) -> TravelBackScene {
        guard let tab else { return TravelBackScene() }
        var scene = TravelBackScene(tab: .init(tabId: tab.guid),
                                    window: .init(windowId: windowId, spaceId: spaceId),
                                    profileId: profileId, runtimeId: TravelBackScene.currentRuntimeId)
        scene.relatedTabIds = [tab.guid]
        let page = TravelBackPage(url: tab.url ?? "", title: tab.title, favicon: tab.faviconUrl)
        if page.isReopenable { scene.page = page }
        if let split = splitGroup(forTabId: tab.guid),
           let primary = resolveTab(split.primaryTabId), let secondary = resolveTab(split.secondaryTabId) {
            scene.relatedTabIds = [primary.guid, secondary.guid]
            let members = [primary, secondary].map {
                TravelBackPage(url: $0.url ?? "", title: $0.title, favicon: $0.faviconUrl)
            }
            // Never persist a partial pair or shift member indexes by filtering.
            if members.allSatisfy(\.isReopenable) {
                scene.layout = .init(splitView: TravelBackSplit(
                    members: members, orientation: split.layout.rawValue,
                    ratio: split.ratio > 0 && split.ratio < 1 ? split.ratio : nil,
                    activeIndex: tab.guid == primary.guid ? 0 : 1
                ))
            }
        }
        return scene
    }

    /// Structural invalidation only: no page or conversation data is broadcast.
    func notifyTravelBackSceneChanged(tabIds: [Int]) {
        let bindings = Set(tabIds.compactMap { resolveTab($0) }
            .compactMap { aiChatTabs[chatIdentifier(for: $0)] }
            .compactMap { travelBackBoundTabId($0) })
        guard !bindings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["boundTabIds": Array(bindings)]),
              let payload = String(data: data, encoding: .utf8) else { return }
        ExtensionMessaging.shared.broadcast(type: "sidecar.travelBack.sceneChanged", payload: payload)
    }

    /// Late arrivals clear their transient marker too; they remain ordinary tabs.
    /// Called before normal tab binding, with the event sent after registration.
    func consumeTravelBackTabMarker(_ tab: Tab) -> String? {
        guard let marker = tab.guidInLocalDB,
              marker.hasPrefix(Self.travelBackTabPrefix) else { return nil }
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        return marker
    }

    private var travelBackChanges: AnyPublisher<Void, Never> {
        Publishers.Merge3($tabs.map { _ in () }, $splits.map { _ in () },
                          $aiChatTabs.map { _ in () }).eraseToAnyPublisher()
    }

    /// Observe lifecycle completion on the next main turn, never call Chromium
    /// from inside its own tab-strip callback. One deadline spans the whole restore.
    func travelBackWait<T>(until deadline: Double,
                                   events: AnyPublisher<Void, Never>? = nil,
                                   read: @escaping () throws -> T?) async throws -> T {
        let changes = events ?? travelBackChanges
        return try await withCheckedThrowingContinuation { continuation in
            var subscription: AnyCancellable?
            var timeout: DispatchWorkItem?
            var finished = false
            let finish: (Result<T, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                subscription?.cancel()
                subscription = nil
                timeout?.cancel()
                timeout = nil
                continuation.resume(with: result)
            }
            let check = { [weak self] in
                do {
                    guard let self, self.travelBackAllowed,
                          SpaceSessionControllersManager.shared.getBrowserState(for: self.windowId) === self else {
                        throw TravelBackFailure.targetChanged
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw TravelBackFailure.timedOut
                    }
                    if let value = try read() { finish(.success(value)) }
                } catch { finish(.failure(error)) }
            }
            subscription = changes.receive(on: DispatchQueue.main).sink { check() }
            let item = DispatchWorkItem { finish(.failure(TravelBackFailure.timedOut)) }
            timeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime),
                                          execute: item)
            DispatchQueue.main.async { check() }
        }
    }

    private func travelBackCreatePage(_ page: TravelBackPage, deadline: Double) async throws -> Tab {
        let marker = Self.travelBackTabPrefix + UUID().uuidString
        var created: Tab?
        // Subscribe before dispatch: the event owns correlation, never a URL lookup.
        let capture = travelBackTabCreated.sink { value in
            if value.marker == marker { created = value.tab }
        }
        defer { capture.cancel() }
        createTab(page.url, customGuid: marker, focusAfterCreate: false)
        return try await travelBackWait(until: deadline,
            events: travelBackTabCreated.map { _ in () }.eraseToAnyPublisher()) { created }
    }

    private func travelBackCheck(_ tabs: [Tab], deadline: Double) throws {
        guard travelBackAllowed, ProcessInfo.processInfo.systemUptime < deadline,
              SpaceManager.shared.slot(forWindowId: windowId)?.activeSpaceId == spaceId,
              SpaceSessionControllersManager.shared.getBrowserState(for: windowId) === self,
              tabs.allSatisfy({ resolveTab($0.guid) === $0 && $0.webContentWrapper != nil }) else {
            throw TravelBackFailure.targetChanged
        }
    }

    /// Native owns page/split lifecycle. Sidecar still owns conversation selection
    /// and acknowledgement; this reply does not claim a React mount or first paint.
    func restoreTravelBack(_ snapshot: TravelBackScene, anchor: Tab?,
                           sourceSidebar: TravelBackSidebar?, deadline: Double) async throws -> TravelBackDestination {
        guard let page = snapshot.page, page.isReopenable else { throw TravelBackFailure.invalidSnapshot }
        let split = try snapshot.layout?.splitView?.validated(for: page)
        var destination: Tab
        if let split {
            let existing = anchor.flatMap { splitGroup(forTabId: $0.guid) }
            let existingURLs = existing.map { group in
                [group.primaryTabId, group.secondaryTabId].map { resolveTab($0)?.url ?? "" }
            }
            // Do not detach pinned/bookmark bindings or merge two live Sidecars.
            // The partner is always new when completing an independent anchor.
            let plan = TravelBackSplitPlan.choose(recorded: split, existingURLs: existingURLs,
                hasAnchor: anchor != nil,
                anchorCanJoin: anchor.map { !$0.isPinned && ($0.guidInLocalDB ?? "").isEmpty } ?? false)
            let primary: Tab
            let secondary: Tab
            let groupId: String
            if plan == .reuse, let existing,
               let left = resolveTab(existing.primaryTabId), let right = resolveTab(existing.secondaryTabId) {
                primary = left
                secondary = right
                groupId = existing.id
            } else {
                let anchorIndex = split.members.firstIndex(where: { $0.url == page.url }) ?? split.activeIndex ?? 0
                if plan == .completeAnchor, let anchor {
                    try travelBackCheck([anchor], deadline: deadline)
                    let partner = try await travelBackCreatePage(split.members[1 - anchorIndex], deadline: deadline)
                    try travelBackCheck([anchor, partner], deadline: deadline)
                    guard splitGroup(forTabId: anchor.guid) == nil else { throw TravelBackFailure.targetChanged }
                    if anchor.url != split.members[anchorIndex].url {
                        anchor.webContentWrapper?.navigate(toURL: split.members[anchorIndex].url)
                    }
                    primary = anchorIndex == 0 ? anchor : partner
                    secondary = anchorIndex == 0 ? partner : anchor
                } else {
                    primary = try await travelBackCreatePage(split.members[0], deadline: deadline)
                    secondary = try await travelBackCreatePage(split.members[1], deadline: deadline)
                }
                try travelBackCheck([primary, secondary], deadline: deadline)
                guard splitGroup(forTabId: primary.guid) == nil,
                      splitGroup(forTabId: secondary.guid) == nil else { throw TravelBackFailure.targetChanged }
                let focused = split.activeIndex == 1 ? secondary : primary
                // Chromium's split creation activates its primary argument. Align
                // focus first and use the existing ordered helper to avoid blank panes.
                focused.webContentWrapper?.setAsActiveTab()
                focuseTab(focused)
                guard let id = createSplit(leftTabId: primary.guid, rightTabId: secondary.guid,
                                           layout: split.orientation == "horizontal" ? .horizontal : .vertical) else {
                    throw TravelBackFailure.unavailable
                }
                groupId = id
                let _: SplitGroup = try await travelBackWait(until: deadline) {
                    try self.travelBackCheck([primary, secondary], deadline: deadline)
                    return self.splitGroup(forId: id)
                }
            }
            try travelBackCheck([primary, secondary], deadline: deadline)
            guard let group = splitGroup(forId: groupId),
                  group.primaryTabId == primary.guid, group.secondaryTabId == secondary.guid else {
                throw TravelBackFailure.targetChanged
            }
            let orientation: SplitLayout = split.orientation == "horizontal" ? .horizontal : .vertical
            if group.layout != orientation { updateSplitLayout(groupId, layout: orientation) }
            if abs(group.ratio - (split.ratio ?? 0.5)) > 0.001 { updateSplitRatio(groupId, ratio: split.ratio ?? 0.5) }
            let _: SplitGroup = try await travelBackWait(until: deadline) {
                try self.travelBackCheck([primary, secondary], deadline: deadline)
                guard let live = self.splitGroup(forId: groupId),
                      live.primaryTabId == primary.guid, live.secondaryTabId == secondary.guid else {
                    throw TravelBackFailure.targetChanged
                }
                return live.layout == orientation && abs(live.ratio - (split.ratio ?? 0.5)) <= 0.001 ? live : nil
            }
            destination = split.activeIndex == 1 ? secondary : primary
        } else if let anchor {
            try travelBackCheck([anchor], deadline: deadline)
            if anchor.url != page.url { anchor.webContentWrapper?.navigate(toURL: page.url) }
            destination = anchor
        } else {
            destination = try await travelBackCreatePage(page, deadline: deadline)
        }
        return try await prepareTravelBackDestination(destination, sourceSidebar: sourceSidebar, deadline: deadline)
    }

    private func prepareTravelBackDestination(_ destination: Tab, sourceSidebar: TravelBackSidebar?,
                                             deadline: Double, waitUntilEnabled: Bool = true) async throws -> TravelBackDestination {
        try travelBackCheck([destination], deadline: deadline)
        destination.webContentWrapper?.setAsActiveTab()
        focuseTab(destination)
        // The Phi Chat shim owns the foreground when it asks for a restore, and
        // makeKeyAndOrderFront alone cannot make a window key while Phi is
        // inactive. Cooperative activation is declined on macOS 26 (see
        // `AppController.showSettings`), so take the foreground outright.
        NSApp.activate(ignoringOtherApps: true)
        SpaceSessionControllersManager.shared.controller(for: windowId)?.window?.makeKeyAndOrderFront(nil)
        let identifier = chatIdentifier(for: destination)
        // Request-driven creation bypasses the view's historical 300 ms timer.
        createAIChatTab(for: identifier, chromeTabId: destination.guid)
        // A newly created content tab can still report NTP. Expanding while
        // disabled is ignored by the view, and its enabled observer only
        // autohides; it does not replay that lost expand. Wait for capability,
        // not page load, while the Sidecar WebContents is already preparing.
        if waitUntilEnabled {
            let _: Bool = try await travelBackWait(until: deadline,
                events: destination.$aiChatEnabled.map { _ in () }.eraseToAnyPublisher()) {
                    try self.travelBackCheck([destination], deadline: deadline)
                    return destination.aiChatEnabled ? true : nil
                }
        }
        if destination.aiChatEnabled {
            prepareAIChatSidebarOpen(trigger: .button)
            setAIChatCollapsed(for: destination, collapsed: false)
        }
        let chat: Tab = try await travelBackWait(until: deadline) {
            try self.travelBackCheck([destination], deadline: deadline)
            guard self.chatIdentifier(for: destination) == identifier else { throw TravelBackFailure.targetChanged }
            return self.aiChatTabs[identifier]
        }
        guard let boundTabId = travelBackBoundTabId(chat) else { throw TravelBackFailure.unavailable }
        let sidebar = TravelBackSidebar(windowId: windowId, chatTabId: chat.guid,
                                        boundTabId: boundTabId, profileId: profileId)
        return TravelBackDestination(tabId: destination.guid, windowId: windowId, sidebar: sidebar,
                                     sourceSidebar: sourceSidebar, sameSidecar: sidebar == sourceSidebar)
    }

    func carriedConversationSidebar(for tab: Tab) -> TravelBackSidebar? {
        guard let chat = aiChatTabs[chatIdentifier(for: tab)],
              let binding = travelBackBoundTabId(chat) else { return nil }
        return travelBackSource(boundTabId: binding).sidebar
    }

    /// Only explicit browser Tab moves use this path. Native never reads chat
    /// storage or chooses a conversation; the source Sidecar claims its current one.
    func moveCarriedConversation(_ movingTabs: [Tab], to target: BrowserState,
                                 sidebar: TravelBackSidebar) async throws {
        guard profileId != target.profileId, !movingTabs.isEmpty,
              hasTravelBackSidebar(sidebar), target.travelBackAllowed,
              profileMovesInFlight.insert(sidebar.chatTabId).inserted else { throw TravelBackFailure.busy }
        defer { profileMovesInFlight.remove(sidebar.chatTabId) }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let split = movingTabs.count == 2 ? splitGroup(forTabId: movingTabs[0].guid) : nil
        let activeIndex = movingTabs.firstIndex(where: { $0.guid == focusingTab?.guid }) ?? 0
        var created: [Tab] = []
        for tab in movingTabs {
            guard let url = tab.url, !url.isEmpty, resolveTab(tab.guid) === tab else {
                throw TravelBackFailure.targetChanged
            }
            created.append(try await target.travelBackCreatePage(.init(url: url), deadline: deadline))
        }
        if let split, created.count == 2 {
            target.focuseTab(created[activeIndex])
            created[activeIndex].webContentWrapper?.setAsActiveTab()
            guard let id = target.createSplit(leftTabId: created[0].guid, rightTabId: created[1].guid,
                                              layout: split.layout) else { throw TravelBackFailure.unavailable }
            let _: SplitGroup = try await target.travelBackWait(until: deadline) { target.splitGroup(forId: id) }
            target.updateSplitRatio(id, ratio: split.ratio)
        }
        let destination = try await target.prepareTravelBackDestination(created[activeIndex],
            sourceSidebar: sidebar, deadline: deadline, waitUntilEnabled: false)
        let operationId = UUID().uuidString
        let expiresAt = ProcessInfo.processInfo.systemUptime + 20
        profileMoveRequests[sidebar.chatTabId] = .init(operationId: operationId, destination: destination,
            snapshot: target.travelBackScene(for: created[activeIndex]), expiresAt: expiresAt,
            finishBefore: (Date().timeIntervalSince1970 + 20) * 1000)
        defer {
            if profileMoveRequests[sidebar.chatTabId]?.operationId == operationId {
                profileMoveRequests.removeValue(forKey: sidebar.chatTabId)
            }
        }
        ExtensionMessaging.shared.broadcast(type: "sidecar.travelBack.profileMoveAvailable",
            payload: "{\"boundTabIds\":[\(sidebar.boundTabId)]}")
        let accepted: Bool = try await travelBackWait(until: expiresAt,
            events: $profileMoveRequests.map { _ in () }.eraseToAnyPublisher()) {
                guard let request = self.profileMoveRequests[sidebar.chatTabId], request.operationId == operationId else {
                    throw TravelBackFailure.targetChanged
                }
                return request.completed
            }
        guard accepted, hasTravelBackSidebar(sidebar),
              target.hasTravelBackSidebar(destination.sidebar) else { throw TravelBackFailure.targetChanged }
        for tab in movingTabs where resolveTab(tab.guid) === tab { tab.close() }
    }

    func hasTravelBackSidebar(_ sidebar: TravelBackSidebar) -> Bool {
        sidebar.windowId == windowId && sidebar.profileId == profileId
            && travelBackSource(boundTabId: sidebar.boundTabId).sidebar == sidebar
    }

    func offerTravelBackHandoff(_ handoff: TravelBackHandoff) throws {
        guard hasTravelBackSidebar(handoff.destination) else { throw TravelBackFailure.targetChanged }
        let key = handoff.destination.chatTabId
        if let pending = travelBackHandoffs[key], pending.expiresAt > ProcessInfo.processInfo.systemUptime,
           pending.acceptBy > ProcessInfo.processInfo.systemUptime {
            throw TravelBackFailure.busy
        }
        travelBackHandoffs[key] = handoff
        // No conversation IDs or tokens in notifications. Cold receivers pull.
        let payload = "{\"boundTabIds\":[\(handoff.destination.boundTabId)]}"
        ExtensionMessaging.shared.broadcast(type: "sidecar.travelBack.handoffAvailable", payload: payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard self?.travelBackHandoffs[key]?.operationId == handoff.operationId else { return }
            self?.travelBackHandoffs.removeValue(forKey: key)
        }
    }

    func waitForTravelBackHandoff(_ operationId: String, destination: TravelBackSidebar) async throws -> Bool {
        try await travelBackWait(until: ProcessInfo.processInfo.systemUptime + 7.5,
            events: $travelBackHandoffs.map { _ in () }.eraseToAnyPublisher()) {
                guard self.hasTravelBackSidebar(destination),
                      let handoff = self.travelBackHandoffs[destination.chatTabId],
                      handoff.operationId == operationId,
                      handoff.expiresAt > ProcessInfo.processInfo.systemUptime else { return false }
                switch handoff.status {
                case .accepted: return true
                case .rejected: return false
                case .offered, .claimed:
                    return handoff.acceptBy > ProcessInfo.processInfo.systemUptime ? nil : false
                }
            }
    }

    /// An exact-instance close after acknowledgement, never a focus-relative toggle.
    /// If binding changed meanwhile, leave the user's new sidebar alone.
    func closeTravelBackSource(_ source: TravelBackSidebar, destination: TravelBackSidebar) throws {
        guard source != destination,
              let (identifier, _) = aiChatTabs.first(where: { $0.value.guid == source.chatTabId }),
              let content = tab(forChatIdentifier: identifier),
              chatIdentifier(for: content) == identifier else { return }
        setAIChatCollapsed(for: content, collapsed: true)
    }
}

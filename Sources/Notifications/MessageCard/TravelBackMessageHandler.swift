// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation

/// Trusted packaged Sidecar UI commands, not the external-agent automation API.
/// The bridge proves extension identity, NOT the caller's Profile/frame.
/// Native holds only transient, addressed handoff IDs; chat data stays in phi-agent.
enum TravelBackMessageHandler {
    static let messageTypes = ["snapshot", "restore", "closeSource", "offer", "claim", "ack", "wait", "cancel", "claimProfileMove", "finishProfileMove"]
        .map { "sidecar.travelBack." + $0 }

    struct Request: Decodable {
        let profileId: String
        let windowId: Int?
        let boundTabId: Int?
        let sourceKind: String?
        let sourceId: String?
        let profileMove: Bool?
        let snapshot: TravelBackScene?
        let sourceSidebar: TravelBackSidebar?
        let destinationSidebar: TravelBackSidebar?
        let operationId: String?
        let conversationId: String?
        let success: Bool?
    }

    @MainActor
    static func handle(_ context: ExtensionMessageContext) async -> String {
        do {
            guard context.senderId == SidecarAIOutputStateStore.extensionId else {
                throw TravelBackFailure.unauthorizedSender
            }
            guard context.payload.utf8.count <= 65536,
                  let data = context.payload.data(using: .utf8),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  !request.profileId.isEmpty else { throw TravelBackFailure.invalidSnapshot }
            let manager = SpaceSessionControllersManager.shared
            let source: BrowserState?
            if request.sourceKind == "phi-chat" {
                // Product isolation trusts the packaged UI's native Profile lookup.
                // This declaration is not Chromium-authenticated caller identity.
                guard request.windowId == nil, request.boundTabId == nil,
                      let sourceId = request.sourceId, UUID(uuidString: sourceId) != nil,
                      ApplicationState.shared.isAuthenticated,
                      PhiPreferences.AISettings.phiAIEnabled.loadValue() else {
                    throw TravelBackFailure.unavailable
                }
                source = nil
            } else {
                guard request.sourceKind == nil, request.sourceId == nil,
                      let windowId = request.windowId,
                      let state = manager.getBrowserState(for: windowId),
                      state.profileId == request.profileId, state.travelBackAllowed else {
                    throw TravelBackFailure.unavailable
                }
                source = state
            }
            let binding: (tab: Tab?, sidebar: TravelBackSidebar?) =
                source?.travelBackSource(boundTabId: request.boundTabId) ?? (nil, nil)
            switch context.type {
            case "sidecar.travelBack.claimProfileMove":
                guard let source, let sidebar = binding.sidebar else { throw TravelBackFailure.targetChanged }
                guard var move = source.profileMoveRequests[sidebar.chatTabId], !move.claimed,
                      move.expiresAt > ProcessInfo.processInfo.systemUptime else {
                    return "{\"ok\":true,\"result\":{\"move\":null}}"
                }
                move.claimed = true
                source.profileMoveRequests[sidebar.chatTabId] = move
                return try encode(ProfileMoveReply(move: .init(operationId: move.operationId,
                    destination: move.destination, snapshot: move.snapshot, finishBefore: move.finishBefore)))
            case "sidecar.travelBack.finishProfileMove":
                guard let source, let sidebar = binding.sidebar, let success = request.success,
                      var move = source.profileMoveRequests[sidebar.chatTabId], move.claimed,
                      move.operationId == request.operationId,
                      move.expiresAt > ProcessInfo.processInfo.systemUptime else { throw TravelBackFailure.targetChanged }
                move.completed = success
                source.profileMoveRequests[sidebar.chatTabId] = move
                return emptyReply
            case "sidecar.travelBack.snapshot":
                guard let source else { throw TravelBackFailure.unavailable }
                return try encode(source.travelBackScene(for: binding.tab))
            case "sidecar.travelBack.restore":
                return try encode(await restore(request, source: source, binding: binding))
            case "sidecar.travelBack.claim":
                guard let source, request.boundTabId != nil, let recipient = binding.sidebar else {
                    throw TravelBackFailure.targetChanged
                }
                guard var handoff = source.travelBackHandoffs[recipient.chatTabId],
                      handoff.claim(by: recipient, now: ProcessInfo.processInfo.systemUptime) else {
                    return "{\"ok\":true,\"result\":{\"handoff\":null}}"
                }
                source.travelBackHandoffs[recipient.chatTabId] = handoff
                return try encode(ClaimReply(handoff: .init(operationId: handoff.operationId,
                    conversationId: handoff.conversationId, acceptBefore: handoff.acceptBefore, profileMove: handoff.profileMove)))
            case "sidecar.travelBack.ack":
                guard let source, let recipient = binding.sidebar, let success = request.success,
                      var handoff = source.travelBackHandoffs[recipient.chatTabId],
                      handoff.operationId == request.operationId,
                      handoff.acknowledge(by: recipient, success: success,
                                          now: ProcessInfo.processInfo.systemUptime) else {
                    throw TravelBackFailure.targetChanged
                }
                source.travelBackHandoffs[recipient.chatTabId] = handoff
                return emptyReply
            case "sidecar.travelBack.offer", "sidecar.travelBack.wait",
                 "sidecar.travelBack.cancel", "sidecar.travelBack.closeSource":
                guard let operationId = request.operationId, UUID(uuidString: operationId) != nil,
                      let destination = request.destinationSidebar,
                      let target = manager.getBrowserState(for: destination.windowId),
                      target.profileId == destination.profileId, target.travelBackAllowed else {
                    throw TravelBackFailure.targetChanged
                }
                if context.type == "sidecar.travelBack.offer" {
                    guard let conversationId = request.conversationId, !conversationId.isEmpty,
                          conversationId.utf8.count <= 512 else { throw TravelBackFailure.invalidSnapshot }
                    if request.profileMove == true {
                        guard let source, let sidebar = binding.sidebar,
                              let move = source.profileMoveRequests[sidebar.chatTabId],
                              move.operationId == operationId, move.destination.sidebar == destination,
                              move.expiresAt > ProcessInfo.processInfo.systemUptime else { throw TravelBackFailure.targetChanged }
                    }
                    try target.offerTravelBackHandoff(.init(operationId: operationId,
                        conversationId: conversationId, sourceWindowId: request.windowId,
                        sourceProfileId: request.profileId, sourceId: request.sourceId,
                        profileMove: request.profileMove == true, destination: destination,
                        expiresAt: ProcessInfo.processInfo.systemUptime + 60,
                        acceptBy: ProcessInfo.processInfo.systemUptime + 7.5,
                        acceptBefore: (Date().timeIntervalSince1970 + 7.5) * 1000))
                    return emptyReply
                }
                let handoff = target.travelBackHandoffs[destination.chatTabId]
                if context.type == "sidecar.travelBack.cancel", handoff == nil { return emptyReply }
                guard let handoff, handoff.operationId == operationId,
                      handoff.sourceWindowId == request.windowId,
                      handoff.sourceProfileId == request.profileId,
                      handoff.sourceId == request.sourceId,
                      handoff.destination == destination else { throw TravelBackFailure.targetChanged }
                if context.type == "sidecar.travelBack.cancel" {
                    target.travelBackHandoffs.removeValue(forKey: destination.chatTabId)
                    return emptyReply
                }
                if context.type == "sidecar.travelBack.wait" {
                    let accepted = (try? await target.waitForTravelBackHandoff(operationId, destination: destination)) ?? false
                    return try encode(["accepted": accepted])
                }
                guard let source, handoff.status == .accepted, handoff.expiresAt > ProcessInfo.processInfo.systemUptime,
                      target.hasTravelBackSidebar(destination),
                      let original = request.sourceSidebar, original.windowId == source.windowId,
                      original.profileId == source.profileId else { throw TravelBackFailure.targetChanged }
                try source.closeTravelBackSource(original, destination: destination)
                return emptyReply
            default:
                throw TravelBackFailure.unavailable
            }
        } catch {
            let code = (error as? TravelBackFailure)?.rawValue ?? "unavailable"
            AppLogWarn("[TravelBack] request failed type=\(context.type) code=\(code)")
            return "{\"ok\":false,\"error\":\"\(code)\"}"
        }
    }

    @MainActor
    private static func restore(_ request: Request, source: BrowserState?,
                                binding: (tab: Tab?, sidebar: TravelBackSidebar?)) async throws -> TravelBackDestination {
        guard let snapshot = request.snapshot, let page = snapshot.page, page.isReopenable,
              let profileId = snapshot.profileId, let spaceId = snapshot.window?.spaceId else {
            throw TravelBackFailure.invalidSnapshot
        }
        _ = try snapshot.layout?.splitView?.validated(for: page)
        ProfileManager.shared.refresh()
        guard ProfileManager.shared.profile(for: profileId) != nil,
              let space = SpaceManager.shared.spaces.first(where: { $0.spaceId == spaceId }),
              space.profileId == profileId, !space.isAgentSpace,
              !SpaceManager.isIncognitoSpaceId(spaceId) else { throw TravelBackFailure.targetUnavailable }
        guard source?.travelBackRunning != true else { throw TravelBackFailure.busy }
        let manager = SpaceSessionControllersManager.shared
        let candidates = manager.getAllWindows().compactMap(\.browserState).filter {
            $0.profileId == profileId && $0.spaceId == spaceId && $0.travelBackWindowAllowed
        }
        func reference(_ tab: Tab, state: BrowserState) -> TravelBackTabRef {
            .init(tabId: tab.guid, windowId: state.windowId, url: tab.url ?? "",
                  profileId: state.profileId, spaceId: state.spaceId)
        }
        let current = request.boundTabId == nil ? nil : source.flatMap { state in
            binding.tab.map { reference($0, state: state) }
        }
        let anchorRef = TravelBackTabRef.anchor(for: snapshot, current: current,
            openTabs: candidates.flatMap { state in state.tabs.map { reference($0, state: state) } })
        let windowId = anchorRef?.windowId ?? TravelBackScene.destinationWindowId(
            for: snapshot, sourceWindowId: source?.windowId, availableWindowIds: candidates.map(\.windowId))
        let spaces = SpaceManager.shared
        func eligibleSlot(_ slot: SpaceWindowSlot) -> Bool {
            guard let activeSpaceId = slot.activeSpaceId,
                  let state = slot.windowController(for: activeSpaceId)?.browserState else { return false }
            return state.travelBackWindowAllowed
        }
        let fallback = windowId.flatMap { spaces.slot(forWindowId: $0) }
            ?? source.flatMap { spaces.slot(forWindowId: $0.windowId) }
            ?? spaces.keySlot.flatMap { eligibleSlot($0) ? $0 : nil }
            ?? spaces.slots.first(where: eligibleSlot)
        let slot = fallback ?? spaces.createSlot(initialSpaceId: spaceId)
        let mintedSlot = fallback == nil
        defer { spaces.reclaimMintedSlot(slot, mintedForThisAttempt: mintedSlot) }
        let existing = windowId.flatMap { manager.getBrowserState(for: $0) }
        guard existing === source || existing?.travelBackRunning != true else { throw TravelBackFailure.busy }
        source?.travelBackRunning = true
        existing?.travelBackRunning = true
        var activated: BrowserState?
        defer {
            source?.travelBackRunning = false
            existing?.travelBackRunning = false
            activated?.travelBackRunning = false
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        try await activate(slot: slot, spaceId: spaceId, deadline: deadline)
        guard let target = slot.windowController(for: spaceId)?.browserState,
              slot.activeSpaceId == spaceId, target.profileId == profileId, target.travelBackAllowed,
              SpaceManager.shared.spaces.first(where: { $0.spaceId == spaceId })?.profileId == profileId else {
            throw TravelBackFailure.targetChanged
        }
        if let source, manager.getBrowserState(for: source.windowId) !== source {
            throw TravelBackFailure.targetChanged
        }
        guard target === source || target === existing || !target.travelBackRunning else { throw TravelBackFailure.busy }
        target.travelBackRunning = true
        activated = target
        let anchor = anchorRef.flatMap { target.resolveTab($0.tabId) }
        if let anchorRef, anchor == nil || anchorRef.windowId != target.windowId {
            throw TravelBackFailure.targetChanged
        }
        return try await target.restoreTravelBack(snapshot, anchor: anchor,
            sourceSidebar: request.boundTabId == nil ? nil : binding.sidebar, deadline: deadline)
    }

    /// Activation owns window visibility, Profile loading and lazy session replay.
    /// Timeout stops our continuation; it cannot cancel already-dispatched browser work.
    @MainActor
    private static func activate(slot: SpaceWindowSlot, spaceId: String, deadline: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            var timeout: DispatchWorkItem?
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !settled else { return }
                settled = true
                timeout?.cancel()
                continuation.resume(with: result)
            }
            let item = DispatchWorkItem { finish(.failure(TravelBackFailure.timedOut)) }
            timeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: item)
            slot.activate(spaceId: spaceId, userInitiated: true,
                          onActivationFailed: { finish(.failure(TravelBackFailure.targetChanged)) },
                          onSwapSettled: { finish(.success(())) })
        }
    }

    private struct ClaimReply: Encodable {
        struct Envelope: Encodable {
            let operationId: String
            let conversationId: String
            let acceptBefore: Double
            let profileMove: Bool
        }
        let handoff: Envelope
    }

    private struct ProfileMoveReply: Encodable {
        struct Move: Encodable {
            let operationId: String
            let destination: TravelBackDestination
            let snapshot: TravelBackScene
            let finishBefore: Double
        }
        let move: Move
    }

    private static let emptyReply = "{\"ok\":true,\"result\":{}}"
    private struct Reply<T: Encodable>: Encodable {
        let ok = true
        let result: T
    }
    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(Reply(result: value))
        guard let text = String(data: data, encoding: .utf8) else { throw TravelBackFailure.unavailable }
        return text
    }
}

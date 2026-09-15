// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation

/// Durable, reopenable data only. Live tab IDs are optional session hints.
struct TravelBackPage: Codable, Equatable {
    let url: String
    var title: String? = nil
    var favicon: String? = nil

    var isReopenable: Bool {
        guard url.utf8.count <= 16384, let parsed = URL(string: url),
              let host = parsed.host, !host.isEmpty else { return false }
        return parsed.scheme == "http" || parsed.scheme == "https"
    }
}

struct TravelBackSplit: Codable, Equatable {
    let members: [TravelBackPage]
    var orientation: String? = nil
    var ratio: Double? = nil
    var activeIndex: Int? = nil

    func validated(for page: TravelBackPage) throws -> TravelBackSplit {
        guard members.count == 2, members.allSatisfy(\.isReopenable),
              orientation == nil || ["vertical", "horizontal"].contains(orientation!),
              ratio == nil || (ratio!.isFinite && ratio! > 0 && ratio! < 1),
              activeIndex == nil || (0...1).contains(activeIndex!) else {
            throw TravelBackFailure.invalidSnapshot
        }
        return TravelBackSplit(
            members: members, orientation: orientation ?? "vertical", ratio: ratio ?? 0.5,
            activeIndex: activeIndex ?? members.firstIndex(where: { $0.url == page.url }) ?? 0
        )
    }
}

struct TravelBackScene: Codable {
    struct TabRef: Codable { let tabId: Int }
    /// One process incarnation; persisted numeric IDs are unsafe after restart.
    static let currentRuntimeId = UUID().uuidString
    struct WindowRef: Codable { let windowId: Int; var spaceId: String? = nil }
    struct Layout: Codable { let splitView: TravelBackSplit? }
    var page: TravelBackPage? = nil
    var tab: TabRef? = nil
    var window: WindowRef? = nil
    var profileId: String? = nil
    var runtimeId: String? = nil
    var layout: Layout? = nil
    /// Live capture-only membership, omitted by the persisted client schema.
    var relatedTabIds: [Int]? = nil

    static func destinationWindowId(for scene: TravelBackScene, sourceWindowId: Int?,
                                    availableWindowIds: [Int]) -> Int? {
        if scene.runtimeId == currentRuntimeId, let recorded = scene.window?.windowId,
           availableWindowIds.contains(recorded) { return recorded }
        if let sourceWindowId, availableWindowIds.contains(sourceWindowId) { return sourceWindowId }
        return availableWindowIds.sorted().first
    }
}

enum TravelBackFailure: String, Error {
    case unauthorizedSender = "unauthorized_sender"
    case invalidSnapshot = "invalid_snapshot"
    case unavailable = "unavailable"
    case targetChanged = "target_changed"
    case busy = "busy"
    case timedOut = "timed_out"
    case targetUnavailable = "target_unavailable"
}

struct TravelBackTabRef: Equatable {
    let tabId: Int
    let windowId: Int
    let url: String
    var profileId: String? = nil
    var spaceId: String? = nil

    static func anchor(for scene: TravelBackScene, current: TravelBackTabRef?,
                       openTabs: [TravelBackTabRef]) -> TravelBackTabRef? {
        let matchesScope: (TravelBackTabRef) -> Bool = {
            scene.profileId != nil && scene.window?.spaceId != nil
                && $0.profileId == scene.profileId && $0.spaceId == scene.window?.spaceId
        }
        if let current, matchesScope(current), current.url == scene.page?.url { return current }
        guard scene.runtimeId == TravelBackScene.currentRuntimeId,
              let recordedId = scene.tab?.tabId else { return nil }
        return openTabs.first { $0.tabId == recordedId && matchesScope($0) }
    }
}

struct TravelBackSidebar: Codable, Equatable {
    let windowId: Int
    let chatTabId: Int
    /// The fixed URL binding can outlive its original content tab.
    let boundTabId: Int
    let profileId: String
}

/// A bounded control-plane envelope, owned by the destination BrowserState.
/// Claiming is not success: only the exact recipient may acknowledge it.
struct TravelBackHandoff {
    enum Status { case offered, claimed, accepted, rejected }
    let operationId: String
    let conversationId: String
    let sourceWindowId: Int?
    let sourceProfileId: String
    var sourceId: String? = nil
    var profileMove = false
    let destination: TravelBackSidebar
    let expiresAt: Double
    let acceptBy: Double
    /// Wall-clock deadline only for rejecting delayed JS delivery; native uses monotonic time.
    let acceptBefore: Double
    var status: Status = .offered

    mutating func claim(by recipient: TravelBackSidebar, now: Double) -> Bool {
        guard recipient == destination, now < expiresAt, now < acceptBy, status == .offered else { return false }
        status = .claimed
        return true
    }

    mutating func acknowledge(by recipient: TravelBackSidebar, success: Bool, now: Double) -> Bool {
        guard recipient == destination, now < expiresAt, now < acceptBy, status == .claimed else { return false }
        status = success ? .accepted : .rejected
        return true
    }
}

/// Pure conflict policy; never searches other tabs by URL or dismantles a split.
enum TravelBackSplitPlan: Equatable {
    case reuse
    case completeAnchor
    case newPair

    static func choose(recorded: TravelBackSplit, existingURLs: [String]?,
                       hasAnchor: Bool, anchorCanJoin: Bool) -> Self {
        if let existingURLs {
            return existingURLs == recorded.members.map(\.url) ? .reuse : .newPair
        }
        return hasAnchor && anchorCanJoin ? .completeAnchor : .newPair
    }
}

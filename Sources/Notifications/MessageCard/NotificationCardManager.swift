// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Foundation
import Kingfisher

final class NotificationCardManager: ObservableObject {
    static let shared = NotificationCardManager()

    private let maxQueueSize: Int
    private let now: () -> Int64
    private let messenger: ExtensionMessagingProtocol
    private let queue = DispatchQueue(label: "notification.card.manager")
    private var cards: [String: Card] = [:]
    private var order: [String] = []
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var latestCard: Card?
    
    /// All cards in order (newest first)
    @Published private(set) var allCards: [Card] = []
    
    /// Current displayed card index for pagination
    @Published var currentIndex: Int = 0
    
    // MARK: - Display Mode Management
    
    /// Presentation mode used for notification cards.
    enum CardDisplayMode {
        /// Card is shown inside the sidebar UI.
        case sidebar
        /// Card is shown in the overlay toast container for legacy layouts.
        case legacy
    }
    
    /// Currently active presentation mode.
    @Published private(set) var activeDisplayMode: CardDisplayMode = .sidebar
    
    /// Tracks whether cards were explicitly shown by the user.
    @Published private(set) var isManuallyShown: Bool = false
    
    /// Tracks whether the current card stack was explicitly dismissed by the user.
    @Published private(set) var isExplicitlyHidden: Bool = false
    
    /// Fires on subscription and whenever the account's popup mode changes,
    /// which `isNotificationPopupEnabled` reads but nothing publishes.
    private static var popupModeChanges: AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: .notificationPopupModeDidChange)
            .map { _ in }
            .prepend(())
            .eraseToAnyPublisher()
    }

    /// Visibility publisher for sidebar presentation.
    var shouldShowInSidebar: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4($latestCard, $isManuallyShown, $activeDisplayMode, $isExplicitlyHidden)
            .combineLatest(Self.popupModeChanges)
            .map { [weak self] values, _ in
                let (latestCard, isManuallyShown, activeMode, isExplicitlyHidden) = values
                guard latestCard != nil, activeMode == .sidebar, !isExplicitlyHidden else { return false }
                return self?.isNotificationPopupEnabled == true || isManuallyShown
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Visibility publisher for legacy overlay presentation.
    var shouldShowInLegacy: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4($latestCard, $isManuallyShown, $activeDisplayMode, $isExplicitlyHidden)
            .combineLatest(Self.popupModeChanges)
            .map { [weak self] values, _ in
                let (latestCard, isManuallyShown, activeMode, isExplicitlyHidden) = values
                let hasCard = latestCard != nil
                let isLegacy = activeMode == .legacy
                let isPopupEnabled = self?.isNotificationPopupEnabled == true
                
                guard hasCard, isLegacy, !isExplicitlyHidden else {
                    AppLogDebug("[CardDisplay] shouldShowInLegacy=false: hasCard=\(hasCard), isLegacy=\(isLegacy), isExplicitlyHidden=\(isExplicitlyHidden)")
                    return false
                }
                let result = isPopupEnabled || isManuallyShown
                AppLogDebug("[CardDisplay] shouldShowInLegacy=\(result): isPopupEnabled=\(isPopupEnabled), isManuallyShown=\(isManuallyShown)")
                return result
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Whether automatic popup mode is enabled for the current account.
    private var isNotificationPopupEnabled: Bool {
        guard let account = AccountController.shared.account else { return true }
        return account.userDefaults.notificationPopupMode == .popup
    }

    struct Card {
        let taskId: String
        let messageId: String
        let taskType: String?
        let timestamp: Int64
        let title: String
        let message: String
        let buttonTitle: String?
        let expiresAt: Int64
        let correlationId: String?
        var timer: DispatchSourceTimer?
        var driverPrincipalId: String? = nil
        var kind: Kind = .action

        /// What the card presents. The sender picks it with the payload's
        /// `kind` field; an absent or unknown value is an action card.
        enum Kind: String {
            /// A suggestion with one primary button.
            case action
            /// The agent is working on `title`; `message` is its current
            /// activity. It has no button, and the sender updates it by
            /// resending the same `task_id` and ends it with a revoke or with
            /// an action card for the same `task_id`.
            case working
        }
        
        enum Decision: String {
            case accept, reject, timeout, ignore
        }
    }

    init(
        maxQueueSize: Int = 5,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        messenger: ExtensionMessagingProtocol = ExtensionMessaging.shared
    ) {
        self.maxQueueSize = maxQueueSize
        self.now = now
        self.messenger = messenger
        
        Task { @MainActor in
            setupLayoutModeObserver()
        }
    }
    
    // MARK: - Display Mode Control
    
    /// Marks the card stack as manually shown in the requested mode.
    func showManually(for mode: CardDisplayMode) {
        guard latestCard != nil else {
            AppLogDebug("[CardDisplay] showManually: no card to show")
            return
        }
        AppLogDebug("[CardDisplay] showManually: mode=\(mode), setting isManuallyShown=true, isExplicitlyHidden=false")
        activeDisplayMode = mode
        isManuallyShown = true
        isExplicitlyHidden = false
    }
    
    /// Marks the current card stack as explicitly hidden.
    func hideCard() {
        AppLogDebug("[CardDisplay] hideCard: setting isManuallyShown=false, isExplicitlyHidden=true")
        isManuallyShown = false
        isExplicitlyHidden = true
    }
    
    /// Updates the active display mode when layout changes.
    ///
    /// Runs on every defaults change, and every sidebar bottom bar of every
    /// Space observes this object, so an unchanged mode is not reassigned.
    private func setDisplayMode(_ mode: CardDisplayMode) {
        guard activeDisplayMode != mode else { return }
        isManuallyShown = false
        isExplicitlyHidden = false
        activeDisplayMode = mode
    }
    
    // MARK: - Layout Mode Observer
    @MainActor
    private func setupLayoutModeObserver() {
        updateDisplayModeFromLayoutMode()
        
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDisplayModeFromLayoutMode()
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    private func updateDisplayModeFromLayoutMode() {
        let layoutMode = BrowserState.buildLayoutMode()
        let newMode: CardDisplayMode
        switch layoutMode {
        case .comfortable:
            newMode = .legacy
        case .performance, .balanced:
            newMode = .sidebar
        }
        setDisplayMode(newMode)
    }

    var count: Int { queue.sync { order.count } }
    var oldestTaskId: String? { queue.sync { order.last } }
    var latestTaskId: String? { queue.sync { order.first } }

    /// Handle a request from the new type-based messaging API
    /// - Parameter context: The message context containing type, payload, and requestId
    func handleRequest(context: ExtensionMessageContext) {
        guard let data = context.payload.data(using: .utf8),
              let payloadDict = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else { return }

        if payloadDict["action"]?.stringValue == "notification.card.revoke" {
            let messageId = payloadDict["messageId"]?.stringValue ?? ""
            let revoked = revoke(messageId: messageId)
            messenger.sendResponse(revoked ? messageId : "", requestId: context.requestId)
            return
        }
        
        let result = enqueueCard(envelope: payloadDict, correlationId: context.requestId)
        messenger.sendResponse(result ?? "", requestId: context.requestId)
    }

    private struct AgentNotificationRequest: Decodable {
        let title: String
        let message: String
        let buttonTitle: String?
        let expiresInSeconds: Int?
    }

    /// App-level agent notifications reuse the card queue and popup preference.
    /// The acknowledgement is immediate; decisions are separate session-scoped events.
    func handleAgentRequest(context: ExtensionMessageContext) -> String {
        guard context.senderId == "cdp",
              let principalId = context.driverPrincipalId, !principalId.isEmpty else {
            return #"{"ok":false,"error":"agent_session_required"}"#
        }
        guard let data = context.payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentNotificationRequest.self, from: data),
              !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...86_400).contains(request.expiresInSeconds ?? 300) else {
            return #"{"ok":false,"error":"invalid_params"}"#
        }
        let notificationId = "agent-notification:\(UUID().uuidString)"
        let timestamp = now()
        let expiresAt = timestamp + Int64(request.expiresInSeconds ?? 300) * 1000
        let payload: [String: AnyCodable] = [
            "task_id": .string(notificationId),
            "title": .string(request.title),
            "description": .string(request.message),
            "button_title": .string(request.buttonTitle ?? "Run"),
            "timestamp": .string(String(timestamp)),
            "expires_at": .string(String(expiresAt)),
        ]
        enqueueCard(envelope: ["messageId": .string(notificationId), "payload": .init(payload)],
                    correlationId: context.requestId, driverPrincipalId: principalId)
        // The ID is generated locally and contains only a fixed prefix and a UUID.
        return #"{"notificationId":"\#(notificationId)"}"#
    }

    @discardableResult
    func enqueueCard(envelope: [String: AnyCodable], correlationId: String?,
                     driverPrincipalId: String? = nil) -> String? {
        guard let payload = envelope["payload"]?.dictionaryValue else {
            return nil
        }
        guard let taskId = payload["task_id"]?.stringValue else { return nil }
        let messageId = envelope["messageId"]?.stringValue ?? ""
        let expiresAt = payload["expires_at"]?.int64Value ?? 0
        let taskType = payload["task_type"]?.stringValue
        let timestamp = payload["timestamp"]?.int64Value ?? 0
        let title = payload["title"]?.stringValue ?? ""
        let message = payload["description"]?.stringValue ?? ""
        let kind = payload["kind"]?.stringValue.flatMap(Card.Kind.init(rawValue:)) ?? .action
        let rawButtonTitle = payload["button_title"]?.stringValue
        let buttonTitle: String?
        switch kind {
        case .action:
            buttonTitle = rawButtonTitle?.isEmpty == false ? rawButtonTitle : "Run"
        case .working:
            buttonTitle = nil
        }
        let nowMs = now()
        if expiresAt > 0, expiresAt <= nowMs {
            let card = Card(
                taskId: taskId,
                messageId: messageId,
                taskType: taskType,
                timestamp: timestamp,
                title: title,
                message: message,
                buttonTitle: buttonTitle,
                expiresAt: expiresAt,
                correlationId: correlationId,
                timer: nil,
                driverPrincipalId: driverPrincipalId,
                kind: kind
            )
            queue.sync {
                if let existing = cards.removeValue(forKey: taskId) {
                    existing.timer?.cancel()
                    order.removeAll { $0 == taskId }
                    publishLatestLocked()
                }
            }
            sendTimeout(card: card)
            return taskId
        }

        return queue.sync {
            defer { publishLatestLocked() }
            let existing = cards[taskId]
            existing?.timer?.cancel()
            // A working card's progress updates replace it where it stands,
            // so they neither jump the stack nor reopen a hidden one.
            let updatesInPlace = existing?.kind == .working && kind == .working
            if !updatesInPlace {
                if existing != nil {
                    order.removeAll { $0 == taskId }
                }
                if order.count >= maxQueueSize, let evicted = order.popLast() {
                    if let evictedCard = cards.removeValue(forKey: evicted) {
                        evictedCard.timer?.cancel()
                        sendTimeout(card: evictedCard)
                    }
                }
                order.insert(taskId, at: 0)
            }
            let card = Card(
                taskId: taskId,
                messageId: messageId,
                taskType: taskType,
                timestamp: timestamp,
                title: title,
                message: message,
                buttonTitle: buttonTitle,
                expiresAt: expiresAt,
                correlationId: correlationId,
                timer: nil,
                driverPrincipalId: driverPrincipalId,
                kind: kind
            )
            cards[taskId] = card
            scheduleExpiry(for: taskId)
            return taskId
        }
    }

    /// The `task_type` of the Sidecar's conversation cards (task reports and
    /// wake-rule results), whose `task_id` is the conversation to open.
    static let conversationCardType = "task-report"

    /// The primary button. A conversation card first tries
    /// `showConversation` (the AI Chat panel of the window it was clicked
    /// in), then sends `accept` with `opened_in: "sidebar"` when that showed
    /// it, so the sender opens Phi Chat only when it did not. The card leaves
    /// the queue at once either way. Every other card is accepted at once.
    func accept(_ card: Card, showConversation: (@MainActor (String) async -> Bool)?) {
        guard card.taskType == Self.conversationCardType, card.driverPrincipalId == nil,
              let showConversation else {
            decide(card: card, decision: .accept)
            return
        }
        let taken: Card? = queue.sync {
            guard let stored = cards.removeValue(forKey: card.taskId) else { return nil }
            order.removeAll { $0 == card.taskId }
            stored.timer?.cancel()
            publishLatestLocked()
            return stored
        }
        guard let taken else { return }
        Task { @MainActor [weak self] in
            let shown = await showConversation(taken.taskId)
            self?.sendDecision(card: taken, decision: .accept, openedIn: shown ? "sidebar" : nil)
        }
    }

    func decide(card: Card, decision: Card.Decision) {
        queue.sync {
            guard let _ = cards.removeValue(forKey: card.taskId) else { return }
            order.removeAll { $0 == card.taskId }
            card.timer?.cancel()
            publishLatestLocked()
            sendDecision(card: card, decision: decision)
        }
    }
    
    /// Takes down the cards a sender showed under `messageId`, without a
    /// decision: the sender withdrew them itself. Returns whether any was shown.
    @discardableResult
    func revoke(messageId: String) -> Bool {
        guard !messageId.isEmpty else { return false }
        return queue.sync {
            let revokedIds = order.filter { cards[$0]?.messageId == messageId }
            guard !revokedIds.isEmpty else { return false }
            for taskId in revokedIds {
                cards.removeValue(forKey: taskId)?.timer?.cancel()
            }
            order.removeAll { revokedIds.contains($0) }
            publishLatestLocked()
            return true
        }
    }

    /// Dismiss a card without sending a decision
    func dismiss(_ card: Card) {
        queue.sync {
            guard cards.removeValue(forKey: card.taskId) != nil else { return }
            order.removeAll { $0 == card.taskId }
            card.timer?.cancel()
            publishLatestLocked()
        }
    }
    
    // MARK: - Pagination
    
    /// Shows the previous card, wrapping around when needed.
    func showPrevious() {
        guard allCards.count > 1 else { return }
        currentIndex = (currentIndex - 1 + allCards.count) % allCards.count
    }
    
    /// Shows the next card, wrapping around when needed.
    func showNext() {
        guard allCards.count > 1 else { return }
        currentIndex = (currentIndex + 1) % allCards.count
    }
    
    /// Get current displayed card based on currentIndex
    var currentCard: Card? {
        guard !allCards.isEmpty else { return nil }
        let safeIndex = min(currentIndex, allCards.count - 1)
        return allCards[safeIndex]
    }

    private func scheduleExpiry(for taskId: String) {
        guard let card = cards[taskId], card.expiresAt > 0 else { return }
        let deadlineMs = card.expiresAt - now()
        if deadlineMs <= 0 {
            sendTimeout(card: card)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(deadlineMs)))
        timer.setEventHandler { [weak self] in
            self?.expire(taskId: taskId)
        }
        timer.resume()
        var updated = card
        updated.timer = timer
        cards[taskId] = updated
    }

    private func expire(taskId: String) {
        guard let card = cards.removeValue(forKey: taskId) else { return }
        order.removeAll { $0 == taskId }
        publishLatestLocked()
        sendTimeout(card: card)
    }

    private func sendTimeout(card: Card) {
        sendDecision(card: card, decision: .timeout)
    }

    private func sendDecision(card: Card, decision: Card.Decision, openedIn: String? = nil) {
        if let principalId = card.driverPrincipalId {
            let response = ["notificationId": card.taskId, "decision": decision.rawValue]
            guard let data = try? JSONEncoder().encode(response),
                  let json = String(data: data, encoding: .utf8) else { return }
            messenger.broadcastToAgent(
                type: "notification.response", payload: json, principalId: principalId)
            return
        }
        var payload: [String: AnyCodable] = [
            "decision": .string(decision.rawValue),
            "task_id": .string(card.taskId),
            "title": .string(card.title),
            "timestamp": .string("\(Date.now.timeIntervalSince1970)"),
            "task_type": .string(card.taskType ?? "")
        ]
        if let openedIn {
            payload["opened_in"] = .string(openedIn)
        }
        
        let response: [String: AnyCodable] = [
            "action": .string("notification.card.response"),
            "messageId": .string(card.messageId),
            "payload": .init(payload)
        ]
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8) else { return }
        messenger.broadcast(type: "notification", payload: json)
    }

    private func publishLatestLocked() {
        let latest = order.first.flatMap { cards[$0] }
        let orderedCards = order.compactMap { cards[$0] }
        let cardCount = orderedCards.count
        let previousLatestId = latestCard?.taskId
        let newLatestId = latest?.taskId
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let hasNewCard = newLatestId != nil && newLatestId != previousLatestId
            if hasNewCard {
                self.isExplicitlyHidden = false
            }
            
            self.latestCard = latest
            self.allCards = orderedCards
            if cardCount == 0 {
                self.currentIndex = 0
                self.isManuallyShown = false
                self.isExplicitlyHidden = false
            } else if self.currentIndex >= cardCount {
                self.currentIndex = cardCount - 1
            }
        }
    }
}

extension NotificationCardManager.Card: Identifiable {
    var id: String { taskId }
}

// MARK: - Agent Avatar

/// The agent avatar notification cards show, kept per account so a card has it
/// on its first frame: from memory, or after a relaunch from Kingfisher's disk
/// cache, while `refresh()` fetches the current one from phi-agent behind it.
///
/// Entries are keyed by user ID and only served to that signed-in account;
/// sign-out removes the account's entry (`AccountController.clearCachedAccount`).
@MainActor
enum AgentAvatarStore {
    private static var memory: (userID: String, image: NSImage?)?
    private static var refreshes: [String: Task<NSImage?, Never>] = [:]

    private static var signedInUserID: String? {
        guard ApplicationState.shared.isAuthenticated else { return nil }
        return AccountController.shared.account?.userID
    }

    private static func diskKey(userID: String) -> String {
        "phi-agent-avatar:\(userID)"
    }

    /// The last known avatar of the signed-in account, or nil. Reads the disk
    /// cache at most once per account per launch.
    static func cachedImage() -> NSImage? {
        guard let userID = signedInUserID else { return nil }
        if let memory, memory.userID == userID {
            return memory.image
        }
        let data = try? KingfisherManager.shared.cache.diskStorage.value(forKey: diskKey(userID: userID))
        let image = data.flatMap(NSImage.init(data:))
        memory = (userID, image)
        return image
    }

    /// Fetches the signed-in account's avatar and remembers it. Concurrent
    /// callers share one fetch. Returns nil when the fetch fails or the account
    /// changed meanwhile, leaving the cached avatar in place.
    static func refresh() async -> NSImage? {
        guard let userID = signedInUserID else { return nil }
        if let running = refreshes[userID] {
            return await running.value
        }
        let task = Task<NSImage?, Never> { @MainActor in
            defer { refreshes[userID] = nil }
            guard let loaded = await loadImage(loadData: {
                try await APIClient.shared.getAgentAvatarImageData().data
            }), signedInUserID == userID else { return nil }
            memory = (userID, loaded.image)
            // The callback-queue overload writes in the background rather
            // than holding this fetch until the file is on disk.
            KingfisherManager.shared.cache.storeToDisk(
                loaded.data, forKey: diskKey(userID: userID), callbackQueue: .untouch)
            return loaded.image
        }
        refreshes[userID] = task
        return await task.value
    }

    /// Fetches avatar bytes and decodes them, or nil when the fetch fails or
    /// the bytes are not an image; cards then show their fallback.
    static func loadImage(loadData: () async throws -> Data) async -> (image: NSImage, data: Data)? {
        do {
            let data = try await loadData()
            guard let image = NSImage(data: data), image.isValid else {
                AppLogWarn("[AgentAvatarStore] Agent avatar image could not be decoded; using fallback")
                return nil
            }
            return (image, data)
        } catch is CancellationError {
            return nil
        } catch {
            if let error = error as? URLError {
                if error.code != .cancelled {
                    AppLogWarn("[AgentAvatarStore] Agent avatar request failed (URL error \(error.code.rawValue)); using fallback")
                }
            } else if case APIError.httpError(let status) = error {
                AppLogWarn("[AgentAvatarStore] Agent avatar request failed (HTTP \(status)); using fallback")
            } else {
                AppLogWarn("[AgentAvatarStore] Agent avatar unavailable; using fallback")
            }
            return nil
        }
    }

    /// Drops the account's avatar from memory and disk.
    static func forget(userID: String) {
        if memory?.userID == userID {
            memory = nil
        }
        KingfisherManager.shared.cache.removeImage(forKey: diskKey(userID: userID))
    }
}

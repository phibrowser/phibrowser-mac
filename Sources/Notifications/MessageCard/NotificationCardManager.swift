// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

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
    
    /// Visibility publisher for sidebar presentation.
    var shouldShowInSidebar: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4($latestCard, $isManuallyShown, $activeDisplayMode, $isExplicitlyHidden)
            .map { [weak self] latestCard, isManuallyShown, activeMode, isExplicitlyHidden in
                guard latestCard != nil, activeMode == .sidebar, !isExplicitlyHidden else { return false }
                return self?.isNotificationPopupEnabled == true || isManuallyShown
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// Visibility publisher for legacy overlay presentation.
    var shouldShowInLegacy: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4($latestCard, $isManuallyShown, $activeDisplayMode, $isExplicitlyHidden)
            .map { [weak self] latestCard, isManuallyShown, activeMode, isExplicitlyHidden in
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
    private func setDisplayMode(_ mode: CardDisplayMode) {
        if activeDisplayMode != mode {
            isManuallyShown = false
            isExplicitlyHidden = false
        }
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
        
        let result = enqueueCard(envelope: payloadDict, correlationId: context.requestId)
        messenger.sendResponse(result ?? "", requestId: context.requestId)
    }

    @discardableResult
    func enqueueCard(envelope: [String: AnyCodable], correlationId: String?) -> String? {
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
        let rawButtonTitle = payload["button_title"]?.stringValue
        let buttonTitle = rawButtonTitle?.isEmpty == false ? rawButtonTitle : "Run"
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
                timer: nil
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
            if let existing = cards[taskId] {
                existing.timer?.cancel()
                order.removeAll { $0 == taskId }
            }
            if order.count >= maxQueueSize, let evicted = order.popLast() {
                if let evictedCard = cards.removeValue(forKey: evicted) {
                    evictedCard.timer?.cancel()
                    sendTimeout(card: evictedCard)
                }
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
                timer: nil
            )
            order.insert(taskId, at: 0)
            cards[taskId] = card
            scheduleExpiry(for: taskId)
            return taskId
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

    private func sendDecision(card: Card, decision: Card.Decision) {
        let payload: [String: AnyCodable] = [
            "decision": .string(decision.rawValue),
            "task_id": .string(card.taskId),
            "title": .string(card.title),
            "timestamp": .string("\(Date.now.timeIntervalSince1970)"),
            "task_type": .string(card.taskType ?? "")
        ]
        
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

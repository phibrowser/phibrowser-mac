// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

extension BrowserState {
    @MainActor
    func omniboxSearchAdapterIfAvailable() -> OmniboxNativeSearchAdapter? {
        guard currentOmniboxNativeScope() != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.revokeOmniboxSearchContext(windowId:expectedBindingToken:reason:))) else {
            return nil
        }
        if omniboxNativeSearchAdapter == nil {
            omniboxNativeSearchAdapter = OmniboxNativeSearchAdapter(state: self, revoke: { windowID, token, reason in
                guard let bridge = ChromiumLauncher.sharedInstance().bridge,
                      bridge.responds(to: #selector(PhiChromiumBridgeProtocol.revokeOmniboxSearchContext(windowId:expectedBindingToken:reason:))) else {
                    return false
                }
                return bridge.revokeOmniboxSearchContext(windowId: Int64(windowID), expectedBindingToken: token, reason: reason)
            }, refresh: { windowID, token in
                guard let bridge = ChromiumLauncher.sharedInstance().bridge,
                      bridge.responds(to: #selector(PhiChromiumBridgeProtocol.refreshOmniboxNativeData(windowId:expectedBindingToken:))) else {
                    return false
                }
                return bridge.refreshOmniboxNativeData(windowId: Int64(windowID), expectedBindingToken: token)
            })
        }
        return omniboxNativeSearchAdapter
    }
}

/// One BrowserState owns this adapter. Chromium supplies session identities;
/// renderer input never chooses the account, store, profile, or Space.
@MainActor
final class OmniboxNativeSearchAdapter {
    typealias Binding = OmniboxNativeContextAuthority.Binding
    typealias QueryCompletion = (Result<OmniboxNativeSearchSnapshot, OmniboxNativeQueryError>) -> Void
    typealias Revoke = (Int, String, String) -> Bool
    typealias Refresh = (Int, String) -> Bool

    @MainActor private final class Attempt {
        let request: UInt64
        let ticket: OmniboxQueryTicket
        var completion: QueryCompletion?
        var timeout: Task<Void, Never>?
        var snapshot: OmniboxNativeSearchSnapshot?
        var expiry: Task<Void, Never>?

        init(request: UInt64, completion: @escaping QueryCompletion) {
            self.request = request
            self.completion = completion
            ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 300_000_000)
        }

        func detachCancellation() -> QueryCompletion? {
            ticket.cancel()
            timeout?.cancel()
            expiry?.cancel()
            timeout = nil
            expiry = nil
            snapshot = nil
            let callback = completion
            completion = nil
            return callback
        }

        func cancel() {
            detachCancellation()?(.failure(.cancelled))
        }
    }

    @MainActor private final class Session {
        let reader: OmniboxNativeQueryCoordinator<OmniboxNativeSearchSnapshot>
        var lastRequest: UInt64 = 0
        var attempt: Attempt?
        var actionTicket: OmniboxQueryTicket?
        // Cancellation does not release this physical FIFO occupancy.
        var selectionPending = false

        init(store: LocalStore) { reader = store.makeOmniboxQueryCoordinator() }
        func freeze() -> QueryCompletion? {
            let old = attempt
            attempt = nil
            actionTicket?.cancel()
            actionTicket = nil
            let callback = old?.detachCancellation()
            reader.cancel()
            return callback
        }
        func cancel() {
            freeze()?(.failure(.cancelled))
        }
    }

    private weak var state: BrowserState?
    private weak var observedTarget: Tab?
    private let authority = OmniboxNativeContextAuthority()
    private let revoke: Revoke
    private let refresh: Refresh
    private var refreshTask: Task<Void, Never>?
    private var sessions: [String: Session] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var targetSubscription: AnyCancellable?
    private var transitionDepth = 0
    private var mutationPending = false
    private var mutationGeneration: UInt64 = 0
    private var closed = false

    init(state: BrowserState, revoke: @escaping Revoke, refresh: @escaping Refresh = { _, _ in false }) {
        self.state = state
        self.revoke = revoke
        self.refresh = refresh
        observeTarget(state.focusingTab)
        state.$focusingTab.dropFirst().sink { [weak self] target in
            MainActor.assumeIsolated {
                guard let self, self.observedTarget !== target else { return }
                self.beginContextTransition(reason: "context_changed")
                self.observeTarget(target)
            }
        }.store(in: &subscriptions)
        observeMutation(state.$groupOverviewState.dropFirst().map { _ in () }.eraseToAnyPublisher())
        observeMutation(state.$pendingSplitPreview.dropFirst().map { _ in () }.eraseToAnyPublisher())
        observeMutation(state.$tabsAwaitingSplit.dropFirst().map { _ in () }.eraseToAnyPublisher())
        observeMutation(state.$splits.dropFirst().map { _ in () }.eraseToAnyPublisher())
        observeMutation(state.peekState.$peeksByOpener.dropFirst().map { _ in () }.eraseToAnyPublisher())
        NotificationCenter.default.publisher(for: .omniboxAuthorityWillChange).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transitionDepth += 1
                self.beginContextTransition(reason: "context_changed")
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .omniboxAuthorityDidChange).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transitionDepth = max(0, self.transitionDepth - 1)
                // A later explicit begin resolves the committed scope; no idle renewal.
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: LocalStore.omniboxNativeDataWillChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let store = note.object as? LocalStore,
                          store === self.state?.localStore else { return }
                    self.scheduleNativeRefresh()
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: LocalStore.willCloseNotification).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let store = note.object as? LocalStore,
                      store === self.state?.localStore else { return }
                self.close(reason: "store_closed")
            }
        }.store(in: &subscriptions)
    }

    private func observeMutation(_ publisher: AnyPublisher<Void, Never>) {
        publisher.sink { [weak self] in
            MainActor.assumeIsolated { self?.beginContextTransition(reason: "context_changed") }
        }.store(in: &subscriptions)
    }

    private func observeTarget(_ target: Tab?) {
        observedTarget = target
        targetSubscription = target?.$groupToken.dropFirst().removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.beginContextTransition(reason: "context_changed") }
        }
    }

    func beginContextTransition(reason: String) {
        mutationPending = true
        mutationGeneration &+= 1
        let generation = mutationGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.mutationGeneration == generation else { return }
            self.mutationPending = false
        }
        let token = authority.beginTransition()
        let previous = sessions
        sessions.removeAll()
        // Freeze all owned state before completion callbacks can reenter.
        let callbacks = previous.values.compactMap { $0.freeze() }
        if let state {
            if let token, revoke(state.windowId, token, reason) {
                _ = authority.acknowledgeRevocation(token)
            }
            NotificationCenter.default.post(name: .omniboxNativeContextInvalidated, object: state,
                userInfo: ["reason": reason])
        }
        for callback in callbacks { callback(.failure(.cancelled)) }
    }

    /// Chromium keeps one native snapshot per session; writes are coalesced
    /// into one re-read, which the FIFO orders after them.
    private func scheduleNativeRefresh() {
        guard !closed, !sessions.isEmpty, refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.refreshTask = nil
            guard !self.closed, !self.sessions.isEmpty, let state = self.state,
                  let token = self.authority.binding?.token else { return }
            _ = self.refresh(state.windowId, token)
        }
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        refreshTask?.cancel()
        refreshTask = nil
        beginContextTransition(reason: reason)
        _ = authority.close()
        subscriptions.removeAll()
        targetSubscription = nil
    }

    func beginSession(_ sessionID: String, profileID: String, targetID: Int?) -> Binding? {
        guard !closed, !mutationPending, transitionDepth == 0, !sessionID.isEmpty, sessionID.utf8.count <= 128,
              let state, let scope = state.currentOmniboxNativeScope(),
              scope.profileID == profileID, scope.targetID == targetID else { return nil }
        if let current = authority.binding, current.scope != scope {
            beginContextTransition(reason: "context_changed")
        }
        // Missing/failed revoke ACK intentionally keeps the context frozen.
        guard !mutationPending, let binding = authority.finishBinding(scope) else { return nil }
        if sessions[sessionID] == nil {
            guard sessions.count < 32 else { return nil }
            sessions[sessionID] = Session(store: state.localStore)
        }
        return binding
    }

    func endSession(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)?.cancel()
    }

    /// Advance every input generation, including unsupported/keyword input.
    /// Cancel before querying so a new generation cannot leave an old consumed
    /// but not-yet-submitted entity action alive.
    func advance(sessionID: String, token: String, request: UInt64) -> Bool {
        guard let binding = authority.binding, binding.token == token,
              let session = sessions[sessionID], isCurrent(binding, sessionID: sessionID, session: session),
              request > session.lastRequest, request <= 9_007_199_254_740_991 else { return false }
        session.lastRequest = request
        // The snapshot read is session-wide in Chromium and survives requests.
        session.actionTicket?.cancel()
        session.actionTicket = nil
        return isCurrent(binding, sessionID: sessionID, session: session) && session.lastRequest == request
    }

    private func isCurrent(_ binding: Binding, sessionID: String, session: Session) -> Bool {
        !closed && !mutationPending && transitionDepth == 0 && authority.binding == binding &&
            sessions[sessionID] === session && state?.currentOmniboxNativeScope() == binding.scope
    }

    func query(sessionID: String, token: String, request: UInt64,
               completion: @escaping QueryCompletion) {
        guard let state, let binding = authority.binding, binding.token == token,
              let session = sessions[sessionID], isCurrent(binding, sessionID: sessionID, session: session),
              request >= session.lastRequest,
              request > 0, request <= 9_007_199_254_740_991 else {
            completion(.failure(.unavailable))
            return
        }
        let old = session.attempt
        let attempt = Attempt(request: request, completion: completion)
        session.lastRequest = request
        session.attempt = attempt
        session.actionTicket?.cancel()
        old?.cancel()
        guard isCurrent(binding, sessionID: sessionID, session: session), session.attempt === attempt else {
            attempt.cancel()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = attempt.ticket.deadlineUptimeNanoseconds > now
            ? attempt.ticket.deadlineUptimeNanoseconds - now : 0
        if remaining == 0 {
            attempt.ticket.cancel()
            let callback = attempt.completion
            attempt.completion = nil
            session.reader.cancel()
            callback?(.failure(.expired))
            return
        }
        attempt.timeout = Task { @MainActor [weak self, weak session, weak attempt] in
            guard let deadline = attempt?.ticket.deadlineUptimeNanoseconds else { return }
            let scheduledAt = DispatchTime.now().uptimeNanoseconds
            if deadline > scheduledAt {
                do { try await Task.sleep(nanoseconds: deadline - scheduledAt) } catch { return }
            }
            guard let self, let session, let attempt, session.attempt === attempt,
                  self.isCurrent(binding, sessionID: sessionID, session: session) else { return }
            attempt.ticket.cancel()
            let callback = attempt.completion
            attempt.completion = nil
            session.reader.cancel()
            callback?(.failure(.expired))
        }
        let store = state.localStore
        let requestTicket = attempt.ticket
        session.reader.submit(ticket: attempt.ticket, read: {
            try await store.readOmniboxSnapshot(profileID: binding.scope.profileID,
                spaceID: binding.scope.spaceID, ticket: requestTicket)
        }, completion: { [weak self, weak session, attempt] result in
            guard let self, let session, session.attempt === attempt,
                  self.isCurrent(binding, sessionID: sessionID, session: session),
                  let callback = attempt.completion else { attempt.cancel(); return }
            attempt.completion = nil
            attempt.timeout?.cancel()
            attempt.timeout = nil
            do {
                let snapshot = try result.get()
                guard let state = self.state else { throw OmniboxNativeQueryError.unavailable }
                let decorated = try state.decorateOmniboxSnapshot(snapshot, ticket: attempt.ticket)
                guard self.isCurrent(binding, sessionID: sessionID, session: session) else {
                    throw OmniboxNativeQueryError.cancelled
                }
                attempt.snapshot = decorated
                attempt.expiry = Task { @MainActor [weak attempt] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    attempt?.snapshot = nil
                }
                callback(.success(decorated))
            } catch {
                callback(.failure(error as? OmniboxNativeQueryError ?? .readFailed))
            }
        })
    }

    func stop(sessionID: String, request: UInt64) {
        guard let session = sessions[sessionID], session.lastRequest == request else { return }
        let old = session.attempt
        session.attempt = nil
        session.reader.cancel()
        old?.cancel()
        // A consumed action has its own ticket; provider Stop does not cancel it.
    }

    func recordOrdinaryChoice(sessionID: String, token: String, request: UInt64, learningText: String) {
        guard let state, let binding = authority.binding, binding.token == token,
              let session = sessions[sessionID], session.lastRequest == request,
              isCurrent(binding, sessionID: sessionID, session: session) else { return }
        state.recordOmniboxOrdinaryChoice(learningText: learningText)
    }

    /// Returns the bridge status: "accepted", "rejected" for a command that is
    /// unknown or unavailable here, or "stale".
    func executeCommand(sessionID: String, token: String, request: UInt64, commandID: String) -> String {
        guard let state, let binding = authority.binding, binding.token == token,
              let session = sessions[sessionID], session.lastRequest == request,
              !session.selectionPending, isCurrent(binding, sessionID: sessionID, session: session) else {
            return "stale"
        }
        return state.scheduleOmniboxCommand(commandID) ? "accepted" : "rejected"
    }

    func execute(sessionID: String, token: String, request: UInt64,
                 entity: OmniboxNativeEntity, expectedEpoch: String,
                 expectedPinScope: String, learningText: String,
                 duplicateSplit: Bool) async -> OmniboxNativeDispatchEffect? {
        guard let state, let binding = authority.binding, binding.token == token,
              let session = sessions[sessionID] else {
            AppLogDebug("[OmniboxNative] execute rejected: no binding or session")
            return nil
        }
        guard session.lastRequest == request, !session.selectionPending,
              isCurrent(binding, sessionID: sessionID, session: session) else {
            AppLogDebug("[OmniboxNative] execute rejected: lastRequest=\(session.lastRequest) " +
                "request=\(request) pending=\(session.selectionPending) " +
                "current=\(isCurrent(binding, sessionID: sessionID, session: session))")
            return nil
        }
        // This action is independent of the expired 300ms read ticket. Retain
        // its physical occupancy until the existing store FIFO has returned.
        let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
        session.selectionPending = true
        session.actionTicket = ticket
        session.attempt?.snapshot = nil
        defer {
            session.selectionPending = false
            if session.actionTicket === ticket { session.actionTicket = nil }
        }
        do {
            return try await state.localStore.performOmniboxEntitySelection(entity,
                expectedEpoch: expectedEpoch, expectedPinScope: expectedPinScope,
                profileID: binding.scope.profileID, spaceID: binding.scope.spaceID, ticket: ticket,
                dispatch: { [weak self, weak state, weak session] entity -> OmniboxNativeDispatchEffect? in
                    guard let self, let state, let session else { return nil }
                    let effect = state.dispatchOmniboxEntity(entity, binding: binding, ticket: ticket,
                                                             duplicatesSplit: duplicateSplit) {
                        self.isCurrent(binding, sessionID: sessionID, session: session)
                    }
                    // A copy of a split is not a visit to the pin or bookmark.
                    if effect != nil, !duplicateSplit { state.recordOmniboxSelection(entity, learningText: learningText) }
                    return effect
                })
        } catch {
            AppLogDebug("[OmniboxNative] execute failed: \(error)")
            return nil
        }
    }
}

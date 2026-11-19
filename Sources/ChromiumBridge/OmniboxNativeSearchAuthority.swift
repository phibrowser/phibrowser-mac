// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum OmniboxNativeQueryError: Error, Sendable {
    case cancelled
    case expired
    case busy
    case unavailable
    case readFailed
}

/// Value projection of the two sides of one entity's runtime binding. A stale
/// cache is rejected instead of repairing it by opening an unrelated URL.
struct OmniboxNativeRuntimeBinding {
    enum Action: Equatable {
        case focus(tabID: Int)
        case create(bound: Bool)
    }

    let tabID: Int
    let wrapper: ObjectIdentifier?
    let isOpen: Bool
    let unsupported: Bool

    static func resolve(cache: [Self], live: [Self], isPin: Bool,
                        traditional: Bool) -> Action? {
        guard cache.count == 1, let cache = cache.first, !cache.unsupported else { return nil }
        if live.isEmpty {
            guard !cache.isOpen, cache.tabID == -1, cache.wrapper == nil else { return nil }
            return .create(bound: isPin || !traditional)
        }
        guard isPin || !traditional, live.count == 1, let live = live.first,
              !live.unsupported, live.isOpen, cache.isOpen,
              live.tabID >= 0, live.tabID == cache.tabID,
              let wrapper = live.wrapper, wrapper == cache.wrapper else { return nil }
        return .focus(tabID: live.tabID)
    }
}

/// Window-owned authority only. Eligibility (account/access/isolation/visibility)
/// is resolved by the adapter before calling finishBinding, including before any
/// lazy account store access. Chromium must acknowledge the old token's revoke.
@MainActor
final class OmniboxNativeContextAuthority {
    struct Scope: Equatable, Sendable {
        enum Access: Sendable { case guest, signedIn }
        let windowID: Int
        let accountID: String
        let storeID: UUID
        let profileID: String
        let spaceID: String
        let access: Access
        var targetID: Int? = nil
        var stateIdentity: ObjectIdentifier? = nil
    }

    struct Binding: Equatable, Sendable {
        let token: String
        let scope: Scope
    }

    private(set) var binding: Binding?
    private(set) var pendingRevocationToken: String?
    private var closed = false

    @discardableResult
    func beginTransition() -> String? {
        if let binding {
            pendingRevocationToken = binding.token
            self.binding = nil
        }
        return pendingRevocationToken
    }

    @discardableResult
    func acknowledgeRevocation(_ token: String) -> Bool {
        guard pendingRevocationToken == token else { return false }
        pendingRevocationToken = nil
        return true
    }

    func finishBinding(_ scope: Scope) -> Binding? {
        guard !closed, pendingRevocationToken == nil,
              !scope.accountID.isEmpty, !scope.profileID.isEmpty, !scope.spaceID.isEmpty else { return nil }
        if let binding {
            guard binding.scope == scope else {
                beginTransition()
                return nil
            }
            return binding
        }
        let binding = Binding(token: UUID().uuidString, scope: scope)
        self.binding = binding
        return binding
    }

    @discardableResult
    func close() -> String? {
        closed = true
        return beginTransition()
    }
}

/// Cancellation can cross the bridge/main-actor/writer boundaries. The deadline
/// belongs to the original request, including time spent waiting in the FIFO.
final class OmniboxQueryTicket: @unchecked Sendable {
    let deadlineUptimeNanoseconds: UInt64
    private let lock = NSLock()
    private var cancelled = false

    init(deadlineUptimeNanoseconds: UInt64) {
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func isValid(atUptimeNanoseconds now: UInt64) -> Bool {
        failure(atUptimeNanoseconds: now) == nil
    }

    func failure(atUptimeNanoseconds now: UInt64) -> OmniboxNativeQueryError? {
        lock.withLock {
            if cancelled { return .cancelled }
            return now < deadlineUptimeNanoseconds ? nil : .expired
        }
    }
}

/// Session-local coalescing, with admission owned by the actual LocalStore.
/// `enqueue` must append to that store's existing FIFO without starting a Task.
@MainActor
final class OmniboxNativeQueryCoordinator<Value: Sendable> {
    typealias Completion = @MainActor (Result<Value, OmniboxNativeQueryError>) -> Void
    typealias Job = @Sendable () async -> Void

    private struct Submission {
        let identifier = UUID()
        let ticket: OmniboxQueryTicket
        let read: @Sendable () async throws -> Value
        var completion: Completion?
    }

    private let admission: OmniboxReadAdmission
    private let now: @Sendable () -> UInt64
    private let enqueue: (@escaping Job) -> Bool
    private var inFlight: Submission?
    private var latest: Submission?

    init(admission: OmniboxReadAdmission,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         enqueue: @escaping (@escaping Job) -> Bool) {
        self.admission = admission
        self.now = now
        self.enqueue = enqueue
    }

    func submit(ticket: OmniboxQueryTicket,
                read: @escaping @Sendable () async throws -> Value,
                completion: @escaping Completion) {
        guard !admission.isClosed else {
            cancel()
            completion(.failure(.unavailable))
            return
        }
        let submission = Submission(ticket: ticket, read: read, completion: completion)
        if inFlight != nil {
            let oldCurrent = inFlight?.completion
            inFlight?.completion = nil
            inFlight?.ticket.cancel()
            let oldLatest = latest
            latest = submission
            oldLatest?.ticket.cancel()
            oldCurrent?(.failure(.cancelled))
            oldLatest?.completion?(.failure(.cancelled))
            return
        }
        launch(submission)
    }

    func cancel() {
        let currentCompletion = inFlight?.completion
        let oldLatest = latest
        inFlight?.completion = nil
        inFlight?.ticket.cancel()
        latest = nil
        oldLatest?.ticket.cancel()
        currentCompletion?(.failure(.cancelled))
        oldLatest?.completion?(.failure(.cancelled))
    }

    private func launch(_ submission: Submission) {
        if let error = submission.ticket.failure(atUptimeNanoseconds: now()) {
            submission.completion?(.failure(error))
            return
        }
        guard let lease = admission.acquire() else {
            submission.completion?(.failure(admission.isClosed ? .unavailable : .busy))
            return
        }
        inFlight = submission
        let clock = now
        let ticket = submission.ticket
        let read = submission.read
        let identifier = submission.identifier
        let storeAdmission = admission
        let accepted = enqueue { [weak self] in
            let outcome: Result<Value, OmniboxNativeQueryError>
            if storeAdmission.isClosed {
                outcome = .failure(.unavailable)
            } else if let error = ticket.failure(atUptimeNanoseconds: clock()) {
                outcome = .failure(error)
            } else {
                do {
                    let value = try await read()
                    if let error = ticket.failure(atUptimeNanoseconds: clock()) {
                        outcome = .failure(error)
                    } else {
                        outcome = .success(value)
                    }
                } catch {
                    outcome = .failure(.readFailed)
                }
            }
            // Keep admission until the latest slot is detached on MainActor.
            // The store FIFO itself can already advance to its next job.
            Task { @MainActor [weak self] in
                guard let self else {
                    lease.finish()
                    return
                }
                self.physicalJobDidExit(identifier: identifier, outcome: outcome, lease: lease)
            }
        }
        if !accepted {
            inFlight = nil
            lease.finish()
            submission.completion?(.failure(.unavailable))
        }
    }

    private func physicalJobDidExit(identifier: UUID,
                                   outcome: Result<Value, OmniboxNativeQueryError>,
                                   lease: OmniboxReadAdmission.Lease) {
        guard inFlight?.identifier == identifier else {
            lease.finish()
            return
        }
        let completion = inFlight?.completion
        let deliveryError = admission.isClosed ? OmniboxNativeQueryError.unavailable
            : inFlight?.ticket.failure(atUptimeNanoseconds: now())
        let next = latest
        inFlight = nil
        latest = nil
        lease.finish()
        // Reserve/enqueue the latest before invoking a potentially reentrant
        // consumer, but only now, behind writes submitted since the old job.
        if let next { launch(next) }
        completion?(deliveryError.map { .failure($0) } ?? outcome)
    }

    deinit {
        inFlight?.ticket.cancel()
        latest?.ticket.cancel()
    }
}

/// Owned by one LocalStore instance, rather than one Profile or UI session.
final class OmniboxReadAdmission: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var admitted = Set<UUID>()
    private var closed = false

    init(limit: Int = 32) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire() -> Lease? {
        lock.withLock {
            guard !closed, admitted.count < limit else { return nil }
            let identifier = UUID()
            admitted.insert(identifier)
            return Lease(owner: self, identifier: identifier)
        }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func close() {
        lock.withLock { closed = true }
    }

    private func release(_ identifier: UUID) {
        _ = lock.withLock { admitted.remove(identifier) }
    }

    /// The queued/running FIFO closure retains this lease until physical exit.
    /// A query ticket's cancellation must never finish the lease early.
    final class Lease: @unchecked Sendable {
        private let owner: OmniboxReadAdmission
        private let identifier: UUID

        fileprivate init(owner: OmniboxReadAdmission, identifier: UUID) {
            self.owner = owner
            self.identifier = identifier
        }

        func finish() {
            owner.release(identifier)
        }

        deinit {
            finish()
        }
    }
}

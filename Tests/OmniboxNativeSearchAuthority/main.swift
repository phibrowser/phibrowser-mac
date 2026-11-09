// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@main
enum OmniboxNativeSearchAuthorityTests {
    @MainActor
    static func main() async {
        cancellationDoesNotReleasePhysicalAdmission()
        releaseIsIdempotent()
        deadlineIsNotRenewedByQueueing()
        separateStoresDoNotShareCapacity()
        await latestRequestQueuesAfterInterveningWork()
        await expiredLatestDoesNotReenterTheFIFO()
        await closedStoreSkipsQueuedReads()
        admissionIsHeldUntilLatestIsDetached()
        contextBindingRequiresRevocationAcknowledgement()
        unchangedAuthorityDoesNotRotateBinding()
        nativeRuntimeBindingsFailClosed()
        print("OmniboxNativeSearchAuthority: 11 tests passed")
    }

    private static func nativeRuntimeBindingsFailClosed() {
        let wrapper = NSObject()
        let wrongWrapper = NSObject()
        let open = OmniboxNativeRuntimeBinding(tabID: 7, wrapper: ObjectIdentifier(wrapper),
                                             isOpen: true, unsupported: false)
        let closed = OmniboxNativeRuntimeBinding(tabID: -1, wrapper: nil,
                                               isOpen: false, unsupported: false)
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [open], live: [open],
            isPin: true, traditional: false) == .focus(tabID: 7))
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [closed], live: [],
            isPin: true, traditional: true) == .create(bound: true))
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [closed], live: [],
            isPin: false, traditional: true) == .create(bound: false))
        let mismatched = OmniboxNativeRuntimeBinding(tabID: 7, wrapper: ObjectIdentifier(wrongWrapper),
                                                   isOpen: true, unsupported: false)
        for live in [[], [mismatched], [open, open]] {
            precondition(OmniboxNativeRuntimeBinding.resolve(cache: [open], live: live,
                isPin: true, traditional: false) == nil)
        }
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [closed], live: [open],
            isPin: true, traditional: false) == nil)
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [open], live: [open],
            isPin: false, traditional: true) == nil)
        let split = OmniboxNativeRuntimeBinding(tabID: -1, wrapper: nil,
                                              isOpen: false, unsupported: true)
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [split], live: [],
            isPin: true, traditional: false) == nil)
        precondition(OmniboxNativeRuntimeBinding.resolve(cache: [closed, closed], live: [],
            isPin: true, traditional: false) == nil)
    }

    @MainActor
    private static func contextBindingRequiresRevocationAcknowledgement() {
        let context = OmniboxNativeContextAuthority()
        let firstScope = OmniboxNativeContextAuthority.Scope(windowID: 1, accountID: "A",
            storeID: UUID(), profileID: "P", spaceID: "S", access: .signedIn)
        guard let first = context.finishBinding(firstScope) else { fatalError("Initial ready binding") }
        let revoked = context.beginTransition()
        precondition(revoked == first.token && context.binding == nil)
        precondition(context.finishBinding(firstScope) == nil,
                     "No replacement may be published before old Chromium context is revoked")
        precondition(!context.acknowledgeRevocation("unrelated"))
        precondition(context.acknowledgeRevocation(first.token))
        guard let second = context.finishBinding(firstScope) else { fatalError("Rebound ready context") }
        precondition(first.token != second.token)
        precondition(!context.acknowledgeRevocation(first.token))
        precondition(context.binding == second, "A late old acknowledgement must not affect new authority")
        context.close()
        precondition(context.binding == nil && context.finishBinding(firstScope) == nil)
    }

    @MainActor
    private static func unchangedAuthorityDoesNotRotateBinding() {
        let context = OmniboxNativeContextAuthority()
        let scope = OmniboxNativeContextAuthority.Scope(windowID: 2, accountID: "A",
            storeID: UUID(), profileID: "P", spaceID: "S", access: .guest)
        guard let original = context.finishBinding(scope) else { fatalError("Initial binding") }
        precondition(context.finishBinding(scope) == original)
        let reopened = OmniboxNativeContextAuthority.Scope(windowID: 2, accountID: "A",
            storeID: UUID(), profileID: "P", spaceID: "S", access: .guest)
        precondition(context.finishBinding(reopened) == nil,
                     "Changing store identity must require explicit begin/revoke/finish")
        precondition(context.binding == nil && context.pendingRevocationToken == original.token,
                     "An unexpected scope change must fail closed immediately")
    }

    private static func cancellationDoesNotReleasePhysicalAdmission() {
        let admission = OmniboxReadAdmission(limit: 2)
        let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: 300)
        guard let first = admission.acquire(), let second = admission.acquire() else {
            fatalError("Initial physical jobs must be admitted")
        }
        ticket.cancel()
        precondition(!ticket.isValid(atUptimeNanoseconds: 100))
        precondition(admission.acquire() == nil,
                     "Cancelling an accepted query must not release a queued/running job")
        first.finish()
        guard let replacement = admission.acquire() else {
            fatalError("A physically exited job must release exactly one slot")
        }
        precondition(admission.acquire() == nil)
        second.finish()
        replacement.finish()
    }

    private static func releaseIsIdempotent() {
        let admission = OmniboxReadAdmission(limit: 1)
        guard let first = admission.acquire() else { fatalError("Missing first lease") }
        first.finish()
        first.finish()
        guard let second = admission.acquire() else { fatalError("Missing replacement lease") }
        first.finish()
        precondition(admission.acquire() == nil,
                     "A late duplicate exit must not release another job's slot")
        second.finish()
    }

    private static func deadlineIsNotRenewedByQueueing() {
        let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: 300)
        precondition(ticket.isValid(atUptimeNanoseconds: 0))
        precondition(ticket.isValid(atUptimeNanoseconds: 299))
        precondition(!ticket.isValid(atUptimeNanoseconds: 300))
        precondition(!ticket.isValid(atUptimeNanoseconds: 500),
                     "A job starting late must retain its original query deadline")
        ticket.cancel()
        precondition(!ticket.isValid(atUptimeNanoseconds: 1))
    }

    private static func separateStoresDoNotShareCapacity() {
        let firstStore = OmniboxReadAdmission(limit: 1)
        let secondStore = OmniboxReadAdmission(limit: 1)
        guard let first = firstStore.acquire(), let second = secondStore.acquire() else {
            fatalError("Each LocalStore instance must own its admission budget")
        }
        precondition(firstStore.acquire() == nil)
        precondition(secondStore.acquire() == nil)
        first.finish()
        second.finish()
    }

    @MainActor
    private static func latestRequestQueuesAfterInterveningWork() async {
        var jobs: [@Sendable () async -> Void] = []
        var reads: [Int] = []
        var completed: [Int] = []
        let latestEnqueued = TestSignal()
        let latestCompleted = TestSignal()
        let admission = OmniboxReadAdmission(limit: 1)
        let coordinator = OmniboxNativeQueryCoordinator<Int>(
            admission: admission,
            now: { 100 },
            enqueue: {
                jobs.append($0)
                if jobs.count == 2 { latestEnqueued.signal() }
                return true
            }
        )
        for value in 1...100 {
            coordinator.submit(
                ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: 300),
                read: {
                    await MainActor.run { reads.append(value) }
                    return value
                },
                completion: {
                    if case .success(let result) = $0 {
                        completed.append(result)
                        latestCompleted.signal()
                    }
                }
            )
        }
        precondition(jobs.count == 1, "Typing must not enqueue one FIFO job per key")
        jobs.append { await MainActor.run { reads.append(-1) } }
        await jobs.removeFirst()()
        await latestEnqueued.wait()
        precondition(jobs.count == 2, "Only the newest request may enqueue after physical exit")
        precondition(reads.isEmpty, "The cancelled queued request must not read the store")
        await jobs.removeFirst()()
        await jobs.removeFirst()()
        await latestCompleted.wait()
        precondition(reads == [-1, 100], "Latest must queue after intervening writes, not replace the old payload")
        precondition(completed == [100])
        precondition(admission.acquire() != nil)
    }

    @MainActor
    private static func expiredLatestDoesNotReenterTheFIFO() async {
        var jobs: [@Sendable () async -> Void] = []
        let done = TestSignal()
        let coordinator = OmniboxNativeQueryCoordinator<Int>(
            admission: OmniboxReadAdmission(limit: 1), now: { 300 },
            enqueue: { jobs.append($0); return true }
        )
        coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: 400),
                           read: { fatalError("Superseded queued job must not read") },
                           completion: { _ in })
        coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: 300),
                           read: { fatalError("Expired latest must not read") },
                           completion: {
            guard case .failure(.expired) = $0 else { fatalError("Deadline must not renew") }
            done.signal()
        })
        await jobs.removeFirst()()
        await done.wait()
        precondition(jobs.isEmpty)
    }

    @MainActor
    private static func closedStoreSkipsQueuedReads() async {
        var jobs: [@Sendable () async -> Void] = []
        let done = TestSignal()
        let admission = OmniboxReadAdmission(limit: 1)
        let coordinator = OmniboxNativeQueryCoordinator<Int>(
            admission: admission, now: { 100 },
            enqueue: { jobs.append($0); return true }
        )
        coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: 300),
                           read: { fatalError("A closed store must not be queried") },
                           completion: {
            guard case .failure(.unavailable) = $0 else { fatalError("Closed store must reject") }
            done.signal()
        })
        admission.close()
        precondition(admission.acquire() == nil)
        await jobs.removeFirst()()
        await done.wait()
        precondition(jobs.isEmpty)
    }

    @MainActor
    private static func admissionIsHeldUntilLatestIsDetached() {
        var jobs: [@Sendable () async -> Void] = []
        let admission = OmniboxReadAdmission(limit: 1)
        let coordinator = OmniboxNativeQueryCoordinator<Int>(
            admission: admission, now: { 100 },
            enqueue: { jobs.append($0); return true }
        )
        for _ in 0..<2 {
            coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: 300),
                               read: { 1 }, completion: { _ in })
        }
        let job = jobs.removeFirst()
        let gate = DispatchSemaphore(value: 0)
        let earlyAdmission = LockedFlag()
        Task.detached {
            await job()
            if let lease = admission.acquire() {
                earlyAdmission.set()
                lease.finish()
            }
            gate.signal()
        }
        // Deliberately hold the CLI's MainActor so exit delivery cannot clear
        // the latest slot before the competing admission probe runs.
        gate.wait()
        precondition(!earlyAdmission.value,
                     "A coordinator retaining latest must still own its physical lease")
        coordinator.cancel()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

@MainActor
private final class TestSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

import Foundation

enum SyncContextPhase: String, Codable, Sendable {
    case checking, initialSync, syncing, upToDate, offline, needsAttention
}

struct SyncContextSnapshot: Equatable, Sendable {
    let id: String
    let phase: SyncContextPhase
    let lastSuccess: Date?
    let revision: UInt64
}

enum SyncSummaryPhase: String { case notStarted, checking, initialSync, syncing, upToDate, offline, needsAttention }

struct SyncStatusSummary: Equatable {
    let phase: SyncSummaryPhase
    let lastSuccess: Date?

    static func reduce(paired: Bool, requiredIDs: Set<String>, snapshots: [SyncContextSnapshot]) -> Self {
        guard paired else { return Self(phase: .notStarted, lastSuccess: nil) }
        var newest: [String: SyncContextSnapshot] = [:]
        for snapshot in snapshots where requiredIDs.contains(snapshot.id) {
            if let old = newest[snapshot.id], old.revision > snapshot.revision { continue }
            newest[snapshot.id] = snapshot
        }
        let phases = newest.values.map(\.phase)
        let times = newest.values.compactMap(\.lastSuccess)
        let last = !requiredIDs.isEmpty && times.count == requiredIDs.count ? times.min() : nil
        if phases.contains(.needsAttention) { return Self(phase: .needsAttention, lastSuccess: last) }
        if requiredIDs.isEmpty || newest.count != requiredIDs.count || phases.contains(.checking) {
            return Self(phase: .checking, lastSuccess: last)
        }
        for phase in [SyncContextPhase.offline, .initialSync, .syncing] where phases.contains(phase) {
            return Self(phase: SyncSummaryPhase(rawValue: phase.rawValue)!, lastSuccess: last)
        }
        // Even a supplied success phase without a timestamp is incomplete evidence.
        return Self(phase: last == nil ? .checking : .upToDate, lastSuccess: last)
    }
}

struct SyncRoundCompletion: Equatable, Sendable {
    let pullDrained: Bool
    let outboundAccepted: Bool
    let persistenceSucceeded: Bool
    let pendingInbound: Bool
    let pendingOutbound: Bool
    let followupQueued: Bool
    var succeeded: Bool {
        pullDrained && outboundAccepted && persistenceSucceeded
            && !pendingInbound && !pendingOutbound && !followupQueued
    }
}

/// Engine-owned metadata. Local notifications can invalidate success before debounced
/// work reaches the actor; an older round cannot clear that newer pending edit.
final class SyncStatusState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SyncContextSnapshot(id: "phi", phase: .checking, lastSuccess: nil, revision: 0)

    var snapshot: SyncContextSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    func update(_ phase: SyncContextPhase, completing revision: UInt64? = nil) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let finalPhase: SyncContextPhase = phase == .upToDate && revision != nil && revision != value.revision
            ? .syncing : phase
        value = SyncContextSnapshot(id: value.id, phase: finalPhase,
            lastSuccess: finalPhase == .upToDate ? Date() : value.lastSuccess,
            revision: value.revision &+ 1)
        return value.revision
    }
}

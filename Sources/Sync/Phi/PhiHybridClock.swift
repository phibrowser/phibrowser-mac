import Foundation

/// The account's hybrid logical clock for LWW stamps (C2 / design R2.1, amended by AM-1).
///
/// `stamp() = max(wallClockMs, maxSeen + 1)`, where `maxSeen` is the largest LWW stamp this
/// device has ever issued or landed. Plain wall-clock LWW lets the device with the fastest
/// clock win every field; the hybrid clock keeps a causally later edit strictly above the
/// value it overwrote while staying readable as a wall-clock time on a healthy account.
///
/// It is a separate value type, and that is the whole reason it exists: the formula has to be
/// the SAME code in `PhiSyncEngine` and in the hostless convergence harness
/// (`Tests/SyncConvergence`), which cannot build the engine. Keeping it pure and
/// Foundation-only lets the harness symlink this file and stamp its simulated replicas through
/// the production clock instead of a copy that would drift.
///
/// Stamp 0 is untouched by any of this (R2.3): 0 means "derived, must never beat a real
/// action", `stamp` can never produce it because `maxSeen >= 0` makes every result at least 1,
/// and `observe(0)` is a no-op because `max` is.
///
/// Inbound stamps are never rewritten and `maxSeen` is never clamped (R2.4). A clamp would
/// change the merge input, and two devices with different wall clocks would clamp differently,
/// so `SyncableSettings.lwwWinner` would pick different winners on different devices — that is
/// divergence, not a repair.
struct PhiHybridClock {
    /// Largest LWW stamp issued or landed. Only `PhiSettingValue.updated_at_ms` values are
    /// folded in: never `created_at_ms` (a creation instant merged with `min()`, so a bogus
    /// future one must not drag the account's logical time), and never `deletedAtMs` /
    /// `purgedAtMs` / `refusedAtMs`, which are wall-clock quantities compared against wall
    /// clock.
    private(set) var maxSeen: Int64

    init(maxSeen: Int64 = 0) { self.maxSeen = maxSeen }

    /// A new stamp for an engine-authored LWW value, and the advance of logical time that goes
    /// with it.
    mutating func stamp(wallMs: Int64) -> Int64 {
        let issued = max(wallMs, Self.bumped(maxSeen))
        maxSeen = max(maxSeen, issued)
        return issued
    }

    /// Fold a landed stamp into logical time.
    mutating func observe(_ stampMs: Int64) {
        maxSeen = max(maxSeen, stampMs)
    }

    /// AM-1: an edit-time stamp must still be a logical stamp. Taking the row's wall-clock edit
    /// column alone bypasses the clock — a device running behind edits a field it has already
    /// merged from a peer, its edit column is smaller than the stamp of the value it replaced,
    /// and the causally later edit loses. `overwrittenStampMs` is the stamp of the value this
    /// device demonstrably overwrote: the baseline's stamp for that field or merge unit.
    static func editStamp(editWallMs: Int64, overwrittenStampMs: Int64) -> Int64 {
        max(editWallMs, bumped(overwrittenStampMs))
    }

    /// The no-baseline variant (a create, or a republish after a yield): nothing was
    /// demonstrably overwritten, so the account's logical time is the floor.
    func editStamp(editWallMs: Int64) -> Int64 {
        Self.editStamp(editWallMs: editWallMs, overwrittenStampMs: maxSeen)
    }

    /// `+ 1`, saturating. `Int64.max` is a legal stamp on the wire — a peer or a broken clock
    /// can put one there, and the convergence harness generates them deliberately — so the
    /// increment must not trap.
    private static func bumped(_ stamp: Int64) -> Int64 {
        stamp == Int64.max ? Int64.max : stamp + 1
    }

    // MARK: - AM-2: correcting a broken clock at the SOURCE

    /// How far this device's wall clock may be off before its own stamps are corrected.
    ///
    /// R2.4's no-clamp rule stands: an inbound stamp is never rewritten and `maxSeen` is never
    /// clamped, because two devices with different clocks would clamp differently and
    /// `SyncableSettings.lwwWinner` would then pick different winners on different devices. A
    /// SOURCE-side correction is a different thing entirely — it changes only what this device
    /// stamps NEXT, so every device still merges the same inputs — and it is what keeps a Mac
    /// whose clock is set to 2031 from dragging the whole account's logical time with it.
    ///
    /// Five minutes is deliberately far above ordinary skew. Below it a correction would buy
    /// nothing (LWW does not promise true-time ordering of concurrent writes at that resolution)
    /// and would cost something real: the estimate is re-measured on every response, so a small
    /// correction would jitter this device's stamps round to round for no gain.
    static let wallClockCorrectionThresholdMs: Int64 = 5 * 60 * 1000

    /// The correction to apply to this device's wall clock, from one server response.
    ///
    /// `serverMs` is the `Date` header of a successful round and `localMs` this device's wall
    /// clock when that response landed. No RTT compensation: the quantity that matters here is
    /// measured in minutes, and half a round trip is milliseconds.
    ///
    /// Returns 0 below the threshold, so the stored value is the correction itself rather than a
    /// raw measurement a second reader would have to re-apply the threshold to.
    static func wallClockCorrection(serverMs: Int64, localMs: Int64) -> Int64 {
        let (offset, overflow) = serverMs.subtractingReportingOverflow(localMs)
        guard !overflow else { return serverMs > 0 ? Int64.max : Int64.min }
        // Not `abs`: `abs(Int64.min)` traps, and a nonsense header must not crash the engine.
        guard offset > wallClockCorrectionThresholdMs
            || offset < -wallClockCorrectionThresholdMs else { return 0 }
        return offset
    }

    /// A wall-clock instant seen through AM-2's correction, saturating like `bumped`.
    ///
    /// Every quantity that becomes an LWW STAMP passes through this: `stamp(wallMs:)`'s argument
    /// and, at the other end, the row edit columns `OwnedItemKind.stamp` reads. Wall-clock
    /// quantities — retention, `deletedAtMs`, `purgedAtMs`, `refusedAtMs`, round deadlines — do
    /// NOT, because they are compared against this device's own wall clock and correcting one
    /// side of that comparison is what would actually break them.
    static func corrected(wallMs: Int64, offsetMs: Int64) -> Int64 {
        let (sum, overflow) = wallMs.addingReportingOverflow(offsetMs)
        guard !overflow else { return offsetMs > 0 ? Int64.max : Int64.min }
        return sum
    }
}

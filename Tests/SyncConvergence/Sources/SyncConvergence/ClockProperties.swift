// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// Properties of the PRODUCTION hybrid logical clock (C2 / design R2.1, AM-1).
// `PhiSyncCore/PhiHybridClock.swift` is a symlink to
// `Sources/Sync/Phi/PhiHybridClock.swift`, so these run against the same code
// the engine and the Layer 2 replicas use -- which is the reason the formula
// lives in a value type of its own rather than inside `PhiSyncEngine`.

func runClockProperties(iterations: Int, generators: inout Generators, report: Report) {
    let frozenWall: Int64 = 1_700_000_000_000

    // 1. Strictly increasing with the wall clock FROZEN. This is the whole point
    //    of the +1: plain wall-clock LWW hands out the same stamp twice in the
    //    same millisecond and the byte tie-break decides, not the edit order.
    do {
        var clock = PhiHybridClock()
        var previous = Int64.min
        var strictly = true
        for _ in 0..<max(iterations, 64) {
            let stamp = clock.stamp(wallMs: frozenWall)
            if stamp <= previous { strictly = false }
            previous = stamp
        }
        report.check("clock.strictly-increasing-under-a-frozen-wall-clock", strictly,
                     "last stamp \(previous) did not exceed its predecessor")
        report.markPassed("clock.strictly-increasing-under-a-frozen-wall-clock")
    }

    // 2. The wall clock jumps BACKWARDS (an hour of DST, an NTP correction).
    //    Logical time does not follow it.
    do {
        var clock = PhiHybridClock()
        let before = clock.stamp(wallMs: frozenWall)
        var previous = before
        var strictly = true
        for step in 1...64 {
            let stamp = clock.stamp(wallMs: frozenWall - 3_600_000 + Int64(step))
            if stamp <= previous { strictly = false }
            previous = stamp
        }
        report.check("clock.survives-a-wall-clock-jump-backwards", strictly,
                     "stamps stopped increasing after the jump: \(before) -> \(previous)")
        report.markPassed("clock.survives-a-wall-clock-jump-backwards")
    }

    // 3. `observe(0)` is a no-op. Stamp 0 means "derived, never beat a real
    //    action" (R2.3), and it must never become the account's logical time --
    //    which `max` gives for free, so this pins the property, not the code.
    do {
        var clock = PhiHybridClock()
        _ = clock.stamp(wallMs: frozenWall)
        let before = clock.maxSeen
        clock.observe(0)
        clock.observe(-1)
        report.check("clock.observing-stamp-0-is-a-no-op", clock.maxSeen == before,
                     "maxSeen moved \(before) -> \(clock.maxSeen)")
        report.markPassed("clock.observing-stamp-0-is-a-no-op")
    }

    // 4. `stamp` never PRODUCES 0 either, for any wall clock the generators can
    //    reach -- including negative ones.
    do {
        var clock = PhiHybridClock()
        var produced: Int64 = 1
        var everZero = false
        for _ in 0..<max(iterations, 64) {
            produced = clock.stamp(wallMs: generators.rng.bool()
                                       ? -Int64(generators.rng.int(0...1_000_000))
                                       : frozenWall)
            if produced == 0 { everZero = true }
        }
        report.check("clock.never-produces-stamp-0", !everZero, "stamp() returned 0")
        report.markPassed("clock.never-produces-stamp-0")
    }

    // 5. A peer one year in the future raises logical time, and the next local
    //    stamp exceeds it. No clamp anywhere (R2.4): the inbound value is not
    //    rewritten, only what this device stamps NEXT moves.
    do {
        var clock = PhiHybridClock()
        _ = clock.stamp(wallMs: frozenWall)
        let inflated = frozenWall + 365 * 24 * 3_600_000
        clock.observe(inflated)
        let next = clock.stamp(wallMs: frozenWall)
        report.check("clock.a-future-peer-stamp-is-exceeded-by-the-next-local-stamp",
                     clock.maxSeen >= inflated && next > inflated,
                     "observed \(inflated), next local stamp \(next)")
        report.markPassed("clock.a-future-peer-stamp-is-exceeded-by-the-next-local-stamp")
    }

    // 6. Int64.max does not trap. It is a legal stamp on the wire, Layer 1's
    //    generators emit it, and `+ 1` on it would be a remotely triggerable
    //    crash.
    do {
        var clock = PhiHybridClock(maxSeen: Int64.max)
        let stamp = clock.stamp(wallMs: frozenWall)
        let edit = PhiHybridClock.editStamp(editWallMs: frozenWall,
                                            overwrittenStampMs: Int64.max)
        let noBaseline = clock.editStamp(editWallMs: frozenWall)
        report.check("clock.saturates-at-int64-max",
                     stamp == Int64.max && edit == Int64.max && noBaseline == Int64.max,
                     "stamp=\(stamp) edit=\(edit) noBaseline=\(noBaseline)")
        report.markPassed("clock.saturates-at-int64-max")
    }

    // 7. AM-1, the rule the three `stamp` functions now share: a changed merge
    //    unit's stamp is its EDIT time, raised one above the stamp it overwrote,
    //    so a slow clock cannot lose to the value it replaced.
    do {
        var holds = true
        var counterexample = ""
        for _ in 0..<iterations {
            let editWall = generators.rng.pick([Int64.min, -1, 0, 1, 7, frozenWall,
                                                frozenWall - 86_400_000, Int64.max])
            let overwritten = generators.rng.pick([Int64.min, -1, 0, 1, 7, frozenWall,
                                                   frozenWall + 1_000, Int64.max])
            let stamp = PhiHybridClock.editStamp(editWallMs: editWall,
                                                 overwrittenStampMs: overwritten)
            let beatsWhatItOverwrote = overwritten == Int64.max || stamp > overwritten
            let keepsTheEditTime = stamp >= editWall
            guard !(beatsWhatItOverwrote && keepsTheEditTime) else { continue }
            holds = false
            counterexample = "editWall=\(editWall) overwritten=\(overwritten) -> \(stamp)"
            break
        }
        report.check("clock.an-edit-stamp-beats-the-value-it-overwrote", holds, counterexample)
        report.markPassed("clock.an-edit-stamp-beats-the-value-it-overwrote")
    }

    // 8. `observe` is monotone and order-independent: logical time is a max, so
    //    the order stamps happen to be landed in cannot change it.
    do {
        var holds = true
        var counterexample = ""
        for _ in 0..<iterations {
            let stamps = (0..<8).map { _ in
                generators.rng.pick([Int64.min, 0, 1, 7, frozenWall, Int64.max])
            }
            var left = PhiHybridClock()
            for stamp in stamps { left.observe(stamp) }
            var right = PhiHybridClock()
            for stamp in generators.rng.shuffled(stamps) { right.observe(stamp) }
            guard left.maxSeen != right.maxSeen else { continue }
            holds = false
            counterexample = "\(stamps) -> \(left.maxSeen) vs \(right.maxSeen)"
            break
        }
        report.check("clock.observation-is-order-independent", holds, counterexample)
        report.markPassed("clock.observation-is-order-independent")
    }
}

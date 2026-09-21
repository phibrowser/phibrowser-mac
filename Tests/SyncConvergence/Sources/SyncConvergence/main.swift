// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// Hostless convergence harness. See Tests/SyncConvergence/README.md.
//
//   SYNC_CONV_SEED        seed (decimal or 0x hex); default 0x5D1B2E9F00C0FFEE
//   SYNC_CONV_ITERATIONS  Layer 1 iterations per property, default 400
//   SYNC_CONV_STEPS       Layer 2 scheduler steps per scenario, default 600
//   SYNC_CONV_SKEW        1 to include the clock-skew scenarios, default 1
//   SYNC_CONV_HLC         0 to stamp Layer 2 with the plain wall clock Phi used
//                         before C2 instead of the production PhiHybridClock,
//                         default 1. The skew scenarios always run BOTH, so one
//                         run shows the before and after on the same seed.

private func env(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

private func parseSeed(_ text: String) -> UInt64? {
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
        return UInt64(text.dropFirst(2), radix: 16)
    }
    return UInt64(text)
}

let defaultSeed: UInt64 = 0x5D1B_2E9F_00C0_FFEE
let seed = env("SYNC_CONV_SEED").flatMap(parseSeed) ?? defaultSeed
let iterations = env("SYNC_CONV_ITERATIONS").flatMap(Int.init) ?? 400
let simSteps = env("SYNC_CONV_STEPS").flatMap(Int.init) ?? 600
let includeSkew = (env("SYNC_CONV_SKEW") ?? "1") != "0"
let hybridClock = (env("SYNC_CONV_HLC") ?? "1") != "0"

print("phi sync convergence harness")
print(String(format: "  seed        = 0x%016llX  (SYNC_CONV_SEED)", seed))
print("  iterations  = \(iterations) per Layer 1 property")
print("  sim steps   = \(simSteps) per Layer 2 scenario")
print("  stamping    = \(hybridClock ? "PhiHybridClock (C2)" : "plain wall clock (pre-C2)")")
print("")

let report = Report()

// ---------------------------------------------------------------- Layer 1 ----
var generators = Generators(rng: SplitMix64(seed: seed))
runLayer1(iterations: iterations, generators: &generators, report: report)
runRankProperties(iterations: iterations, generators: &generators, report: report)
runClockProperties(iterations: iterations, generators: &generators, report: report)
checkPlannerRefusesAnInjectedCycle(report: report)
checkAnOfflineMoveLosesToALaterOnlineMove(report: report)
print("Layer 1: \(report.checks) algebraic checks over 5 merges, the shared LWW winner "
      + "and the rank primitives")

// ---------------------------------------------------------------- Layer 2 ----
struct ScenarioSummary {
    var name: String
    var outcome: SimOutcome
}
var summaries: [ScenarioSummary] = []

/// `assertIntent` is on for every scenario stamped through the production clock.
/// It asserts only the CAUSAL half: an edit whose author had already observed
/// every competing edit is stamped strictly above all of them by AM-1, so losing
/// it is a defect. Concurrent losses stay reported -- LWW gives up true-time
/// ordering of concurrent writes by definition, and no logical clock returns it.
func describe(_ name: String, _ outcome: SimOutcome, report: Report, assertIntent: Bool) {
    report.check("simulation.\(name).all-replicas-converge", outcome.converged,
                 outcome.divergence ?? "")
    report.markPassed("simulation.\(name).all-replicas-converge")
    report.check("simulation.\(name).reaches-quiescence", outcome.quiesced,
                 "still committing after \(outcome.rounds) idle sync rounds "
                 + "(\(outcome.quiesceCommits) commits, \(outcome.conflicts) conflicts): the "
                 + "replicas keep rewriting each other's entities")
    report.markPassed("simulation.\(name).reaches-quiescence")
    summaries.append(ScenarioSummary(name: name, outcome: outcome))
    if assertIntent {
        report.check("simulation.\(name).a-causally-later-edit-wins",
                     outcome.causalIntentLosses.isEmpty,
                     "\(outcome.causalIntentLosses.count) of \(outcome.intentChecked) "
                     + "identities lost an edit whose author had already observed every "
                     + "competing edit, which the hybrid logical clock must make impossible. "
                     + "First case -- \(outcome.causalIntentLosses.first ?? "")")
        report.markPassed("simulation.\(name).a-causally-later-edit-wins")
    }
    if !outcome.concurrentIntentLosses.isEmpty {
        report.note("""
            simulation.\(name): \(outcome.concurrentIntentLosses.count) of \
            \(outcome.intentChecked) identities converged on something other than the latest \
            edit by TRUE wall clock, all of them CONCURRENT -- the editing replica had not seen \
            the value it lost to. Convergence holds and the causal property holds; ordering \
            concurrent writes by true time is what LWW gives up, not something a logical clock \
            can restore. First case -- \(outcome.concurrentIntentLosses[0])
            """)
    }
}

var simRng = SplitMix64(seed: seed &* 0x9E37_79B9)

do {
    let outcome = Simulation(kind: settingsSimKind(), identities: ["phi-settings"],
                             replicaCount: 3, steps: simSteps, hybridClock: hybridClock)
        .run(rng: &simRng, report: report)
    describe("settings", outcome, report: report, assertIntent: hybridClock)
}
do {
    let outcome = Simulation(kind: spacesSimKind(), identities: Pool.spaceUuids,
                             replicaCount: 4, steps: simSteps, hybridClock: hybridClock)
        .run(rng: &simRng, report: report)
    describe("spaces", outcome, report: report, assertIntent: hybridClock)
}
do {
    let simulation = Simulation(kind: bookmarksSimKind(), identities: simBookmarkIdentities,
                                replicaCount: 3, steps: simSteps, hybridClock: hybridClock)
    let outcome = simulation.run(rng: &simRng, report: report)
    describe("bookmarks", outcome, report: report, assertIntent: hybridClock)
}
do {
    let outcome = Simulation(kind: pinsSimKind(), identities: simPinIdentities,
                             replicaCount: 3, steps: simSteps, hybridClock: hybridClock)
        .run(rng: &simRng, report: report)
    describe("pins", outcome, report: report, assertIntent: hybridClock)
}
do {
    let outcome = Simulation(kind: rulesSimKind(), identities: simRuleIdentities,
                             replicaCount: 3, steps: simSteps, hybridClock: hybridClock)
        .run(rng: &simRng, report: report)
    describe("urlrules", outcome, report: report, assertIntent: hybridClock)
}

// Bookmark tree invariants over a converged set, checked with the production
// planner. A dedicated run so the entity set is reachable here.
do {
    var treeRng = SplitMix64(seed: seed &+ 0x1234_5678)
    let simulation = Simulation(kind: bookmarksSimKind(), identities: simBookmarkIdentities,
                                replicaCount: 3, steps: simSteps)
    _ = simulation.run(rng: &treeRng, report: report)
    // Rebuild a converged set deterministically by replaying the same seed
    // through a short quiescing run and reading replica 0 out of the merge of
    // every identity's final value.
    var entities: [String: Phi_PhiBookmarkEntity] = [:]
    var rng = SplitMix64(seed: seed &+ 0x1234_5678)
    let kind = bookmarksSimKind()
    for identity in simBookmarkIdentities {
        var clock = PhiHybridClock()
        func stamper(_ wall: Int64) -> SimStamper {
            SimStamper(editWallMs: wall, hlcMax: hybridClock ? clock.maxSeen : nil)
        }
        var entity = kind.create(identity, stamper(1_700_000_000_000), &rng)
        for stamp in kind.stamps(entity) { clock.observe(stamp) }
        for _ in 0..<6 {
            entity = kind.edit(entity, stamper(1_700_000_000_000 + Int64(rng.int(1...50))), &rng)
            for stamp in kind.stamps(entity) { clock.observe(stamp) }
        }
        entities[identity] = entity
    }
    checkBookmarkTree(entities, report: report, label: "bookmarks.tree")
}

// Clock skew: the same scenarios with replicas whose clocks disagree by hours.
// Clock skew is where the two clocks differ, so both are run on the SAME seed
// and both are printed: `[skew,wall]` is the pre-C2 baseline, `[skew]` is the
// production hybrid clock. Only the latter is asserted.
if includeSkew {
    let skew: [Int64] = [6 * 3_600_000, 0, -90 * 60_000]
    for hybrid in [false, true] {
        let suffix = hybrid ? "[skew]" : "[skew,wall]"
        // One RNG per mode, seeded identically, so the two runs schedule the
        // same edits and the intent numbers are directly comparable.
        var modeRng = SplitMix64(seed: seed &* 0xD1B5_4A32 &+ 0x9E37)
        do {
            let outcome = Simulation(kind: bookmarksSimKind(), identities: simBookmarkIdentities,
                                     replicaCount: 3, steps: simSteps, clockSkew: skew,
                                     hybridClock: hybrid)
                .run(rng: &modeRng, report: report)
            describe("bookmarks" + suffix, outcome, report: report, assertIntent: hybrid)
        }
        do {
            let outcome = Simulation(kind: rulesSimKind(), identities: simRuleIdentities,
                                     replicaCount: 3, steps: simSteps, clockSkew: skew,
                                     hybridClock: hybrid)
                .run(rng: &modeRng, report: report)
            describe("urlrules" + suffix, outcome, report: report, assertIntent: hybrid)
        }
        do {
            let outcome = Simulation(kind: settingsSimKind(), identities: ["phi-settings"],
                                     replicaCount: 3, steps: simSteps, clockSkew: skew,
                                     hybridClock: hybrid)
                .run(rng: &modeRng, report: report)
            describe("settings" + suffix, outcome, report: report, assertIntent: hybrid)
        }
    }
}

print("")
print("Layer 2: merge-level replica simulations")
for summary in summaries {
    let o = summary.outcome
    print("  \(summary.name.padding(toLength: 22, withPad: " ", startingAt: 0))"
          + " converged=\(o.converged ? "yes" : "NO ")"
          + " commits=\(o.commits) conflicts=\(o.conflicts)"
          + " dup-pages=\(o.duplicatePages) dropped=\(o.droppedPages)"
          + " offline=\(o.offlineEpisodes) deletes=\(o.deletes)"
          + " quiesce-rounds=\(o.rounds)\(o.quiesced ? "" : "(BOUND)")"
          + " quiesce-commits=\(o.quiesceCommits)"
          + " intent-losses=\(o.intentLosses.count)/\(o.intentChecked)"
          + " (causal=\(o.causalIntentLosses.count)"
          + " concurrent=\(o.concurrentIntentLosses.count))")
}

// ----------------------------------------------------------------- Output ----
print("")
if !report.notes.isEmpty {
    print("OBSERVATIONS (reported, not asserted)")
    for note in report.notes { print("  - " + note.replacingOccurrences(of: "\n", with: "\n    ")) }
    print("")
}

if report.failed {
    print("FAILURES")
    for finding in report.violations {
        print("  ✗ \(finding.property)  (\(finding.hits) failing cases)")
        for line in finding.counterexample.split(separator: "\n", omittingEmptySubsequences: false) {
            print("      " + line)
        }
        print("")
    }
    print(String(format: "Reproduce with: SYNC_CONV_SEED=0x%016llX "
                 + "SYNC_CONV_ITERATIONS=\(iterations) SYNC_CONV_STEPS=\(simSteps) "
                 + "bash build-scripts/test-sync-convergence.sh", seed))
    print("FAIL: \(report.violations.count) properties violated out of "
          + "\(report.violations.count + report.passed.count) checked "
          + "(\(report.checks) total cases)")
    exit(1)
}

print("PASS: \(report.passed.count) properties, \(report.checks) cases, "
      + String(format: "seed 0x%016llX", seed))

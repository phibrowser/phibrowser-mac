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
runNormalisationProperties(iterations: iterations, generators: &generators, report: report)
runRankProperties(iterations: iterations, generators: &generators, report: report)
runClockProperties(iterations: iterations, generators: &generators, report: report)
checkPlannerRefusesAnInjectedCycle(report: report)
checkAnOfflineMoveLosesToALaterOnlineMove(report: report)
checkAnOfflineRenameLosesToALaterOnlineRename(report: report)
checkAnEditedChildSurvivesItsFoldersDeletion(report: report)
print("Layer 1: \(report.checks) algebraic checks over 5 merges, the shared LWW winner, "
      + "the rank primitives and the normalisation of payloads the schema forbids")

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
    // Ruling C4, both directions, over the same run: an item whose delete an edit beat exists
    // everywhere, and a delete nobody contradicted stays gone everywhere.
    report.check("simulation.\(name).an-edit-beats-a-concurrent-delete",
                 outcome.editBeatsDeleteViolations.isEmpty,
                 "\(outcome.editBeatsDeleteViolations.count) identities broke C4 after "
                 + "quiescence (\(outcome.yields) yields, \(outcome.cancelledDeletes) cancelled "
                 + "deletes). First case -- \(outcome.editBeatsDeleteViolations.first ?? "")")
    report.markPassed("simulation.\(name).an-edit-beats-a-concurrent-delete")
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

// Why the non-associative rank-coherence rule (RC3, see ExpectedFailures.swift)
// cannot split an account: the minimal counterexample replayed to three replicas
// through every schedule the protocol permits.
checkRankCoherenceCannotDivergeReplicas(report: report)

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
        // Spaces stamp at edit time too as of C2-a, so "a causally later edit wins" is asserted
        // for them under skew like every other kind. Last in the block on purpose: appending
        // leaves the three scenarios above on the RNG stream they already had.
        do {
            let outcome = Simulation(kind: spacesSimKind(), identities: Pool.spaceUuids,
                                     replicaCount: 3, steps: simSteps, clockSkew: skew,
                                     hybridClock: hybrid)
                .run(rng: &modeRng, report: report)
            describe("spaces" + suffix, outcome, report: report, assertIntent: hybrid)
        }
    }
}

// The C4 property above is only as good as the number of delete-versus-edit races the scheduler
// actually produced. Sum them over every scenario and fail if the run produced none at all, so a
// green report can never mean "no delete ever met an edit".
let raced = summaries.reduce(into: 0) { $0 += $1.outcome.yields + $1.outcome.cancelledDeletes }
report.check("simulation.edit-beats-delete-is-actually-exercised", raced > 0,
             "no delete met a concurrent edit in any scenario on this seed; the C4 property "
             + "passed vacuously. Raise SYNC_CONV_STEPS or pick another SYNC_CONV_SEED.")
report.markPassed("simulation.edit-beats-delete-is-actually-exercised")

print("")
print("Layer 2: merge-level replica simulations")
for summary in summaries {
    let o = summary.outcome
    print("  \(summary.name.padding(toLength: 22, withPad: " ", startingAt: 0))"
          + " converged=\(o.converged ? "yes" : "NO ")"
          + " commits=\(o.commits) conflicts=\(o.conflicts)"
          + " dup-pages=\(o.duplicatePages) dropped=\(o.droppedPages)"
          + " offline=\(o.offlineEpisodes) deletes=\(o.deletes)"
          + " yields=\(o.yields) cancelled-deletes=\(o.cancelledDeletes)"
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

// The expected-failure allowlist, printed on EVERY run whether it is green or
// not: a registered failure that nobody reads is a deleted property with extra
// steps. See ExpectedFailures.swift for what each entry means.
let registered = Set(expectedFailures.map(\.property))
let violated = Set(report.violations.map(\.property))
var stale: [ExpectedFailure] = []

func printCounterexample(_ finding: Report.Finding, indent: String) {
    for line in finding.counterexample.split(separator: "\n", omittingEmptySubsequences: false) {
        print(indent + line)
    }
}

print("EXPECTED FAILURES (\(expectedFailures.count) registered in "
      + "Tests/SyncConvergence/Sources/SyncConvergence/ExpectedFailures.swift)")
for entry in expectedFailures {
    let reproduces = entry.witness()
    if !reproduces { stale.append(entry) }
    print("  \(reproduces ? "!" : "✗ UNEXPECTED PASS:") \(entry.property)")
    print("      witness      "
          + (reproduces
             ? "still reproduces -- the rule is unchanged"
             : "NO LONGER REPRODUCES. The rule was repaired or moved; delete this entry."))
    print("      this seed    "
          + (violated.contains(entry.property)
             ? "hit it in the randomized search"
             : "did not hit it; the witness is what pins the entry"))
    print("      root cause   " + entry.rootCause.replacingOccurrences(of: "\n",
                                                                      with: "\n                   "))
    print("      waits on     " + entry.waitsOn.replacingOccurrences(of: "\n",
                                                                    with: "\n                   "))
    if let finding = report.violations.first(where: { $0.property == entry.property }) {
        print("      counterexample (\(finding.hits) failing cases):")
        printCounterexample(finding, indent: "        ")
    }
    print("")
}

// A stale entry stops covering its property: its witness is gone, so a failure
// the search still finds is a DIFFERENT one and must be reported as unexpected
// rather than absorbed by an entry that no longer describes it.
let staleProperties = Set(stale.map(\.property))
let unexpected = report.violations.filter {
    !registered.contains($0.property) || staleProperties.contains($0.property)
}
if !unexpected.isEmpty {
    print("FAILURES (not covered by the expected-failure list)")
    for finding in unexpected {
        print("  ✗ \(finding.property)  (\(finding.hits) failing cases)")
        printCounterexample(finding, indent: "      ")
        print("")
    }
}

let reproduceLine = String(format: "Reproduce with: SYNC_CONV_SEED=0x%016llX "
                           + "SYNC_CONV_ITERATIONS=\(iterations) SYNC_CONV_STEPS=\(simSteps) "
                           + "bash build-scripts/test-sync-convergence.sh", seed)
let asserted = report.violations.count + report.passed.count

// Exit status, documented in Tests/SyncConvergence/README.md, "Using this as a
// gate": 0 only when nothing unexpected happened in EITHER direction.
if !unexpected.isEmpty {
    print(reproduceLine)
    print("FAIL: \(unexpected.count) unexpected property violations out of \(asserted) asserted "
          + "(\(report.checks) cases, \(report.violations.count - unexpected.count) of "
          + "\(expectedFailures.count) registered failures also seen)")
    exit(1)
}
if !stale.isEmpty {
    print(reproduceLine)
    print("FAIL: the expected-failure list is stale -- \(stale.count) entry/entries no longer "
          + "reproduce: \(stale.map(\.property).joined(separator: ", ")). Every asserted property "
          + "held; remove the repaired entry from ExpectedFailures.swift to re-arm the gate.")
    exit(2)
}

print("PASS: \(report.passed.count) properties, \(report.checks) cases, "
      + "\(expectedFailures.count) registered failures still reproducing, "
      + String(format: "seed 0x%016llX", seed))

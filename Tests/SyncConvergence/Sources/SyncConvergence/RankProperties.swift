// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// The fractional rank channel. `rankBetween` has release-build preconditions,
// so the properties here are as much about the DECODING BOUNDARY (`isLegalRank`)
// as about the arithmetic: nothing that fails the boundary may ever reach the
// function, and `assignRanks` is the only production caller that generates.

private func randomLegalRank(_ rng: inout SplitMix64) -> String {
    let alphabet = SyncableSpaces.rankAlphabet
    let length = rng.int(1...4)
    var out = ""
    for position in 0..<length {
        // The last digit may not be the lowest one, which is exactly the
        // invariant every rank this file produces satisfies.
        let lower = position == length - 1 ? 1 : 0
        out.append(alphabet[rng.int(lower...(alphabet.count - 1))])
    }
    return out
}

func runRankProperties(iterations: Int, generators: inout Generators, report: Report) {

    // --- The decoding boundary ------------------------------------------------
    for rank in Pool.legalRanks {
        report.check("isLegalRank.accepts-generated-shapes",
                     SyncableSpaces.isLegalRank(rank), "rank=\(rank)")
    }
    for rank in Pool.illegalRanks {
        report.check("isLegalRank.rejects-unsafe-shapes",
                     !SyncableSpaces.isLegalRank(rank), "rank=\(rank)")
    }
    for _ in 0..<iterations {
        let rank = randomLegalRank(&generators.rng)
        report.check("isLegalRank.accepts-generated-shapes",
                     SyncableSpaces.isLegalRank(rank), "rank=\(rank)")
    }
    report.markPassed("isLegalRank.accepts-generated-shapes")
    report.markPassed("isLegalRank.rejects-unsafe-shapes")

    // --- rankBetween ----------------------------------------------------------
    for _ in 0..<iterations {
        var lower: String? = generators.rng.chance(4) ? nil : randomLegalRank(&generators.rng)
        var upper: String? = generators.rng.chance(4) ? nil : randomLegalRank(&generators.rng)
        if let l = lower, let u = upper, !(l < u) {
            // The precondition is the caller's job; `assignRanks` separates tied
            // endpoints before calling, so the harness does too.
            if l == u { upper = nil } else { swap(&lower, &upper) }
        }
        let result = SyncableSpaces.rankBetween(lower, upper)
        report.check("rankBetween.strictly-between",
                     (lower.map { $0 < result } ?? true) && (upper.map { result < $0 } ?? true),
                     "lower=\(lower ?? "nil") upper=\(upper ?? "nil") result=\(result)")
        report.check("rankBetween.output-is-legal", SyncableSpaces.isLegalRank(result),
                     "lower=\(lower ?? "nil") upper=\(upper ?? "nil") result=\(result)")
    }

    // Repeated subdivision of one interval: the representation must keep finding
    // room, and every intermediate value must stay legal.
    for _ in 0..<max(1, iterations / 8) {
        var low = randomLegalRank(&generators.rng)
        var high = randomLegalRank(&generators.rng)
        if low == high { high = low + "V" }
        if low > high { swap(&low, &high) }
        for _ in 0..<32 {
            let middle = SyncableSpaces.rankBetween(low, high)
            guard SyncableSpaces.isLegalRank(middle), low < middle, middle < high else {
                report.check("rankBetween.repeated-subdivision", false,
                             "low=\(low) high=\(high) middle=\(middle)")
                break
            }
            if generators.rng.bool() { low = middle } else { high = middle }
        }
        report.check("rankBetween.repeated-subdivision", true, "")
    }
    report.markPassed("rankBetween.strictly-between")
    report.markPassed("rankBetween.output-is-legal")
    report.markPassed("rankBetween.repeated-subdivision")

    // --- assignRanks ----------------------------------------------------------
    // The probe is the production seam: `assignRanks` takes its generator as a
    // parameter precisely so `SyncableOwnedItems` can route through a counter.
    // Here it asserts that no untrusted shape ever reaches the trapping function.
    for iteration in 0..<iterations {
        let count = generators.rng.int(1...8)
        var order: [(uuid: String, rank: String?)] = []
        for index in 0..<count {
            let uuid = "id-\(index)-\(generators.rng.int(0...2))"
            let rank: String? = generators.rng.chance(3)
                ? nil
                : (generators.rng.chance(3) ? generators.rng.pick(Pool.legalRanks)
                                            : randomLegalRank(&generators.rng))
            order.append((uuid: uuid, rank: rank))
        }
        // Duplicate uuids would make the result dictionary lose an element; the
        // production callers deduplicate before calling (R-exec-12 / D-B).
        var seen: Set<String> = []
        order = order.filter { seen.insert($0.uuid).inserted }

        var illegalArgument: String?
        let probe: (String?, String?) -> String = { lower, upper in
            if let lower, !SyncableSpaces.isLegalRank(lower) {
                illegalArgument = "lower=\(lower)"
            }
            if let upper, !SyncableSpaces.isLegalRank(upper) {
                illegalArgument = "upper=\(upper)"
            }
            if let lower, let upper, !(lower < upper) {
                illegalArgument = "lower=\(lower) !< upper=\(upper)"
            }
            return SyncableSpaces.rankBetween(lower, upper)
        }
        let assigned = SyncableSpaces.assignRanks(order: order, rankBetween: probe)
        let rendered = order.map { "\($0.uuid)@\($0.rank ?? "nil")" }.joined(separator: " ")

        report.check("assignRanks.never-feeds-rankBetween-an-unsafe-bound",
                     illegalArgument == nil,
                     "iteration=\(iteration) order=[\(rendered)] offending \(illegalArgument ?? "")")

        for (uuid, rank) in assigned {
            report.check("assignRanks.assigns-only-legal-ranks",
                         SyncableSpaces.isLegalRank(rank),
                         "iteration=\(iteration) order=[\(rendered)] \(uuid)->\(rank)")
        }

        // The effective order is what `plannedOrder` / `rankToIndex` sort by:
        // (rank, identity). It must be strictly increasing, or the account's
        // order is ambiguous.
        let effective = order.map { (uuid: $0.uuid, rank: assigned[$0.uuid] ?? $0.rank ?? "") }
        var monotone = true
        for index in 1..<max(effective.count, 1) {
            let previous = effective[index - 1], current = effective[index]
            if !(previous.rank < current.rank
                 || (previous.rank == current.rank && previous.uuid < current.uuid)) {
                monotone = false
            }
        }
        report.check("assignRanks.effective-order-is-strictly-increasing", monotone,
                     "iteration=\(iteration) order=[\(rendered)] "
                     + "effective=[\(effective.map { "\($0.uuid)@\($0.rank)" }.joined(separator: " "))]")
    }
    report.markPassed("assignRanks.never-feeds-rankBetween-an-unsafe-bound")
    report.markPassed("assignRanks.assigns-only-legal-ranks")
    report.markPassed("assignRanks.effective-order-is-strictly-increasing")

    // --- Dense projections ----------------------------------------------------
    // `rankToIndex` / `rankToSortOrder` must be a permutation of 0..<n over the
    // rows they are handed, or two siblings collide on one slot.
    for _ in 0..<iterations {
        let count = generators.rng.int(1...6)
        var rows: [PhiLocalBookmark] = []
        var ranks: [String: String] = [:]
        for index in 0..<count {
            let syncId = "bm-\(index)"
            rows.append(PhiLocalBookmark(syncId: generators.rng.chance(4) ? nil : syncId,
                                         guid: "guid-\(index)", spaceId: "space-a",
                                         profileId: "p", parentGuid: nil, index: index,
                                         isFolder: false, title: "t",
                                         url: URL(string: "https://a.example/")!,
                                         secondaryUrl: nil, secondaryTitle: nil, source: 0,
                                         createdDate: Date(timeIntervalSince1970: 0),
                                         contentUpdatedDate: nil,
                                         locationUpdatedDate: nil))
            ranks[syncId] = generators.rng.chance(3) ? generators.rng.pick(Pool.legalRanks)
                                                     : randomLegalRank(&generators.rng)
        }
        let index = BookmarkKind.rankToIndex(siblings: rows, ranks: ranks)
        report.check("rankToIndex.is-a-dense-permutation",
                     Set(index.values) == Set(0..<rows.count) && index.count == rows.count,
                     "rows=\(rows.count) index=\(index)")
    }
    report.markPassed("rankToIndex.is-a-dense-permutation")
}

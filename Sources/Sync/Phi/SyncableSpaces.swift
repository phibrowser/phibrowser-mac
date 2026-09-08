// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Space-side snapshot / merge / apply plus the rank primitives behind D4's
/// "one drag rewrites one entity". Everything here is a pure function: the
/// engine owns all persistence (§6.2 -- `snapshot` writes nothing).
enum SyncableSpaces {

    // MARK: - Fractional ranks (§7)

    /// Strictly ASCII-ascending base-62, so plain lexicographic comparison IS
    /// numeric comparison of the implied fraction `0.<rank>`.
    static let rankAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static var rankIndex: [Character: Int] {
        var map: [Character: Int] = [:]
        for (i, c) in rankAlphabet.enumerated() { map[c] = i }
        return map
    }

    /// A rank strictly between `a` and `b`, never ending in the lowest digit
    /// (so there is always room below it).
    ///
    /// - Precondition: when both bounds are present they must satisfy `a < b`.
    ///   `a == b` HAS NO SOLUTION -- the representation only guarantees a value
    ///   between two *different* ranks -- so this traps rather than looping or
    ///   returning an endpoint. Callers separate tied endpoints first
    ///   (`assignRanks`'s tie-interval rule).
    /// - Precondition: the upper bound never ends in the lowest digit. That is
    ///   this type's own invariant (every rank this file produces ends in a
    ///   midpoint digit >= 1), and it is what makes "strictly below `b`" always
    ///   solvable: nothing over this alphabet is lexicographically less than
    ///   `"0"`, and for `"<prefix>0"` the only room left is under the prefix.
    ///   Trapping here is the same honesty as the `a == b` case -- silently
    ///   returning a value ABOVE the bound would corrupt the account's order.
    static func rankBetween(_ a: String?, _ b: String?) -> String {
        if let a, let b { precondition(a < b, "rankBetween requires a < b") }
        precondition(!(b?.hasSuffix("0") ?? false),
                     "a rank never ends in the lowest digit, so it is not a legal upper bound")
        let index = rankIndex
        let base = rankAlphabet.count
        let lower = (a ?? "").map { index[$0] ?? 0 }
        let upper = b.map { $0.map { index[$0] ?? 0 } }

        var out: [Int] = []
        var position = 0
        while true {
            let lo = position < lower.count ? lower[position] : 0
            let hi: Int
            if let upper {
                // Once `out` is already strictly greater than the prefix of the
                // upper bound, the bound stops constraining further digits.
                hi = position < upper.count && out.elementsEqual(upper.prefix(position)) ? upper[position] : base
            } else {
                hi = base
            }
            if hi - lo > 1 {
                out.append((lo + hi) / 2)
                break
            }
            // Digits are adjacent (or equal): keep the lower digit and refine.
            out.append(lo)
            position += 1
        }
        // The loop only ever exits through the `hi - lo > 1` branch, whose digit
        // is `(lo + hi) / 2` with `lo >= 0` and `hi >= lo + 2` -- i.e. always
        // >= 1. So the result structurally never ends in the lowest digit and
        // needs no trailing-zero pass.
        return String(out.map { rankAlphabet[$0] })
    }

    // MARK: - Longest increasing kept set (§7)

    /// Indices to LEAVE ALONE: the longest strictly increasing subsequence of
    /// the local order under the total order `(rank, uuid)`. Elements with no
    /// rank (brand new, or a device snapshotting an old Space for the first
    /// time) never join it, so they always land in the complement and get a
    /// rank from the interval rule. Patience sorting, O(n log n).
    static func longestIncreasingKeptSet(_ keys: [(rank: String?, uuid: String)]) -> Set<Int> {
        struct Key: Comparable {
            let rank: String
            let uuid: String
            static func < (l: Key, r: Key) -> Bool {
                l.rank == r.rank ? l.uuid < r.uuid : l.rank < r.rank
            }
        }
        var tailKey: [Key] = []
        var tailIndex: [Int] = []
        var previous = [Int](repeating: -1, count: keys.count)

        for (i, element) in keys.enumerated() {
            guard let rank = element.rank else { continue }
            let key = Key(rank: rank, uuid: element.uuid)
            // First tail strictly greater than `key` -> replace it (strict LIS).
            var lo = 0, hi = tailKey.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tailKey[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            previous[i] = lo > 0 ? tailIndex[lo - 1] : -1
            if lo == tailKey.count {
                tailKey.append(key)
                tailIndex.append(i)
            } else {
                tailKey[lo] = key
                tailIndex[lo] = i
            }
        }
        guard !tailIndex.isEmpty else { return [] }
        var kept: Set<Int> = []
        // The last tail slot always holds the end of SOME longest increasing
        // subsequence, so it is the reconstruction entry point; no separate
        // "best end" bookkeeping is needed.
        var cursor = tailIndex[tailIndex.count - 1]
        while cursor >= 0 {
            kept.insert(cursor)
            cursor = previous[cursor]
        }
        return kept
    }

    // MARK: - Rank assignment (§7)

    /// New ranks for the Spaces that must be rewritten this snapshot, keyed by
    /// uuid. `order` is the CURRENT LOCAL strip order of the sync-eligible
    /// Spaces with their shadow ranks. Elements inside the kept set are absent
    /// from the result: they are not rewritten, get no new timestamp and do not
    /// enter this round's commit batch.
    static func assignRanks(order: [(uuid: String, rank: String?)]) -> [String: String] {
        let kept = longestIncreasingKeptSet(order.map { (rank: $0.rank, uuid: $0.uuid) })
        var keptFlags = [Bool](repeating: false, count: order.count)
        for i in kept { keptFlags[i] = true }

        var assigned: [String: String] = [:]
        // Effective rank of an element: a freshly assigned one wins over the shadow.
        func effective(_ i: Int) -> String? { assigned[order[i].uuid] ?? order[i].rank }

        var i = 0
        while i < order.count {
            guard !keptFlags[i] else { i += 1; continue }

            // Left endpoint: the nearest FINALIZED rank to the left (kept, or
            // generated earlier in this same pass), so several complement
            // elements in one gap come out strictly increasing.
            var left: String?
            var j = i - 1
            while j >= 0 {
                if let r = effective(j) { left = r; break }
                j -= 1
            }
            // Right endpoint: the nearest kept rank to the right. The tie
            // interval rule (§7): while it is not strictly greater than `left`,
            // evict it from the kept set into the complement and look further
            // right.
            var right: String?
            var k = i + 1
            while k < order.count {
                if keptFlags[k], let r = order[k].rank {
                    if let left, !(left < r) {
                        keptFlags[k] = false   // evicted; it gets a new rank below
                        k += 1
                        continue
                    }
                    right = r
                    break
                }
                k += 1
            }
            assigned[order[i].uuid] = rankBetween(left, right)
            i += 1
        }
        return assigned
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Seeded randomness, failure accounting and the protobuf helpers the harness
// needs. Everything here is deterministic: one seed reproduces one run exactly.

// MARK: - Deterministic RNG

/// SplitMix64. Chosen over `SystemRandomNumberGenerator` because a failing run
/// must be replayable from the seed alone, and over `arc4random` because the
/// state is one word we can print.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<bound`.
    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + below(range.count)
    }

    /// True with probability `1/outOf`.
    mutating func chance(_ outOf: Int) -> Bool { below(outOf) == 0 }

    mutating func bool() -> Bool { next() & 1 == 1 }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }

    mutating func shuffled<T>(_ values: [T]) -> [T] {
        var out = values
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            out.swapAt(i, below(i + 1))
        }
        return out
    }
}

// MARK: - Failure accounting

/// Collects violations per property. The first counterexample of each property
/// is kept verbatim: these counterexamples are the harness's real output, so
/// they are never summarised away.
final class Report {
    struct Finding {
        var property: String
        var counterexample: String
        var hits: Int
        var iterations: Int
    }

    private var findings: [String: Finding] = [:]
    private var order: [String] = []
    private(set) var passed: [String] = []
    private(set) var checks = 0
    private(set) var notes: [String] = []

    func check(_ property: String, _ holds: Bool, _ counterexample: @autoclosure () -> String) {
        checks += 1
        guard !holds else { return }
        if findings[property] == nil {
            order.append(property)
            findings[property] = Finding(property: property, counterexample: counterexample(),
                                         hits: 0, iterations: 0)
        }
        findings[property]?.hits += 1
    }

    /// An observation that is reported but not asserted (a known issue being
    /// fixed elsewhere, or an intent that the current design cannot guarantee).
    func note(_ text: String) { notes.append(text) }

    func markPassed(_ property: String) {
        if findings[property] == nil { passed.append(property) }
    }

    var violations: [Finding] { order.compactMap { findings[$0] } }
    var failed: Bool { !findings.isEmpty }
}

// MARK: - Protobuf helpers

enum Wire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// One varint field on the wire, for a field number this build does not know.
    static func unknownField(number: Int, value: UInt64) -> Data {
        Data(varint(UInt64(number) << 3) + varint(value))
    }
}

/// Re-parse `message` with one extra varint field appended, so it carries
/// `unknownFields` the way a payload written by a newer client would.
/// The reserved ranges (Space 11-14, bookmark 12-15, pin 10-13, rule 9-12) are
/// exactly what the merge contracts promise to carry through untouched.
func addingUnknownField<M: SwiftProtobuf.Message>(_ message: M, number: Int, value: UInt64) -> M {
    guard var data = try? message.serializedData() else { return message }
    data.append(Wire.unknownField(number: number, value: value))
    return (try? M(serializedBytes: data)) ?? message
}

extension SwiftProtobuf.Message {
    /// One-line rendering for counterexamples.
    var oneLine: String {
        textFormatString().replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}

func settingValue(_ text: String, _ stamp: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.stringValue = text
    out.updatedAtMs = stamp
    return out
}

func settingValue(int: Int64, _ stamp: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.intValue = int
    out.updatedAtMs = stamp
    return out
}

func settingValue(bool: Bool, _ stamp: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.boolValue = bool
    out.updatedAtMs = stamp
    return out
}

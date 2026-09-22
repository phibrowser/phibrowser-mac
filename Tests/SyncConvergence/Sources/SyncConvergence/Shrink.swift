// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Generic counterexample shrinking on the protobuf wire.
//
// A randomly generated entity has ten populated fields; a merge-law violation
// usually needs two or three. Shrinking works at the wire level so it stays
// kind-agnostic: split each entity into its top-level fields, drop one field
// number from every entity at once, re-parse, and keep the reduction whenever
// the property still fails. Since the reduced case is re-checked, a shrunk
// counterexample always violates the same law the original did.

enum WireSplit {
    struct Field {
        var number: Int
        /// Tag and payload, exactly as they appeared.
        var bytes: Data
    }

    private static func varint(_ data: Data, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let byte = data[data.startIndex + index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    static func split(_ data: Data) -> [Field]? {
        var out: [Field] = []
        var index = 0
        while index < data.count {
            let start = index
            guard let key = varint(data, &index) else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard varint(data, &index) != nil else { return nil }
            case 1:
                index += 8
            case 2:
                guard let length = varint(data, &index) else { return nil }
                index += Int(length)
            case 5:
                index += 4
            default:
                return nil          // groups: not used by this schema
            }
            guard index <= data.count else { return nil }
            out.append(Field(number: number,
                             bytes: data.subdata(in: (data.startIndex + start)
                                                    ..< (data.startIndex + index))))
        }
        return out
    }

    static func joined(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields { out.append(field.bytes) }
        return out
    }
}

/// Drop top-level fields shared by every entity for as long as `fails` holds.
///
/// `keeping` lists the field numbers the schema says are ALWAYS EMITTED
/// ("never omitted-when-empty -- an absent field cannot carry a timestamp",
/// phi_entity.proto). Removing one of those produces a payload no Phi client
/// can send, and the resulting counterexample would say nothing about the
/// merge law under test, so they are protected from shrinking.
func shrink<E: SwiftProtobuf.Message & Equatable>(_ items: [E],
                                                  keeping alwaysEmitted: Set<Int> = [],
                                                  fails: ([E]) -> Bool) -> [E] {
    guard fails(items) else { return items }
    var current = items
    var splits: [[WireSplit.Field]] = []
    for item in current {
        guard let data = try? item.serializedData(), let fields = WireSplit.split(data) else {
            return current
        }
        splits.append(fields)
    }

    func rebuild(_ tables: [[WireSplit.Field]]) -> [E]? {
        var out: [E] = []
        for fields in tables {
            guard let value = try? E(serializedBytes: WireSplit.joined(fields)) else { return nil }
            out.append(value)
        }
        return out
    }

    var numbers = Set(splits.flatMap { $0.map(\.number) })
        .subtracting(alwaysEmitted).sorted(by: >)
    var progressed = true
    var passes = 0
    while progressed, passes < 8 {
        progressed = false
        passes += 1
        for number in numbers {
            let candidateTables = splits.map { $0.filter { $0.number != number } }
            guard let candidate = rebuild(candidateTables), fails(candidate) else { continue }
            splits = candidateTables
            current = candidate
            progressed = true
        }
        numbers = Set(splits.flatMap { $0.map(\.number) })
            .subtracting(alwaysEmitted).sorted(by: >)
    }
    return current
}

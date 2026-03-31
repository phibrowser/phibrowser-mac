// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    static func string(_ value: String) -> AnyCodable { AnyCodable(value) }

    var stringValue: String? { value as? String }
    var dictionaryValue: [String: AnyCodable]? { value as? [String: AnyCodable] }
    var int64Value: Int64? {
        if let i = value as? Int { return Int64(i) }
        if let i = value as? Int64 { return i }
        if let d = value as? Double { return Int64(d) }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s; return }
        if let i = try? container.decode(Int.self) { value = i; return }
        if let d = try? container.decode(Double.self) { value = d; return }
        if let b = try? container.decode(Bool.self) { value = b; return }
        if let obj = try? container.decode([String: AnyCodable].self) { value = obj; return }
        if let arr = try? container.decode([AnyCodable].self) { value = arr; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String: try container.encode(s)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let b as Bool: try container.encode(b)
        case let obj as [String: AnyCodable]: try container.encode(obj)
        case let arr as [AnyCodable]: try container.encode(arr)
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        return String(describing: lhs.value) == String(describing: rhs.value)
    }
}

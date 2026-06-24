// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SearchTabsChromiumSnapshot: Equatable {
    let openTabs: [ChromiumSearchOpenTab]
    let closedTabs: [ChromiumSearchClosedTab]
}

struct ChromiumSearchOpenTab: Equatable {
    let tabId: Int64
    let windowId: Int64
    let index: Int
    let title: String
    let url: String
    let groupIdHex: String
    let active: Bool
    let pinned: Bool
    let split: Bool
    let hostWindow: Bool
    let lastActiveElapsedMs: Int64
    let lastActiveElapsedText: String
}

struct ChromiumSearchClosedTab: Equatable {
    let sessionId: Int64
    let sourceEntrySessionId: Int64
    let sourceEntryType: String
    let title: String
    let url: String
    let groupIdHex: String
    let lastActiveTimeMs: Int64
    let lastActiveElapsedMs: Int64
    let lastActiveElapsedText: String
    let providerOrder: Int
}

@MainActor
struct SearchTabsChromiumProvider {
    var fetchData: (Int) -> [AnyHashable: Any]

    init(fetchData: @escaping (Int) -> [AnyHashable: Any] = { windowId in
        guard let data = ChromiumLauncher.sharedInstance().bridge?
            .getSearchTabsData(withWindowId: Int64(windowId)) as? [AnyHashable: Any] else {
            return [:]
        }
        return data
    }) {
        self.fetchData = fetchData
    }

    func snapshot(windowId: Int) -> SearchTabsChromiumSnapshot {
        Self.parse(data: fetchData(windowId))
    }

    static func parse(data: [AnyHashable: Any]) -> SearchTabsChromiumSnapshot {
        let openItems = arrayValue(data["openTabs"])
        let closedItems = arrayValue(data["recentlyClosedTabs"])

        return SearchTabsChromiumSnapshot(
            openTabs: openItems.compactMap(parseOpenTab),
            closedTabs: closedItems.enumerated().compactMap { index, item in
                parseClosedTab(item, providerOrder: index)
            }
        )
    }

    private static func parseOpenTab(_ item: Any) -> ChromiumSearchOpenTab? {
        guard let data = dictionaryValue(item) else { return nil }

        let tabId = int64Value(data["tabId"]) ?? 0
        let windowId = int64Value(data["windowId"]) ?? 0
        guard tabId > 0, windowId > 0 else { return nil }

        return ChromiumSearchOpenTab(
            tabId: tabId,
            windowId: windowId,
            index: intValue(data["index"]) ?? 0,
            title: stringValue(data["title"]) ?? "",
            url: stringValue(data["url"]) ?? "about:blank",
            groupIdHex: stringValue(data["groupIdHex"]) ?? "",
            active: boolValue(data["active"]) ?? false,
            pinned: boolValue(data["pinned"]) ?? false,
            split: boolValue(data["split"]) ?? false,
            hostWindow: boolValue(data["hostWindow"]) ?? false,
            lastActiveElapsedMs: int64Value(data["lastActiveElapsedMs"]) ?? Int64.max,
            lastActiveElapsedText: stringValue(data["lastActiveElapsedText"]) ?? ""
        )
    }

    private static func parseClosedTab(_ item: Any, providerOrder: Int) -> ChromiumSearchClosedTab? {
        guard let data = dictionaryValue(item) else { return nil }

        let sessionId = int64Value(data["sessionId"]) ?? 0
        guard sessionId > 0 else { return nil }

        return ChromiumSearchClosedTab(
            sessionId: sessionId,
            sourceEntrySessionId: int64Value(data["sourceEntrySessionId"]) ?? sessionId,
            sourceEntryType: stringValue(data["sourceEntryType"]) ?? "unknown",
            title: stringValue(data["title"]) ?? "",
            url: stringValue(data["url"]) ?? "",
            groupIdHex: stringValue(data["groupIdHex"]) ?? "",
            lastActiveTimeMs: int64Value(data["lastActiveTimeMs"]) ?? 0,
            lastActiveElapsedMs: int64Value(data["lastActiveElapsedMs"]) ?? Int64.max,
            lastActiveElapsedText: stringValue(data["lastActiveElapsedText"]) ?? "",
            providerOrder: providerOrder
        )
    }

    private static func arrayValue(_ value: Any?) -> [Any] {
        switch value {
        case let array as [Any]:
            return array
        case let array as NSArray:
            return array.map { $0 }
        default:
            return []
        }
    }

    private static func dictionaryValue(_ value: Any) -> [AnyHashable: Any]? {
        switch value {
        case let dictionary as [AnyHashable: Any]:
            return dictionary
        case let dictionary as NSDictionary:
            var result: [AnyHashable: Any] = [:]
            dictionary.forEach { key, value in
                if let key = key as? AnyHashable {
                    result[key] = value
                }
            }
            return result
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let int64 = int64Value(value),
              int64 >= Int64(Int.min),
              int64 <= Int64(Int.max) else {
            return nil
        }
        return Int(int64)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case is Bool:
            return nil
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Int32:
            return Int64(value)
        case let value as UInt:
            guard value <= UInt(Int64.max) else { return nil }
            return Int64(value)
        case let value as UInt64:
            guard value <= UInt64(Int64.max) else { return nil }
            return Int64(value)
        case let value as NSNumber:
            return int64NumberValue(value)
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private static func int64NumberValue(_ value: NSNumber) -> Int64? {
        guard !isBooleanNumber(value) else { return nil }

        switch String(cString: value.objCType) {
        case "c", "i", "s", "l", "q":
            return value.int64Value
        case "C", "I", "S", "L", "Q":
            let uintValue = value.uint64Value
            guard uintValue <= UInt64(Int64.max) else { return nil }
            return Int64(uintValue)
        case "f", "d":
            return Int64(exactly: value.doubleValue)
        default:
            return nil
        }
    }

    private static func isBooleanNumber(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            if isBooleanNumber(value) {
                return value.boolValue
            }
            guard let numericValue = int64NumberValue(value),
                  numericValue == 0 || numericValue == 1 else {
                return nil
            }
            return numericValue == 1
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSString:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

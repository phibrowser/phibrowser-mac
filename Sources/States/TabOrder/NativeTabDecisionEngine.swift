import Foundation

enum NativeTabCreationKind: String, Equatable {
    case linkForeground
    case linkBackground
    case typedNewTab
    case typedNavigation
    case explicitInsert
    case moveFromOtherWindow
    case restore
    case bridgeCreate
    case unknown
}

struct NativeTabCreationContext: Equatable {
    var isActiveAtCreation: Bool
    var creationKind: NativeTabCreationKind
    var openerTabId: Int?
    var insertAfterTabId: Int?
    var sourceTabId: Int?
    var resetOpenerOnActiveTabChange: Bool
    var didForgetAllOpenersBeforeCreate: Bool

    init(
        isActiveAtCreation: Bool = false,
        creationKind: NativeTabCreationKind = .unknown,
        openerTabId: Int? = nil,
        insertAfterTabId: Int? = nil,
        sourceTabId: Int? = nil,
        resetOpenerOnActiveTabChange: Bool = false,
        didForgetAllOpenersBeforeCreate: Bool = false
    ) {
        self.isActiveAtCreation = isActiveAtCreation
        self.creationKind = creationKind
        self.openerTabId = openerTabId
        self.insertAfterTabId = insertAfterTabId
        self.sourceTabId = sourceTabId
        self.resetOpenerOnActiveTabChange = resetOpenerOnActiveTabChange
        self.didForgetAllOpenersBeforeCreate = didForgetAllOpenersBeforeCreate
    }

    init(dictionary: [AnyHashable: Any]) {
        self.init(
            isActiveAtCreation: Self.boolValue(dictionary["isActiveAtCreation"]),
            creationKind: NativeTabCreationKind(rawValue: dictionary["creationKind"] as? String ?? "") ?? .unknown,
            openerTabId: Self.intValue(dictionary["openerTabId"]),
            insertAfterTabId: Self.intValue(dictionary["insertAfterTabId"]),
            sourceTabId: Self.intValue(dictionary["sourceTabId"]),
            resetOpenerOnActiveTabChange: Self.boolValue(dictionary["resetOpenerOnActiveTabChange"]),
            didForgetAllOpenersBeforeCreate: Self.boolValue(dictionary["didForgetAllOpenersBeforeCreate"])
        )
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        case is NSNull, nil:
            return nil
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return false
        }
    }
}

struct NativeTabRelationshipSnapshot: Equatable {
    let windowId: Int
    let version: Int64
    let allTabIds: Set<Int>
    let openerByTabId: [Int: Int?]
    let tabsWithExplicitNilOpener: Set<Int>
    let resetOnActiveChangeTabIds: Set<Int>

    init?(
        dictionary: [AnyHashable: Any],
        fallbackWindowId: Int
    ) {
        let windowId = NativeTabCreationContext.intValue(dictionary["windowId"]) ?? fallbackWindowId
        guard let version = Self.int64Value(dictionary["version"]) else {
            return nil
        }

        let allTabIds = Self.parseTabIds(dictionary["openerByTabId"])
        let openerPayload = Self.parseOpenerPayload(dictionary["openerByTabId"])
        let resetOnActiveChangeTabIds = Self.parseIntSet(dictionary["resetOnActiveChangeTabIds"])

        self.windowId = windowId
        self.version = version
        self.allTabIds = allTabIds
        self.openerByTabId = openerPayload.openerByTabId
        self.tabsWithExplicitNilOpener = openerPayload.tabsWithExplicitNilOpener
        self.resetOnActiveChangeTabIds = resetOnActiveChangeTabIds
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let int as Int64:
            return int
        case let int as Int:
            return Int64(int)
        case let number as NSNumber:
            return number.int64Value
        default:
            return nil
        }
    }

    private static func parseIntSet(_ value: Any?) -> Set<Int> {
        guard let array = value as? [Any] else {
            return []
        }
        return Set(array.compactMap { NativeTabCreationContext.intValue($0) })
    }

    private static func parseTabIds(_ value: Any?) -> Set<Int> {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return []
        }

        return Set(dictionary.keys.compactMap { key in
            NativeTabCreationContext.intValue(key) ?? Int(String(describing: key))
        })
    }

    private static func parseOpenerPayload(_ value: Any?) -> (
        openerByTabId: [Int: Int?],
        tabsWithExplicitNilOpener: Set<Int>
    ) {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return ([:], [])
        }

        var result: [Int: Int] = [:]
        var tabsWithExplicitNilOpener: Set<Int> = []
        for (key, value) in dictionary {
            guard let tabId = NativeTabCreationContext.intValue(key) ?? Int(String(describing: key)) else {
                continue
            }
            if value is NSNull {
                tabsWithExplicitNilOpener.insert(tabId)
                continue
            }
            result[tabId] = NativeTabCreationContext.intValue(value)
        }
        return (result, tabsWithExplicitNilOpener)
    }
}

struct NativeTabRelationGraph: Equatable {
    var knownTabIds: Set<Int>
    var openerByTabId: [Int: Int]
    var resetOnActiveChangeTabIds: Set<Int>
    var version: Int64
    /// Tabs whose opener was locally re-parented by `fixOpenersAfterMovingTab`.
    /// Prevents Chromium snapshots from reverting the fix when the move
    /// happened only on the Mac side (e.g. drag reorder in native tab order).
    var locallyFixedOpenerTabIds: Set<Int>

    static let empty = NativeTabRelationGraph(knownTabIds: [], openerByTabId: [:], resetOnActiveChangeTabIds: [], version: 0)

    init(
        knownTabIds: Set<Int> = [],
        openerByTabId: [Int: Int] = [:],
        resetOnActiveChangeTabIds: Set<Int> = [],
        version: Int64 = 0,
        locallyFixedOpenerTabIds: Set<Int> = []
    ) {
        self.knownTabIds = knownTabIds
        self.openerByTabId = openerByTabId
        self.resetOnActiveChangeTabIds = resetOnActiveChangeTabIds
        self.version = version
        self.locallyFixedOpenerTabIds = locallyFixedOpenerTabIds
    }

    init(snapshot: NativeTabRelationshipSnapshot) {
        self.knownTabIds = snapshot.allTabIds
        self.openerByTabId = snapshot.openerByTabId.compactMapValues { $0 }
        self.resetOnActiveChangeTabIds = snapshot.resetOnActiveChangeTabIds
        self.version = snapshot.version
        self.locallyFixedOpenerTabIds = []
    }

    mutating func apply(snapshot: NativeTabRelationshipSnapshot) {
        guard snapshot.version >= version else { return }
        let snapshotTabIds = snapshot.allTabIds
        var mergedOpeners: [Int: Int] = [:]

        for tabId in snapshotTabIds {
            if locallyFixedOpenerTabIds.contains(tabId) {
                if snapshot.tabsWithExplicitNilOpener.contains(tabId) {
                    continue
                }
                if let localOpener = openerByTabId[tabId],
                   snapshotTabIds.contains(localOpener) {
                    mergedOpeners[tabId] = localOpener
                }
                continue
            }

            if let openerTabId = snapshot.openerByTabId[tabId] ?? nil,
               snapshotTabIds.contains(openerTabId) {
                mergedOpeners[tabId] = openerTabId
                continue
            }

            if snapshot.tabsWithExplicitNilOpener.contains(tabId) {
                continue
            }

            if knownTabIds.contains(tabId),
               let openerTabId = openerByTabId[tabId],
               snapshotTabIds.contains(openerTabId) {
                mergedOpeners[tabId] = openerTabId
            }
        }

        knownTabIds = snapshotTabIds
        openerByTabId = mergedOpeners
        let preservedResetTabIds = resetOnActiveChangeTabIds.intersection(snapshotTabIds)
        resetOnActiveChangeTabIds =
            preservedResetTabIds.union(snapshot.resetOnActiveChangeTabIds)
        version = snapshot.version
        locallyFixedOpenerTabIds = locallyFixedOpenerTabIds
            .intersection(snapshotTabIds)
            .subtracting(snapshot.tabsWithExplicitNilOpener)
    }

    mutating func applyOptimisticCreation(tabId: Int, context: NativeTabCreationContext?) {
        knownTabIds.insert(tabId)
        guard let context else { return }
        if let openerTabId = context.openerTabId {
            openerByTabId[tabId] = openerTabId
        } else {
            openerByTabId.removeValue(forKey: tabId)
        }

        if context.resetOpenerOnActiveTabChange {
            resetOnActiveChangeTabIds.insert(tabId)
        } else {
            resetOnActiveChangeTabIds.remove(tabId)
        }
    }

    func directChildren(of tabId: Int) -> [Int] {
        openerByTabId.compactMap { childId, openerTabId in
            openerTabId == tabId ? childId : nil
        }
    }

    mutating func fixOpenersAfterMovingTab(_ movedTabId: Int) {
        let newOpenerTabId = openerByTabId[movedTabId]
        let childTabIds = directChildren(of: movedTabId)

        for childTabId in childTabIds {
            if let newOpenerTabId, newOpenerTabId != childTabId {
                openerByTabId[childTabId] = newOpenerTabId
            } else {
                openerByTabId.removeValue(forKey: childTabId)
            }
        }

        if openerByTabId[movedTabId] == movedTabId {
            openerByTabId.removeValue(forKey: movedTabId)
        }
    }

    func fixingOpenersAfterMovingTab(_ movedTabId: Int) -> NativeTabRelationGraph {
        var graph = self
        graph.fixOpenersAfterMovingTab(movedTabId)
        return graph
    }

    mutating func forgetOpenerOnActiveTabChange(from previousActiveTabId: Int, to newActiveTabId: Int) {
        guard previousActiveTabId != newActiveTabId else { return }
        guard resetOnActiveChangeTabIds.contains(previousActiveTabId) else { return }
        AppLogDebug(
            "[NativeTab] forgetOpenerOnActiveTabChange previous=\(previousActiveTabId) " +
            "new=\(newActiveTabId) oldOpener=\(openerByTabId[previousActiveTabId].map(String.init) ?? "nil")"
        )
        openerByTabId.removeValue(forKey: previousActiveTabId)
        resetOnActiveChangeTabIds.remove(previousActiveTabId)
    }

    mutating func removeTab(_ tabId: Int) {
        knownTabIds.remove(tabId)
        openerByTabId.removeValue(forKey: tabId)
        resetOnActiveChangeTabIds.remove(tabId)
        locallyFixedOpenerTabIds.remove(tabId)
    }
}

struct NativePendingSelectionOverride: Equatable {
    let closingTabId: Int
    let targetTabId: Int
    let relationVersion: Int64
}

enum NativeTabDecisionEngine {
    static func insertionIndex(
        visibleNormalTabIds: [Int],
        context: NativeTabCreationContext?,
        relationGraph: NativeTabRelationGraph
    ) -> Int? {
        let creationKindText = context?.creationKind.rawValue ?? "nil"
        let isActiveText = context?.isActiveAtCreation.description ?? "nil"
        let openerText = context?.openerTabId.map(String.init) ?? "nil"
        let insertAfterText = context?.insertAfterTabId.map(String.init) ?? "nil"
        let sourceText = context?.sourceTabId.map(String.init) ?? "nil"
        let resetOnActiveText = context?.resetOpenerOnActiveTabChange.description ?? "nil"
        let resetTabIds = Array(relationGraph.resetOnActiveChangeTabIds).sorted()
        AppLogDebug(
            "[NativeTab] insertionIndex visible=\(visibleNormalTabIds) " +
            "context={kind=\(creationKindText), active=\(isActiveText), opener=\(openerText), " +
            "insertAfter=\(insertAfterText), source=\(sourceText), resetOnActive=\(resetOnActiveText)} " +
            "graph={openers=\(relationGraph.openerByTabId), reset=\(resetTabIds)}"
        )
        guard !visibleNormalTabIds.isEmpty else { return 0 }
        guard let context else { return nil }

        switch context.creationKind {
        case .linkForeground:
            if let openerTabId = context.openerTabId,
               let openerIndex = visibleNormalTabIds.firstIndex(of: openerTabId) {
                AppLogDebug(
                    "[NativeTab] insertionIndex chose foreground opener=\(openerTabId) " +
                    "openerIndex=\(openerIndex) result=\(openerIndex + 1)"
                )
                return openerIndex + 1
            }
            if let insertAfterTabId = context.insertAfterTabId,
               let anchorIndex = visibleNormalTabIds.firstIndex(of: insertAfterTabId) {
                AppLogDebug(
                    "[NativeTab] insertionIndex foreground fallback insertAfterTabId=\(insertAfterTabId) " +
                    "anchorIndex=\(anchorIndex) result=\(anchorIndex + 1)"
                )
                return anchorIndex + 1
            }
        case .linkBackground:
            if let openerTabId = context.openerTabId,
               let openerIndex = visibleNormalTabIds.firstIndex(of: openerTabId) {
                let result = lastVisibleDescendantInsertionIndex(
                    openerTabId: openerTabId,
                    openerIndex: openerIndex,
                    visibleNormalTabIds: visibleNormalTabIds,
                    relationGraph: relationGraph
                )
                AppLogDebug(
                    "[NativeTab] insertionIndex chose background opener=\(openerTabId) " +
                    "openerIndex=\(openerIndex) result=\(result)"
                )
                return result
            }
            if let insertAfterTabId = context.insertAfterTabId,
               let anchorIndex = visibleNormalTabIds.firstIndex(of: insertAfterTabId) {
                AppLogDebug(
                    "[NativeTab] insertionIndex background fallback insertAfterTabId=\(insertAfterTabId) " +
                    "anchorIndex=\(anchorIndex) result=\(anchorIndex + 1)"
                )
                return anchorIndex + 1
            }
        case .typedNewTab, .typedNavigation:
            AppLogDebug(
                "[NativeTab] insertionIndex chose append for kind=\(context.creationKind.rawValue) " +
                "result=\(visibleNormalTabIds.count)"
            )
            return visibleNormalTabIds.count
        case .explicitInsert, .moveFromOtherWindow, .restore, .bridgeCreate, .unknown:
            if let insertAfterTabId = context.insertAfterTabId,
               let anchorIndex = visibleNormalTabIds.firstIndex(of: insertAfterTabId) {
                AppLogDebug(
                    "[NativeTab] insertionIndex chose explicit insertAfterTabId=\(insertAfterTabId) " +
                    "anchorIndex=\(anchorIndex) result=\(anchorIndex + 1)"
                )
                return anchorIndex + 1
            }
        }

        AppLogDebug("[NativeTab] insertionIndex returned nil")
        return nil
    }

    static func selectionTarget(
        visibleNormalTabIds: [Int],
        closingTabId: Int,
        relationGraph: NativeTabRelationGraph
    ) -> Int? {
        guard let closingIndex = visibleNormalTabIds.firstIndex(of: closingTabId) else {
            return nil
        }

        if let child = directionalMatch(
            around: closingIndex,
            visibleNormalTabIds: visibleNormalTabIds,
            matches: { relationGraph.openerByTabId[$0] == closingTabId }
        ) {
            return child
        }

        if let openerTabId = relationGraph.openerByTabId[closingTabId],
           let sibling = directionalMatch(
                around: closingIndex,
                visibleNormalTabIds: visibleNormalTabIds,
                matches: { $0 != closingTabId && relationGraph.openerByTabId[$0] == openerTabId }
           ) {
            return sibling
        }

        if let openerTabId = relationGraph.openerByTabId[closingTabId],
           visibleNormalTabIds.contains(openerTabId) {
            return openerTabId
        }

        if closingIndex + 1 < visibleNormalTabIds.count {
            return visibleNormalTabIds[closingIndex + 1]
        }

        if closingIndex > 0 {
            return visibleNormalTabIds[closingIndex - 1]
        }

        return nil
    }

    private static func lastVisibleDescendantInsertionIndex(
        openerTabId: Int,
        openerIndex: Int,
        visibleNormalTabIds: [Int],
        relationGraph: NativeTabRelationGraph
    ) -> Int {
        var insertAfterIndex = openerIndex
        for (index, tabId) in visibleNormalTabIds.enumerated() where index > openerIndex {
            if isDescendant(tabId, of: openerTabId, relationGraph: relationGraph) {
                insertAfterIndex = index
            }
        }
        return insertAfterIndex + 1
    }

    private static func directionalMatch(
        around index: Int,
        visibleNormalTabIds: [Int],
        matches: (Int) -> Bool
    ) -> Int? {
        if index + 1 < visibleNormalTabIds.count {
            for candidate in visibleNormalTabIds[(index + 1)...] where matches(candidate) {
                return candidate
            }
        }

        if index > 0 {
            for candidate in visibleNormalTabIds[..<index].reversed() where matches(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func isDescendant(
        _ tabId: Int,
        of ancestorTabId: Int,
        relationGraph: NativeTabRelationGraph
    ) -> Bool {
        var current = relationGraph.openerByTabId[tabId]
        var visited = Set<Int>()

        while let opener = current, visited.insert(opener).inserted {
            if opener == ancestorTabId {
                return true
            }
            current = relationGraph.openerByTabId[opener]
        }

        return false
    }
}

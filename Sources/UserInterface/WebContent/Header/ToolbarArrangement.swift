// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum ToolbarZone: String, Codable, CaseIterable {
    case left, addressLeading, addressTrailing, right

    var isAddress: Bool {
        self == .addressLeading || self == .addressTrailing
    }
}

enum ToolbarItemID: Hashable {
    case sidebarToggle, back, forward, reload
    case extensionsButton, downloads, memory, feedback, chat
    case readerView, siteMemories, copyURL, siteMenu
    case extensionAction(String)

    private static let extensionPrefix = "extension:"

    private static let fixedItems: [String: ToolbarItemID] = [
        "sidebarToggle": .sidebarToggle, "back": .back, "forward": .forward, "reload": .reload,
        "extensionsButton": .extensionsButton, "downloads": .downloads, "memory": .memory,
        "feedback": .feedback, "chat": .chat, "readerView": .readerView,
        "siteMemories": .siteMemories, "copyURL": .copyURL, "siteMenu": .siteMenu,
    ]

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.extensionPrefix) {
            self = .extensionAction(String(rawValue.dropFirst(Self.extensionPrefix.count)))
        } else if let item = Self.fixedItems[rawValue] {
            self = item
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .extensionAction(let id): return Self.extensionPrefix + id
        default: return Self.fixedItems.first { $0.value == self }!.key
        }
    }

    var allowedZones: Set<ToolbarZone> {
        self == .chat ? [.left, .right] : Set(ToolbarZone.allCases)
    }
}

enum ToolbarItemVisibility: String, Codable {
    case always, onHover
}

struct ToolbarPlacement: Equatable, Codable {
    var item: ToolbarItemID
    var visibility: ToolbarItemVisibility

    private enum CodingKeys: String, CodingKey { case item, visibility }

    init(item: ToolbarItemID, visibility: ToolbarItemVisibility) {
        self.item = item
        self.visibility = visibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .item)
        guard let item = ToolbarItemID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .item, in: container, debugDescription: "Unknown toolbar item \(raw)")
        }
        self.item = item
        self.visibility = try container.decode(ToolbarItemVisibility.self, forKey: .visibility)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item.rawValue, forKey: .item)
        try container.encode(visibility, forKey: .visibility)
    }
}

enum AddressBarStyle: String, Codable {
    case standard, minimal
}

/// Where each toolbar item sits. An item appears in at most one zone.
/// Only the address zones honor `onHover`; side zones are always visible.
struct ToolbarArrangement: Equatable, Codable {
    var addressBarStyle: AddressBarStyle
    /// Whether the address bar sits between Left and Right. While it is
    /// removed, the address zones keep their placements, so adding it back
    /// brings its buttons back too.
    var showsAddressBar: Bool
    private var zones: [ToolbarZone: [ToolbarPlacement]]
    /// Items the user dropped or moved while customizing, as opposed to
    /// items placed by the default set or the migration. Balanced shows
    /// Downloads, Memory and Feedback with the sidebar docked only when
    /// they are marked here (`WebContentHeaderState.layoutShowsBottomBarItem`).
    private var userPlacedItems: Set<ToolbarItemID> = []

    static let standard = ToolbarArrangement(
        addressBarStyle: .standard,
        showsAddressBar: true,
        zones: [
            .left: [.sidebarToggle, .back, .forward, .reload].map { ToolbarPlacement(item: $0, visibility: .always) },
            .addressLeading: [],
            .addressTrailing: [.readerView, .siteMemories, .copyURL, .siteMenu].map { ToolbarPlacement(item: $0, visibility: .onHover) },
            .right: [.extensionsButton, .memory, .downloads, .feedback, .chat].map { ToolbarPlacement(item: $0, visibility: .always) },
        ]
    )

    func placements(in zone: ToolbarZone) -> [ToolbarPlacement] {
        zones[zone] ?? []
    }

    func zone(of item: ToolbarItemID) -> ToolbarZone? {
        ToolbarZone.allCases.first { placements(in: $0).contains { $0.item == item } }
    }

    /// Whether the user dropped or moved the item while customizing.
    func isPlacedByUser(_ item: ToolbarItemID) -> Bool {
        userPlacedItems.contains(item)
    }

    /// Moves the item to `zone` at `index` (clamped to the end). Returns false if the item is not allowed there.
    /// `byUser` marks it as placed by the user (`isPlacedByUser`); a mark it already has is kept either way.
    @discardableResult
    mutating func place(_ item: ToolbarItemID, in zone: ToolbarZone, at index: Int, byUser: Bool = false) -> Bool {
        guard item.allowedZones.contains(zone) else { return false }
        let previous = placement(of: item)
        removePlacement(of: item)
        if byUser { userPlacedItems.insert(item) }

        let visibility: ToolbarItemVisibility
        if !zone.isAddress {
            visibility = .always
        } else if let previous, previous.zone.isAddress {
            visibility = previous.placement.visibility
        } else {
            visibility = .onHover
        }

        var list = placements(in: zone)
        list.insert(ToolbarPlacement(item: item, visibility: visibility), at: min(max(index, 0), list.count))
        zones[zone] = list
        return true
    }

    /// Takes the item out of the toolbar, with its user-placed mark.
    mutating func remove(_ item: ToolbarItemID) {
        removePlacement(of: item)
        userPlacedItems.remove(item)
    }

    private mutating func removePlacement(of item: ToolbarItemID) {
        for zone in ToolbarZone.allCases {
            zones[zone]?.removeAll { $0.item == item }
        }
    }

    /// Puts `items` into the slots they hold, in the given order: a run of
    /// adjacent extensions reordered in place. Each keeps its own visibility;
    /// items that are not placed are ignored.
    mutating func reorder(_ items: [ToolbarItemID]) {
        let placed = items.filter { zone(of: $0) != nil }
        var slots: [(zone: ToolbarZone, index: Int)] = []
        var byItem: [ToolbarItemID: ToolbarPlacement] = [:]
        for zone in ToolbarZone.allCases {
            for (index, placement) in placements(in: zone).enumerated() where placed.contains(placement.item) {
                slots.append((zone, index))
                byItem[placement.item] = placement
            }
        }
        for (slot, item) in zip(slots, placed) {
            guard var placement = byItem[item] else { continue }
            if !slot.zone.isAddress { placement.visibility = .always }
            zones[slot.zone]?[slot.index] = placement
        }
    }

    mutating func setVisibility(_ visibility: ToolbarItemVisibility, for item: ToolbarItemID) {
        guard let current = placement(of: item), current.zone.isAddress,
              let index = zones[current.zone]?.firstIndex(where: { $0.item == item }) else { return }
        zones[current.zone]?[index].visibility = visibility
    }

    private func placement(of item: ToolbarItemID) -> (zone: ToolbarZone, placement: ToolbarPlacement)? {
        for zone in ToolbarZone.allCases {
            if let found = placements(in: zone).first(where: { $0.item == item }) {
                return (zone, found)
            }
        }
        return nil
    }

    private init(addressBarStyle: AddressBarStyle, showsAddressBar: Bool, zones: [ToolbarZone: [ToolbarPlacement]]) {
        self.addressBarStyle = addressBarStyle
        self.showsAddressBar = showsAddressBar
        self.zones = zones
    }

    private enum CodingKeys: String, CodingKey { case addressBarStyle, showsAddressBar, zones, placedByUser }

    /// Decodes one array element, turning an unknown item into nil instead of failing the whole array.
    private struct Lossy: Decodable {
        let placement: ToolbarPlacement?
        init(from decoder: Decoder) throws {
            placement = try? ToolbarPlacement(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A style from a later build reads as Standard instead of losing the arrangement.
        addressBarStyle = (try? container.decode(AddressBarStyle.self, forKey: .addressBarStyle)) ?? .standard
        // Saved before the address bar could be removed: it is shown.
        showsAddressBar = (try? container.decodeIfPresent(Bool.self, forKey: .showsAddressBar)) ?? true
        let raw = try container.decode([String: [Lossy]].self, forKey: .zones)

        var seen = Set<ToolbarItemID>()
        zones = [:]
        for zone in ToolbarZone.allCases {
            zones[zone] = (raw[zone.rawValue] ?? []).compactMap(\.placement).filter {
                $0.item.allowedZones.contains(zone) && seen.insert($0.item).inserted
            }
        }
        // Saved before the mark existed: nothing was placed by the user.
        // Unknown and unplaced items are dropped.
        let placedByUser = (try? container.decodeIfPresent([String].self, forKey: .placedByUser)) ?? []
        userPlacedItems = Set(placedByUser.compactMap(ToolbarItemID.init(rawValue:))).intersection(seen)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(addressBarStyle, forKey: .addressBarStyle)
        try container.encode(showsAddressBar, forKey: .showsAddressBar)
        var raw: [String: [ToolbarPlacement]] = [:]
        for zone in ToolbarZone.allCases { raw[zone.rawValue] = placements(in: zone) }
        try container.encode(raw, forKey: .zones)
        try container.encode(userPlacedItems.map(\.rawValue).sorted(), forKey: .placedByUser)
    }
}

extension PhiPreferences.GeneralSettings {
    static let toolbarArrangementKey = "toolbarArrangement"

    /// Loads the saved arrangement. On first load the old comfortable-layout switches are
    /// converted into an arrangement, which is saved and from then on the only source.
    static func loadToolbarArrangement(from defaults: UserDefaults = .standard) -> ToolbarArrangement {
        if let data = defaults.data(forKey: toolbarArrangementKey) {
            return (try? JSONDecoder().decode(ToolbarArrangement.self, from: data)) ?? .standard
        }
        var arrangement = ToolbarArrangement.standard
        let legacy: [(PhiPreferences.GeneralSettings, ToolbarItemID)] = [
            (.topBarShowsDownloads, .downloads),
            (.topBarShowsMemory, .memory),
            (.topBarShowsFeedback, .feedback),
        ]
        for (setting, item) in legacy where !setting.loadValue(from: defaults) {
            arrangement.remove(item)
        }
        saveToolbarArrangement(arrangement, to: defaults)
        return arrangement
    }

    /// Whether there is a saved arrangement this build cannot read. It is
    /// drawn as the standard one but must not be written over on its own.
    static func hasUnreadableToolbarArrangement(in defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: toolbarArrangementKey) else { return false }
        return (try? JSONDecoder().decode(ToolbarArrangement.self, from: data)) == nil
    }

    static func saveToolbarArrangement(_ arrangement: ToolbarArrangement, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(arrangement) else { return }
        defaults.set(data, forKey: toolbarArrangementKey)
    }
}

extension ToolbarArrangement {
    /// Keeps placed extensions in step with Chromium's pinned set. Extensions with a pin still
    /// in flight are kept so a drag that pins one does not lose its placement.
    func reconciled(pinnedExtensionIDs: [String], pendingPinIDs: Set<String>) -> ToolbarArrangement {
        var result = self
        let keep = Set(pinnedExtensionIDs).union(pendingPinIDs)
        for zone in ToolbarZone.allCases {
            for placement in placements(in: zone) {
                if case .extensionAction(let id) = placement.item, !keep.contains(id) {
                    result.remove(placement.item)
                }
            }
        }

        let right = result.placements(in: .right)
        var insertAt = (right.lastIndex { if case .extensionAction = $0.item { return true } else { return false } }).map { $0 + 1 } ?? 0
        for id in pinnedExtensionIDs where result.zone(of: .extensionAction(id)) == nil {
            result.place(.extensionAction(id), in: .right, at: insertAt)
            insertAt += 1
        }
        return result
    }
}

extension ToolbarArrangement {
    /// What a window stores after it reconciles: its newly pinned extensions are added, but
    /// nothing is taken out. Windows of other profiles, incognito windows and windows whose
    /// extensions have not loaded yet each see a different pinned set; storing their removals
    /// would make them undo each other forever. Removal only applies to what is drawn.
    func addingNewPins(_ pinnedExtensionIDs: [String]) -> ToolbarArrangement {
        let placed = ToolbarZone.allCases.flatMap { placements(in: $0) }.compactMap { placement -> String? in
            if case .extensionAction(let id) = placement.item { return id }
            return nil
        }
        return reconciled(pinnedExtensionIDs: pinnedExtensionIDs, pendingPinIDs: Set(placed))
    }
}

extension ToolbarArrangement {
    /// Whether the address zones are drawn: wherever the address bar is
    /// shown, in either style. Minimal draws them around its centered address.
    var drawsAddressZones: Bool {
        showsAddressBar
    }
}

extension ToolbarArrangement {
    /// Whether the Site Memories button has a place it is drawn in: a side
    /// zone, or an address zone while those are drawn (`drawsAddressZones`).
    /// Otherwise the Site Menu offers Site Memories in its place.
    var showsSiteMemoriesButton: Bool {
        guard let zone = zone(of: .siteMemories) else { return false }
        return !zone.isAddress || drawsAddressZones
    }
}

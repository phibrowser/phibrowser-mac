// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
final class ArcDataParserTool {
    private static func log(_ message: String) {
        AppLogDebug(message)
    }
    /// Parse StorableSidebar.json and return Space-rooted Bookmark trees in
    /// Arc's own sidebar order, plus each profile's Arc Favorites.
    static func parse(data: Data) throws -> ArcSidebar {
        let arc = try JSONDecoder().decode(ArcRoot.self, from: data)

        let containerEntries = arc.sidebar.containers.flatMap { $0.items ?? [] }
        log("sidebarSyncState.items=\(arc.sidebarSyncState.items.count) sidebar.containers.items=\(containerEntries.count)")

        let sidebarItems = buildSidebarItemMap(
            syncEntries: arc.sidebarSyncState.items,
            overrideEntries: containerEntries
        )
        let bookmarkMap = createBookmarks(from: sidebarItems)
        linkTree(byChildrenOrder: sidebarItems, bookmarks: bookmarkMap)

        let containerSpaceModels = extractSpaceModels(
            from: arc.sidebar.containers.flatMap { $0.spaces ?? [] })
        let syncSpaceModels = arc.sidebarSyncState.spaceModels
            .map { extractSpaceModels(from: $0) }
            ?? []
        let spaceModels = !containerSpaceModels.isEmpty
            ? containerSpaceModels
            : syncSpaceModels

        let spaces = buildSpaceRoots(
            spaceModels: spaceModels,
            sidebarItems: sidebarItems,
            bookmarkMap: bookmarkMap
        )
        let favorites = buildFavorites(
            from: arc.sidebar.containers.flatMap { $0.topAppsContainerIDs ?? [] },
            bookmarkMap: bookmarkMap
        )
        return ArcSidebar(spaces: spaces, favorites: favorites)
    }

    // MARK: - Step 1: Build the sidebar item map

    private static func buildSidebarItemMap(
        _ entries: [SidebarItemEntry]
    ) -> [String: SidebarItem] {

        var map: [String: SidebarItem] = [:]
        var currentID: String?

        for entry in entries {
            switch entry {
            case .id(let id):
                currentID = id
            case .object(let wrapper):
                let id = currentID ?? wrapper.value.id
                map[id] = wrapper.value
                currentID = nil
            case .raw(let item):
                let id = currentID ?? item.id
                map[id] = item
                currentID = nil
            }
        }

        return map
    }

    private static func buildSidebarItemMap(
        syncEntries: [SidebarItemEntry],
        overrideEntries: [SidebarItemEntry]
    ) -> [String: SidebarItem] {
        var map = buildSidebarItemMap(syncEntries)
        if !overrideEntries.isEmpty {
            let overrideMap = buildSidebarItemMap(overrideEntries)
            for (id, item) in overrideMap {
                map[id] = item
            }
        }
        return map
    }

    // MARK: - Step 2: Create flat bookmarks

    private static func createBookmarks(
        from items: [String: SidebarItem]
    ) -> [String: Bookmark] {

        var map: [String: Bookmark] = [:]

        for item in items.values {
            let isFolder: Bool
            let title: String
            let url: String?

            switch item.data {
            case .tab(let tab):
                isFolder = false
                title = tab.savedTitle ?? item.title ?? ""
                url = tab.savedURL

            case .list:
                isFolder = true
                title = item.title ?? "Untitled"
                url = nil

            case .container:
                isFolder = true
                title = item.title ?? "Untitled"
                url = nil
            }

            map[item.id] = Bookmark(
                guid: item.id,
                title: title,
                url: url,
                isFolder: isFolder
            )
        }

        return map
    }

    // MARK: - Step 3: Link parent and child relationships

    private static func linkTree(
        byChildrenOrder items: [String: SidebarItem],
        bookmarks: [String: Bookmark]
    ) {
        for b in bookmarks.values {
            b.children.removeAll()
            b.parent = nil
        }

        for parentItem in items.values {
            guard let parentBookmark = bookmarks[parentItem.id] else { continue }

            for childID in parentItem.childrenIds {
                guard let child = bookmarks[childID] else { continue }
                child.parent = parentBookmark
                parentBookmark.children.append(child)
            }
        }
    }

    // MARK: - Step 4: Build Arc space roots

    private static func buildSpaceRoots(
        spaceModels: [SpaceWrapper],
        sidebarItems: [String: SidebarItem],
        bookmarkMap: [String: Bookmark]
    ) -> [ArcSpace] {
        var results: [ArcSpace] = []

        for space in spaceModels {
            let trimmed = space.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (trimmed?.isEmpty == false ? trimmed : nil)
                ?? NSLocalizedString("oobe.importBrowserData.arc.untitledSpaceName", value: "Untitled Space",
                                     comment: "Arc import - fallback name for an Arc Space with no title")

            let spaceRoot = Bookmark(guid: space.id, title: title, url: nil, isFolder: true)

            let containerIDs = resolveSpaceContainerIDs(space: space, sidebarItems: sidebarItems)
            for cid in containerIDs {
                guard let containerBookmark = bookmarkMap[cid] else { continue }
                for child in containerBookmark.children {
                    if shouldSkipEmptyPlaceholderFolder(child) { continue }
                    if spaceRoot.children.contains(where: { $0.guid == child.guid }) { continue }
                    child.parent = spaceRoot
                    spaceRoot.children.append(child)
                }
            }

            results.append(ArcSpace(
                id: space.id,
                title: title,
                profile: space.profile,
                colorHex: space.colorHex,
                icon: space.icon,
                root: spaceRoot))
        }

        return results
    }

    // MARK: - Step 5: Collect each profile's Arc Favorites

    /// `topAppsContainerIDs` interleaves a profile marker with the id of that
    /// profile's Arc Favorites container: `[marker, id, marker, id, …]`. A
    /// container with no marker (or an unreadable one) is kept as `.unknown`.
    private static func buildFavorites(
        from entries: [TopAppsEntry],
        bookmarkMap: [String: Bookmark]
    ) -> [ArcFavorites] {
        var results: [ArcFavorites] = []
        var currentProfile: ArcSourceProfile?

        for entry in entries {
            switch entry {
            case .profile(let profile):
                currentProfile = profile
            case .containerID(let id):
                let favorites = (bookmarkMap[id]?.children ?? []).compactMap { child -> ArcFavorite? in
                    guard !child.isFolder, let url = child.url else { return nil }
                    return ArcFavorite(title: child.title ?? "", url: url)
                }
                results.append(ArcFavorites(profile: currentProfile ?? .unknown, entries: favorites))
                currentProfile = nil
            }
        }

        return results
    }

    // MARK: - Helpers

    /// Space models in file order; a repeated id keeps its first position and
    /// its last value.
    private static func extractSpaceModels(
        from entries: [SpaceEntry]
    ) -> [SpaceWrapper] {

        var order: [String] = []
        var models: [String: SpaceWrapper] = [:]
        var currentID: String?

        for entry in entries {
            switch entry {
            case .id(let id):
                currentID = id
            case .object(let wrapper):
                let key = wrapper.id.isEmpty
                    ? (currentID ?? UUID().uuidString)
                    : wrapper.id
                if models.updateValue(wrapper, forKey: key) == nil {
                    order.append(key)
                }
                currentID = nil
            }
        }

        return order.compactMap { models[$0] }
    }

    private static func resolveSpaceContainerIDs(
        space: SpaceWrapper,
        sidebarItems: [String: SidebarItem]
    ) -> [String] {
        let idsFromModel = extractPinnedContainerIDs(
            from: space.containerIDs ?? [],
            spaceID: space.id,
            sidebarItems: sidebarItems
        )
        if !idsFromModel.isEmpty {
            return idsFromModel
        }

        return sidebarItems.values.compactMap { item -> String? in
            guard case .container(let refID) = item.data else { return nil }
            guard refID == space.id else { return nil }
            if item.id.lowercased().contains("unpinned") {
                return nil
            }
            return item.id
        }
    }

    private enum SpaceContainerSection {
        case pinned
        case unpinned
        case unspecified
    }

    private static func extractPinnedContainerIDs(
        from containerIDs: [String],
        spaceID: String,
        sidebarItems: [String: SidebarItem]
    ) -> [String] {
        guard !containerIDs.isEmpty else { return [] }

        var results: [String] = []
        var section: SpaceContainerSection = .unspecified

        for id in containerIDs {
            switch id {
            case "pinned":
                section = .pinned
                log("Space \(spaceID) section=pinned")
                continue
            case "unpinned":
                section = .unpinned
                log("Space \(spaceID) section=unpinned")
                continue
            default:
                break
            }

            if section == .unpinned {
                log("Skip unpinned container \(id) for space \(spaceID)")
                continue
            }

            guard let item = sidebarItems[id] else { continue }
            guard case .container(let refID) = item.data, refID == spaceID else { continue }
            results.append(id)
        }

        return results
    }

    private static func shouldSkipEmptyPlaceholderFolder(_ bookmark: Bookmark) -> Bool {
        guard bookmark.isFolder, bookmark.children.isEmpty else { return false }
        let title = (bookmark.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "Folder"
    }
}

/// Everything the sidebar file yields: the Spaces in Arc's sidebar order and
/// each profile's Arc Favorites.
struct ArcSidebar {
    let spaces: [ArcSpace]
    let favorites: [ArcFavorites]
}

/// A parsed Arc Space with its profile binding, colour and bookmark tree root.
struct ArcSpace {
    let id: String
    let title: String
    let profile: ArcSourceProfile
    /// Hex colour derived from the Space's theme; nil when the Space has none,
    /// or one this parser does not read. Kept distinct from a colour so a
    /// consumer can tell "the user chose no colour" from "the user chose this
    /// one" — substituting a default here would make an untitled, unthemed
    /// Arc Space indistinguishable from one deliberately painted that colour.
    let colorHex: String?
    /// The Space's icon as Arc recorded it; nil when it has none, or a record
    /// this parser does not read.
    let icon: ArcSpaceIcon?
    let root: ArcDataParserTool.Bookmark
}

/// An Arc Space's icon as Arc recorded it.
enum ArcSpaceIcon: Equatable {
    /// The emoji text. Older Arc data records only the leading code point;
    /// that arrives as the scalar it names.
    case emoji(String)
    /// One of Arc's built-in icons, by Arc's own name for it (`medical`,
    /// `notifications`).
    case named(String)
}

/// One profile's Arc Favorites (Arc's top-app row), in source order.
struct ArcFavorites {
    let profile: ArcSourceProfile
    let entries: [ArcFavorite]
}

struct ArcFavorite: Equatable {
    let title: String
    let url: String
}

/// Which Chromium profile (under Arc/User Data) an Arc Space uses.
/// `.unknown` = the `profile` field was present but in an unrecognized shape;
/// its `directoryName` is nil so the importer must NOT fall back to Default's data.
enum ArcSourceProfile: Decodable, Equatable {
    case `default`
    case custom(directoryBasename: String)
    case unknown

    var directoryName: String? {
        switch self {
        case .default: return "Default"   // client-side literal; never present in the JSON
        case .custom(let basename): return basename
        case .unknown: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case `default`, custom }
    private struct Custom: Decodable {
        let _0: Inner
        struct Inner: Decodable { let directoryBasename: String }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decodeIfPresent(Bool.self, forKey: .default)) == true {
            self = .default
        } else if let custom = try? c.decode(Custom.self, forKey: .custom) {
            let basename = custom._0.directoryBasename
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A profile dir must be a single, non-empty path component. Empty,
            // whitespace, path separators, or traversal must NOT reach the bridge:
            // Chromium maps an empty profile to Default (wrong-profile data import)
            // and appends the basename to the Arc User Data path without sanitizing
            // (path escape). Map any invalid value to .unknown → directoryName nil →
            // bookmarks-only, never Default.
            if basename.isEmpty
                || basename.contains("/")
                || basename.contains("\\")
                || basename == "."
                || basename == ".." {
                self = .unknown
            } else {
                self = .custom(directoryBasename: basename)
            }
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized Arc profile shape"))
        }
    }
}

extension ArcDataParserTool {
    struct ArcRoot: Decodable {
        let sidebarSyncState: SidebarSyncState
        let sidebar: SidebarSection
    }
    
    struct SidebarSyncState: Decodable {
        let items: [SidebarItemEntry]
        let spaceModels: [SpaceEntry]?
    }

    enum SidebarItemEntry: Decodable {
        case id(String)
        case object(SidebarItemWrapper)
        case raw(SidebarItem)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .id(s)
            } else if let wrapper = try? c.decode(SidebarItemWrapper.self) {
                self = .object(wrapper)
            } else {
                self = .raw(try c.decode(SidebarItem.self))
            }
        }
    }

    struct SidebarItemWrapper: Decodable {
        let value: SidebarItem
    }
    
    struct SidebarItem: Decodable {
        let id: String
        let parentID: String?
        let childrenIds: [String]
        let title: String?
        let data: SidebarItemData
    }
    
    enum SidebarItemData: Decodable {
        case tab(TabData)
        case list
        case container(spaceRefID: String?)

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            if let tab = try? c.decode(TabData.self, forKey: .tab) {
                self = .tab(tab)
                return
            }

            if c.contains(.list) {
                self = .list
                return
            }

            if let container = try? c.decode(ItemContainer.self, forKey: .itemContainer) {
                self = .container(spaceRefID: container.containerType.spaceItems?._0)
                return
            }

            self = .container(spaceRefID: nil)
        }

        enum CodingKeys: String, CodingKey {
            case tab
            case list
            case itemContainer
        }
    }
    
    struct TabData: Decodable {
        let savedURL: String
        let savedTitle: String?
    }
    
    struct ItemContainer: Decodable {
        let containerType: ContainerType
    }

    struct ContainerType: Decodable {
        let spaceItems: SpaceItemsRef?
    }

    struct SpaceItemsRef: Decodable {
        let _0: String
    }
    
    struct SidebarSection: Decodable {
        let containers: [SidebarContainer]
    }

    /// One entry of `sidebar.containers`. The global container carries none
    /// of these keys; the profile-independent one carries all three.
    struct SidebarContainer: Decodable {
        let spaces: [SpaceEntry]?
        let items: [SidebarItemEntry]?
        /// Interleaved `[profile marker, Arc Favorites container id, …]`.
        let topAppsContainerIDs: [TopAppsEntry]?

        private enum CodingKeys: String, CodingKey { case spaces, items, topAppsContainerIDs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spaces = try c.decodeIfPresent([SpaceEntry].self, forKey: .spaces)
            items = try c.decodeIfPresent([SidebarItemEntry].self, forKey: .items)
            // Arc Favorites are read on top of what the import has always read,
            // so a shape this parser does not recognise costs the Favorites and
            // never the Spaces: synthesised decoding would throw here and take
            // the whole sidebar — and with it the Space picker — down with it.
            topAppsContainerIDs = try? c.decode([TopAppsEntry].self, forKey: .topAppsContainerIDs)
        }
    }

    enum TopAppsEntry: Decodable {
        case profile(ArcSourceProfile)
        case containerID(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let id = try? c.decode(String.self) {
                self = .containerID(id)
            } else {
                self = .profile((try? c.decode(ArcSourceProfile.self)) ?? .unknown)
            }
        }
    }
    
    enum SpaceEntry: Decodable {
        case id(String)
        case object(SpaceWrapper)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .id(s)
            } else if let wrapper = try? c.decode(SpaceModelWrapper.self) {
                self = .object(wrapper.value)
            } else {
                self = .object(try c.decode(SpaceWrapper.self))
            }
        }
    }

    struct SpaceModelWrapper: Decodable {
        let value: SpaceWrapper
    }

    struct SpaceWrapper: Decodable {
        let id: String
        let title: String?
        let containerIDs: [String]?
        let profile: ArcSourceProfile
        /// Colour derived from the Space's window theme; nil when it has none
        /// or one this parser does not read.
        let colorHex: String?
        /// The Space's icon; nil when it has none or one this parser does not
        /// read.
        let icon: ArcSpaceIcon?

        private enum CodingKeys: String, CodingKey { case id, title, containerIDs, profile, customInfo }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            containerIDs = (try? c.decode([String].self, forKey: .containerIDs)) ?? []
            if c.contains(.profile) {
                profile = (try? c.decode(ArcSourceProfile.self, forKey: .profile)) ?? .unknown
            } else {
                profile = .default
            }
            let customInfo = try? c.decode(SpaceCustomInfo.self, forKey: .customInfo)
            colorHex = customInfo?.themeColor?.hexRGBString
            icon = customInfo?.iconType?.spaceIcon
        }
    }

    /// The slice of a Space's `customInfo` this parser reads: the window
    /// theme's colour and the icon record. Arc encodes its theme enums as
    /// `{ "<case>": { "_0": payload } }`:
    /// `windowTheme.background.single._0.style.color._0` is either
    /// `blendedSingleColor` (one colour) or `blendedGradient` (`baseColors`,
    /// the first one stands for the Space). The two are decoded apart, so a
    /// shape this parser does not recognise costs that one thing — never the
    /// other, and never the Space.
    struct SpaceCustomInfo: Decodable {
        let windowTheme: WindowTheme?
        let iconType: IconType?

        private enum CodingKeys: String, CodingKey { case windowTheme, iconType }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowTheme = try? c.decode(WindowTheme.self, forKey: .windowTheme)
            iconType = try? c.decode(IconType.self, forKey: .iconType)
        }

        struct WindowTheme: Decodable { let background: Background? }
        struct Background: Decodable { let single: Payload<Single>? }
        struct Single: Decodable { let style: Style? }
        struct Style: Decodable { let color: Payload<ColorType>? }
        struct ColorType: Decodable {
            let blendedSingleColor: Payload<BlendedSingleColor>?
            let blendedGradient: Payload<BlendedGradient>?
        }
        struct BlendedSingleColor: Decodable { let color: ThemeColor }
        struct BlendedGradient: Decodable { let baseColors: [ThemeColor] }
        struct Payload<Value: Decodable>: Decodable { let _0: Value }

        var themeColor: ThemeColor? {
            let colorType = windowTheme?.background?.single?._0.style?.color?._0
            return colorType?.blendedSingleColor?._0.color
                ?? colorType?.blendedGradient?._0.baseColors.first
        }

        /// `iconType` on disk is an emoji record — `emoji_v2` is the text and
        /// `emoji`, the older field, its leading code point as an integer — or
        /// a named-icon record (`icon`). The text is preferred; the integer
        /// alone is older Arc data, and the emoji is what it names.
        struct IconType: Decodable {
            let emojiText: String?
            let emojiCodePoint: Int?
            let iconName: String?

            private enum CodingKeys: String, CodingKey {
                case emojiText = "emoji_v2"
                case emojiCodePoint = "emoji"
                case iconName = "icon"
            }

            var spaceIcon: ArcSpaceIcon? {
                if let text = emojiText { return .emoji(text) }
                if let codePoint = emojiCodePoint,
                   let value = UInt32(exactly: codePoint),
                   let scalar = Unicode.Scalar(value) {
                    return .emoji(String(Character(scalar)))
                }
                if let iconName { return .named(iconName) }
                return nil
            }
        }
    }

    /// An Arc theme colour. Components are extended sRGB and may fall outside
    /// 0–1; they are clamped before conversion.
    struct ThemeColor: Decodable {
        let red: Double
        let green: Double
        let blue: Double

        var hexRGBString: String {
            func channel(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
        }
    }
    
    class Bookmark {
        var title: String?
        var guid: String
        var children: [Bookmark]
        var url: String?
        var isFolder: Bool
        var parent: Bookmark? = nil
        init(guid: String, title: String, children: [Bookmark] = [], url: String?, isFolder: Bool) {
            self.title = title
            self.guid = guid
            self.children = children
            self.url = url
            self.isFolder = isFolder
        }
    }
}

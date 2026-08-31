// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Compression
import Foundation

/// Reads what a Zen install keeps on disk: Firefox's `profiles.ini`, and per
/// profile Zen's own session file — its store of spaces and pinned tabs,
/// which is not Firefox's window session beside it. Pure data-in / model-out,
/// the Arc sidebar parser's sibling; the file reads live in
/// `BrowserDataImporter`. Verified against Zen 1.21.15b on 2026-08-30.
enum ZenDataParserTool {
    /// Where Zen keeps its profile directories, under its application-support
    /// directory — the one place the Chromium-side Zen import resolves a
    /// profile.
    static let profilesDirectoryName = "Profiles"
    /// A space's `containerTabId` when it is set to no container: Firefox's
    /// default context, which has no identity of its own.
    static let noContainerID = 0

    // MARK: - profiles.ini

    /// One `[ProfileN]` section of `profiles.ini` whose profile lives where
    /// Zen keeps them: `Profiles/<basename>` under its application-support
    /// directory, the only place the Chromium-side Zen import can resolve. A
    /// profile the user placed elsewhere (`IsRelative=0`, or a relative path
    /// outside `Profiles`) is not listed.
    struct Profile: Equatable {
        /// The section's `Name`; empty when it has none.
        let name: String
        /// The profile directory's basename: the key the Chromium-side Zen
        /// import resolves under Zen's `Profiles` directory.
        let key: String
    }

    struct ProfilesINI: Equatable {
        /// In section order.
        let profiles: [Profile]
        /// The install's default profile: the one the first `[Install…]`
        /// section's `Default=` names, and nil when none does. A profile
        /// section's own `Default=1` is never it — on the design machine that
        /// flag sits on a never-launched profile.
        let defaultProfileKey: String?
    }

    static func parseProfilesINI(_ text: String) -> ProfilesINI {
        var sections: [(name: String, values: [String: String])] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        let profiles = sections.compactMap { section -> Profile? in
            let number = section.name.dropFirst("Profile".count)
            guard section.name.hasPrefix("Profile"), !number.isEmpty,
                  number.allSatisfy(\.isNumber),
                  section.values["IsRelative"] == "1",
                  let key = profilesDirectoryBasename(of: section.values["Path"] ?? "") else {
                return nil
            }
            return Profile(name: section.values["Name"] ?? "", key: key)
        }
        let installDefault = sections.first { $0.name.hasPrefix("Install") }?.values["Default"]
            .flatMap(profilesDirectoryBasename)
        return ProfilesINI(
            profiles: profiles,
            defaultProfileKey: profiles.first { $0.key == installDefault }?.key)
    }

    /// `Profiles/<basename>` → the basename; any other path → nil.
    private static func profilesDirectoryBasename(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == profilesDirectoryName,
              !components[1].isEmpty else {
            return nil
        }
        return String(components[1])
    }

    // MARK: - containers.json

    /// One container a Space can be set to — a Firefox contextual identity,
    /// which is what Zen's own "profile" picker on a space chooses.
    struct Container: Equatable {
        let userContextId: Int
        /// Firefox's own name for one of its four defaults
        /// (`user-context-personal` …), which carry no `name`; nil otherwise.
        let l10nId: String?
        /// A custom container's name as typed; nil for a default.
        let name: String?
    }

    /// The containers a user can set a Space to, in file order — creation
    /// order, so public ids are not contiguous. Left out: Firefox's internal
    /// identities (`public` false — or absent, which Firefox reads the same
    /// way) and, should a file ever carry one, an identity with the id of no
    /// container at all, which would double the no-container Profile.
    static func parseContainers(json: Data) throws -> [Container] {
        let file = try JSONDecoder().decode(ContainersFile.self, from: json)
        return (file.identities ?? [])
            .filter { $0.isPublic == true && $0.userContextId != noContainerID }
            .map { Container(userContextId: $0.userContextId, l10nId: $0.l10nId, name: $0.name) }
    }

    private struct ContainersFile: Decodable {
        let identities: [Identity]?
    }

    private struct Identity: Decodable {
        let userContextId: Int
        let l10nId: String?
        let name: String?
        let isPublic: Bool?

        private enum CodingKeys: String, CodingKey {
            case userContextId, l10nId, name
            case isPublic = "public"
        }
    }

    // MARK: - The Mozilla LZ4 container

    enum SessionFileError: Error, Equatable {
        /// Not `mozLz40\0` at the front, or nothing after the header.
        case notAMozillaLZ4Container
        /// The header's decoded size is zero or past what a session file
        /// could be — a malformed file rather than a large one.
        case declaredSizeOutOfRange(Int)
        /// The block decoded to fewer bytes than the header declares — cut
        /// short, or not a block the decoder could read at all.
        case truncatedOrCorrupt(decoded: Int, declared: Int)
    }

    private static let mozillaLZ4Magic = Array("mozLz40\0".utf8)
    /// The real file decodes to about 300 KB; a header claiming more than
    /// this is not honoured with an allocation.
    private static let maxDeclaredSize = 64 << 20

    /// Unwraps a Mozilla LZ4 container: the magic, the decoded size as a
    /// little-endian 32-bit integer, then one raw LZ4 block — which is what
    /// the platform's raw-LZ4 mode decodes (verified on 2026-08-30 against a
    /// real install's session file). No third-party dependency.
    static func decodeMozillaLZ4(_ container: Data) throws -> Data {
        let bytes = [UInt8](container)
        let headerSize = mozillaLZ4Magic.count + 4
        guard bytes.count > headerSize, bytes.starts(with: mozillaLZ4Magic) else {
            throw SessionFileError.notAMozillaLZ4Container
        }
        let declared = bytes[mozillaLZ4Magic.count..<headerSize]
            .reversed()
            .reduce(0) { $0 << 8 | Int($1) }
        guard declared > 0, declared <= maxDeclaredSize else {
            throw SessionFileError.declaredSizeOutOfRange(declared)
        }
        var decoded = [UInt8](repeating: 0, count: declared)
        let written = bytes[headerSize...].withUnsafeBufferPointer { block in
            compression_decode_buffer(
                &decoded, declared, block.baseAddress!, block.count, nil, COMPRESSION_LZ4_RAW)
        }
        guard written == declared else {
            throw SessionFileError.truncatedOrCorrupt(decoded: written, declared: declared)
        }
        return Data(decoded)
    }

    // MARK: - The session file

    /// The session file's spaces — Zen's workspaces — in array order, which
    /// is their order (the file has no position field); its pinned tabs, in
    /// file order; its folders, the tree those sit in; and its split views.
    struct Session: Equatable {
        let spaces: [Space]
        let pinnedTabs: [PinnedTab]
        let folders: [Folder]
        let splitViews: [SplitView]

        init(
            spaces: [Space], pinnedTabs: [PinnedTab] = [], folders: [Folder] = [],
            splitViews: [SplitView] = []
        ) {
            self.spaces = spaces
            self.pinnedTabs = pinnedTabs
            self.folders = folders
            self.splitViews = splitViews
        }
    }

    /// One pinned tab of the session file: an Essential, or a workspace pin.
    /// Not here: an empty pinned placeholder (`zenIsEmpty`), a Glance tab
    /// (`zenIsGlance`), a tab that is not pinned — Zen writes its open tabs
    /// beside the pins while it runs — and a tab with no URL to read.
    struct PinnedTab: Equatable {
        /// `zenWorkspace`: the space a workspace pin belongs to. An
        /// Essential names one too, which means nothing for it.
        let workspaceID: String?
        /// `zenEssential`: an Essential belongs to its container, not to a
        /// space.
        let isEssential: Bool
        /// `userContextId`: the container the tab is in — the one an
        /// Essential's Profile is derived from; 0 when none.
        let userContextId: Int
        /// `groupId`: the tab group a workspace pin sits in — a folder, or a
        /// split view; nil at the root.
        let groupID: String?
        /// From the pinned-at entry (`_zenPinnedInitialState.entry`, which is
        /// what Zen's own "reset pinned tab" returns to), falling back to the
        /// current session entry when there is none. Empty when the entry
        /// has no title.
        let title: String
        let url: String
        /// `zenSyncId`: what a split view's layout names its panes by; nil
        /// when the tab carries none.
        let syncID: String?
    }

    /// One `folders[]` entry: a Firefox tab group Zen shows as a folder of
    /// pins. `parentId` nests it; its own workspace field is not read — the
    /// pins in it say where it is. A record flagged `splitViewGroup` is not
    /// one: it is a split view placed inside a folder, and read as such.
    struct Folder: Equatable {
        let id: String
        /// Empty when the folder has no name.
        let name: String
        let parentID: String?
    }

    /// One split view: a Firefox tab group of its own that Zen shows two to
    /// four workspace pins in together, whose pins carry its id in `groupId`
    /// as a folder's do. Read from its `splitViewData[]` entry — the
    /// authority for the layout — joined with the `folders[]` record Zen
    /// writes for a split only when it is placed inside a folder (flagged
    /// `splitViewGroup`). A record with no entry, a shape Zen does not
    /// write, is a split with no layout, and so no panes.
    struct SplitView: Equatable {
        let id: String
        /// The folder the split is placed in, from its `folders[]` record;
        /// nil at the root.
        let parentFolderID: String?
        /// The layout root's `direction`: `row` is side by side, `column`
        /// stacked.
        let direction: String?
        /// The top level's panes as their tabs' `zenSyncId`, in layout
        /// order — when every pane is a leaf. A grid of three or four nests
        /// a splitter in a pane, which leaves this nil: Phi's split is a
        /// pair, and only a top level of exactly two leaves can be one.
        let paneTabIDs: [String]?
    }

    struct Space: Equatable {
        /// The space's `uuid` as written, braces included.
        let id: String
        /// A placeholder when the name is empty, as the Arc parser supplies
        /// for an untitled Arc Space.
        let name: String
        /// The theme's primary gradient stop as a hex colour; nil when the
        /// theme has no stops, or none this parser can read — a space with no
        /// colour, not a colour.
        let colorHex: String?
        /// The `userContextId` of the container the space is set to; 0 when
        /// it is set to none.
        let containerTabId: Int
        /// `icon` as written — the emoji text, or a
        /// `chrome://…/zen-icons/selectable/<name>.svg` URL — and nil when the
        /// key is absent, null or empty. Naming the built-in is the adapter's.
        let icon: String?
    }

    static func parseSession(container: Data) throws -> Session {
        try parseSession(json: decodeMozillaLZ4(container))
    }

    static func parseSession(json: Data) throws -> Session {
        let file = try JSONDecoder().decode(SessionFile.self, from: json)
        let spaces = (file.spaces ?? []).map { record -> Space in
            let trimmed = (record.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Space(
                id: record.uuid,
                name: trimmed.isEmpty
                    ? NSLocalizedString("app.browserMigration.zen.untitledSpaceName",
                                        value: "Untitled Space",
                                        comment: "Browser migration wizard - fallback name for a Zen workspace that has no name")
                    : trimmed,
                colorHex: record.theme?.primaryStop?.hexRGBString,
                containerTabId: record.containerTabId ?? noContainerID,
                icon: (record.icon ?? "").isEmpty ? nil : record.icon)
        }
        let pinnedTabs = (file.tabs ?? []).compactMap { record -> PinnedTab? in
            guard record.pinned == true, record.zenIsEmpty != true, record.zenIsGlance != true,
                  let entry = record.entry, let url = entry.url, !url.isEmpty else { return nil }
            return PinnedTab(
                workspaceID: record.zenWorkspace,
                isEssential: record.zenEssential == true,
                userContextId: record.userContextId ?? noContainerID,
                groupID: record.groupId,
                title: entry.title ?? "",
                url: url,
                syncID: record.zenSyncId)
        }
        let folders = (file.folders ?? []).compactMap { record -> Folder? in
            guard let id = record.id, record.splitViewGroup != true else { return nil }
            return Folder(id: id, name: record.name ?? "", parentID: record.parentId)
        }
        // A split placed inside a folder has a `folders[]` record naming
        // that folder; a split at the root has none.
        let splitRecords = Dictionary(
            (file.folders ?? []).compactMap { record in
                record.splitViewGroup == true ? record.id.map { ($0, record) } : nil
            },
            uniquingKeysWith: { first, _ in first })
        var splitViews = (file.splitViewData ?? []).compactMap { record -> SplitView? in
            guard let id = record.groupId else { return nil }
            return SplitView(
                id: id,
                parentFolderID: splitRecords[id]?.parentId,
                direction: record.layoutTree?.direction,
                paneTabIDs: record.layoutTree?.paneTabIDs)
        }
        let laidOut = Set(splitViews.map(\.id))
        for record in file.folders ?? [] where record.splitViewGroup == true {
            guard let id = record.id, !laidOut.contains(id) else { continue }
            splitViews.append(SplitView(
                id: id, parentFolderID: record.parentId, direction: nil, paneTabIDs: nil))
        }
        return Session(
            spaces: spaces, pinnedTabs: pinnedTabs, folders: folders, splitViews: splitViews)
    }

    /// The slice of the file this parser reads. Only `uuid` is required of a
    /// space: its name, icon, theme and container are each decoded apart and
    /// tolerantly, so a shape this parser does not recognise costs that one
    /// thing — a container id that is not a number reads as no container —
    /// never the space, and never the file. A tab, a folder and a split
    /// view are read the same way, and nothing is required of them: a tab
    /// this parser cannot read a URL from is not a pin, a folder with no id
    /// cannot be sat in, a split view with no group id has no pins to name
    /// it, and one whose layout cannot be read has no panes. A file with no
    /// `spaces` at all predates workspaces and simply has none.
    private struct SessionFile: Decodable {
        let spaces: [SpaceRecord]?
        let tabs: [TabRecord]?
        let folders: [FolderRecord]?
        let splitViewData: [SplitViewRecord]?
    }

    private struct SpaceRecord: Decodable {
        let uuid: String
        let name: String?
        let icon: String?
        let theme: Theme?
        let containerTabId: Int?

        private enum CodingKeys: String, CodingKey { case uuid, name, icon, theme, containerTabId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
            theme = try? c.decode(Theme.self, forKey: .theme)
            containerTabId = try? c.decodeIfPresent(Int.self, forKey: .containerTabId)
        }
    }

    private struct Theme: Decodable {
        let gradientColors: [Stop]?

        /// Zen derives every other stop from the one flagged primary, so that
        /// stop is the space's colour; the first stands in when none is
        /// flagged.
        var primaryStop: Stop? {
            gradientColors?.first { $0.isPrimary == true } ?? gradientColors?.first
        }
    }

    /// One gradient stop; `c` is `[r, g, b]` on 0–255. Its other fields —
    /// `lightness` (a number or a string), the algorithm, the position — are
    /// not read.
    private struct Stop: Decodable {
        let c: [Double]
        let isPrimary: Bool?

        var hexRGBString: String? {
            guard c.count >= 3 else { return nil }
            func channel(_ component: Double) -> Int { Int(min(max(component, 0), 255).rounded()) }
            return String(format: "#%02x%02x%02x", channel(c[0]), channel(c[1]), channel(c[2]))
        }
    }

    private struct TabRecord: Decodable {
        let pinned: Bool?
        let zenEssential: Bool?
        let zenIsEmpty: Bool?
        let zenIsGlance: Bool?
        let zenWorkspace: String?
        let groupId: String?
        let userContextId: Int?
        let zenSyncId: String?
        /// `_zenPinnedInitialState.entry`: what the tab showed when it was
        /// pinned.
        let pinnedAt: Entry?
        /// The navigation history, and `index` — one-based — the current
        /// entry in it.
        let entries: [Entry]?
        let index: Int?

        private enum CodingKeys: String, CodingKey {
            case pinned, zenEssential, zenIsEmpty, zenIsGlance, zenWorkspace, groupId, userContextId
            case zenSyncId
            case pinnedAt = "_zenPinnedInitialState"
            case entries, index
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
            zenEssential = try? c.decodeIfPresent(Bool.self, forKey: .zenEssential)
            zenIsEmpty = try? c.decodeIfPresent(Bool.self, forKey: .zenIsEmpty)
            zenIsGlance = try? c.decodeIfPresent(Bool.self, forKey: .zenIsGlance)
            zenWorkspace = try? c.decodeIfPresent(String.self, forKey: .zenWorkspace)
            groupId = try? c.decodeIfPresent(String.self, forKey: .groupId)
            userContextId = try? c.decodeIfPresent(Int.self, forKey: .userContextId)
            zenSyncId = try? c.decodeIfPresent(String.self, forKey: .zenSyncId)
            pinnedAt = (try? c.decodeIfPresent(PinnedInitialState.self, forKey: .pinnedAt))?.entry
            entries = try? c.decodeIfPresent([Entry].self, forKey: .entries)
            index = try? c.decodeIfPresent(Int.self, forKey: .index)
        }

        /// The entry the pin's URL and title are read from: the pinned-at
        /// one when it names a URL, else the current one — the last entry
        /// when `index` is absent or out of range.
        var entry: Entry? {
            if let pinnedAt, !(pinnedAt.url ?? "").isEmpty { return pinnedAt }
            guard let entries, !entries.isEmpty else { return nil }
            let position = (index ?? entries.count) - 1
            return entries.indices.contains(position) ? entries[position] : entries.last
        }
    }

    private struct PinnedInitialState: Decodable {
        let entry: Entry?
    }

    private struct Entry: Decodable {
        let url: String?
        let title: String?
    }

    private struct FolderRecord: Decodable {
        let id: String?
        let name: String?
        let parentId: String?
        let splitViewGroup: Bool?

        private enum CodingKeys: String, CodingKey { case id, name, parentId, splitViewGroup }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
            splitViewGroup = try? c.decodeIfPresent(Bool.self, forKey: .splitViewGroup)
        }
    }

    /// One `splitViewData[]` entry. Its `gridType`, `tabs[]` and the panes'
    /// sizes are not read: the layout tree carries the panes and their
    /// direction.
    private struct SplitViewRecord: Decodable {
        let groupId: String?
        let layoutTree: LayoutNode?

        private enum CodingKeys: String, CodingKey { case groupId, layoutTree }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            groupId = try? c.decodeIfPresent(String.self, forKey: .groupId)
            layoutTree = try? c.decodeIfPresent(LayoutNode.self, forKey: .layoutTree)
        }
    }

    /// One node of a split view's layout tree: a `splitter` with a direction
    /// and children, or a `leaf` naming a tab.
    private struct LayoutNode: Decodable {
        let type: String?
        let direction: String?
        let tabId: String?
        let children: [LayoutNode]?

        private enum CodingKeys: String, CodingKey { case type, direction, tabId, children }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            direction = try? c.decodeIfPresent(String.self, forKey: .direction)
            tabId = try? c.decodeIfPresent(String.self, forKey: .tabId)
            children = try? c.decodeIfPresent([LayoutNode].self, forKey: .children)
        }

        /// The children's tabs, in order, when there are children and every
        /// one is a leaf naming a tab; nil when one is a splitter of its own.
        var paneTabIDs: [String]? {
            guard let children, !children.isEmpty else { return nil }
            let tabIDs = children.compactMap { $0.type == "leaf" ? $0.tabId : nil }
            return tabIDs.count == children.count ? tabIDs : nil
        }
    }
}

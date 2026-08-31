// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Fixtures follow the on-disk `StorableSidebar.json` shape: the profile-
/// independent container carries `spaces` (id / model interleaved), `items`
/// and `topAppsContainerIDs` (profile marker / Arc Favorites container id
/// interleaved). Theme payloads copy a real Arc Space's `customInfo`.
final class ArcDataParserTests: XCTestCase {

    // MARK: - Fixture builders

    private let defaultProfile = #"{"default": true}"#
    private let customProfile = #"{"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "M"}}}"#

    private func sidebar(spaces: [String], items: [String] = [], topApps: String? = nil) -> Data {
        let topAppsField = topApps.map { ", \"topAppsContainerIDs\": \($0)" } ?? ""
        return Data("""
        {
          "sidebarSyncState": { "items": [] },
          "sidebar": { "containers": [ { "global": {} }, {
            "spaces": [ \(spaces.joined(separator: ",\n")) ],
            "items": [ \(items.joined(separator: ",\n")) ]\(topAppsField)
          } ] }
        }
        """.utf8)
    }

    /// One Space model entry (id string followed by the model); `customInfo`
    /// is that key's raw JSON, or absent.
    private func space(
        _ id: String, title: String, profile: String? = nil, containerIDs: [String] = [], customInfo: String? = nil
    ) -> String {
        let customInfoField = customInfo.map { ", \"customInfo\": \($0)" } ?? ""
        let containers = containerIDs.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        "\(id)", { "id": "\(id)", "title": "\(title)", "profile": \(profile ?? defaultProfile), "containerIDs": [\(containers)]\(customInfoField) }
        """
    }

    /// A container item: a Space's pinned section when `spaceID` is given,
    /// otherwise an Arc Favorites (top-apps) container.
    private func container(_ id: String, spaceID: String? = nil, children: [String]) -> String {
        let type = spaceID.map { "{ \"spaceItems\": { \"_0\": \"\($0)\" } }" }
            ?? "{ \"topApps\": { \"_0\": { \"default\": true } } }"
        let childIDs = children.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        { "id": "\(id)", "childrenIds": [\(childIDs)], "data": { "itemContainer": { "containerType": \(type) } } }
        """
    }

    private func tab(_ id: String, title: String, url: String) -> String {
        """
        { "id": "\(id)", "childrenIds": [], "title": "\(title)", "data": { "tab": { "savedURL": "\(url)", "savedTitle": "\(title)" } } }
        """
    }

    /// Captured verbatim from a real Arc Space with a single-colour theme.
    private let capturedSingleColorTheme = """
    { "windowTheme": { "background": { "single": { "_0": {
        "style": { "color": { "_0": { "blendedSingleColor": { "_0": {
          "translucencyStyle": "light",
          "modifiers": { "overlay": "grain", "noiseFactor": 0.5, "intensityFactor": 0.7031872089092548 },
          "color": { "red": 0.9495062232017517, "colorSpace": "extendedSRGB", "alpha": 1, "green": 0.9179275035858154, "blue": 0.8942826390266418 }
        } } } } },
        "contentOverBackgroundAppearance": "light", "isVibrant": true
    } } } } }
    """

    /// Captured verbatim from a real Arc Space with a gradient theme. Its
    /// first base colour has a negative red component, so this fixture also
    /// exercises clamping on real data.
    private let capturedGradientTheme = """
    { "windowTheme": { "background": { "single": { "_0": {
        "contentOverBackgroundAppearance": "light",
        "style": { "color": { "_0": { "blendedGradient": { "_0": {
          "overlayColors": [],
          "translucencyStyle": "light",
          "modifiers": { "noiseFactor": 0, "intensityFactor": 0.7044208233173077, "overlay": "grain" },
          "wheel": { "complimentary": {} },
          "baseColors": [
            { "blue": 0.8139187693595886, "red": -0.38402122259140015, "green": 0.9408406615257263, "colorSpace": "extendedSRGB", "alpha": 1 },
            { "blue": 0.3506702184677124, "red": 1.0061089992523193, "green": 0.15736636519432068, "colorSpace": "extendedSRGB", "alpha": 1 }
          ]
        } } } } },
        "isVibrant": true
    } } } } }
    """

    private func singleColorTheme(
        red: Double, green: Double, blue: Double, iconType: String? = nil
    ) -> String {
        let iconTypeField = iconType.map { "\"iconType\": \($0), " } ?? ""
        return """
        { \(iconTypeField)"windowTheme": { "background": { "single": { "_0": { "style": { "color": { "_0": {
          "blendedSingleColor": { "_0": { "color": { "red": \(red), "green": \(green), "blue": \(blue), "alpha": 1, "colorSpace": "extendedSRGB" } } }
        } } } } } } } }
        """
    }

    private func parse(_ data: Data) throws -> ArcSidebar {
        try ArcDataParserTool.parse(data: data)
    }

    // MARK: - Order

    func testSpacesKeepArcSidebarOrderAcrossProfiles() throws {
        let data = sidebar(spaces: [
            space("S1", title: "Zeta", profile: customProfile),
            space("S2", title: "Alpha"),
            space("S3", title: "Mid", profile: customProfile),
        ])
        XCTAssertEqual(try parse(data).spaces.map(\.title), ["Zeta", "Alpha", "Mid"])
    }

    func testSpaceBookmarksKeepSourceOrder() throws {
        let data = sidebar(
            spaces: [space("S1", title: "Work", containerIDs: ["pinned", "C1"])],
            items: [
                container("C1", spaceID: "S1", children: ["T2", "T1"]),
                tab("T1", title: "Linear", url: "https://linear.app"),
                tab("T2", title: "GitHub", url: "https://github.com"),
            ])
        let root = try XCTUnwrap(try parse(data).spaces.first?.root)
        XCTAssertEqual(root.children.map(\.title), ["GitHub", "Linear"])
    }

    /// `containerIDs` marks a Space's pinned section and its open-tab section
    /// in one list. Only the pinned one is the Space's bookmark tree — ordinary
    /// open tabs are not persistent data and do not migrate.
    func testSpaceBookmarksLeaveOutOpenTabs() throws {
        let data = sidebar(
            spaces: [space("S1", title: "Work",
                           containerIDs: ["pinned", "C1", "unpinned", "C2"])],
            items: [
                container("C1", spaceID: "S1", children: ["T1"]),
                container("C2", spaceID: "S1", children: ["T2"]),
                tab("T1", title: "Linear", url: "https://linear.app"),
                tab("T2", title: "Just Browsing", url: "https://example.com"),
            ])
        let root = try XCTUnwrap(try parse(data).spaces.first?.root)
        XCTAssertEqual(root.children.map(\.title), ["Linear"])
    }

    // MARK: - Color

    func testSingleColorThemeYieldsItsColor() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: capturedSingleColorTheme)])
        XCTAssertEqual(try parse(data).spaces.first?.colorHex, "#f2eae4")
    }

    func testGradientThemeYieldsItsFirstColor() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: capturedGradientTheme)])
        XCTAssertEqual(try parse(data).spaces.first?.colorHex, "#00f0d0")
    }

    /// No theme is an absence, not a colour: substituting the default colour
    /// here would make a Space the user never painted indistinguishable from
    /// one deliberately painted that blue, and a Migration would then snap the
    /// stand-in to whatever hue it happened to have.
    func testNoThemeYieldsNoColor() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: #"{ "iconType": { "emoji": "🧪" } }"#)])
        XCTAssertNil(try parse(data).spaces.first?.colorHex)
    }

    func testOutOfRangeColorComponentsAreClamped() throws {
        let theme = singleColorTheme(red: 1.2, green: -0.1, blue: 0.5)
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: theme)])
        XCTAssertEqual(try parse(data).spaces.first?.colorHex, "#ff0080")
    }

    // MARK: - Icon

    /// Captured verbatim from a real Arc Space: the text, and the leading code
    /// point as an integer — the older field, which Arc still writes.
    private let capturedEmojiIcon = #"{ "iconType": { "emoji_v2": "🏢", "emoji": 127970 } }"#

    func testEmojiIconRecordYieldsItsText() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: capturedEmojiIcon)])
        XCTAssertEqual(try parse(data).spaces.first?.icon, .emoji("🏢"))
    }

    /// The two fields disagree once the emoji is more than one scalar — a skin
    /// tone lives only in the text — so this pins that the text wins.
    func testEmojiIconRecordPrefersTheTextToTheCodePoint() throws {
        let record = #"{ "iconType": { "emoji_v2": "\#u{1F44D}\#u{1F3FB}", "emoji": 128077 } }"#
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: record)])
        XCTAssertEqual(try parse(data).spaces.first?.icon, .emoji("\u{1F44D}\u{1F3FB}"))
    }

    /// Older Arc data records only the code point; the age of an install must
    /// not cost the icon.
    func testEmojiIconRecordWithOnlyTheCodePointYieldsItsScalar() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: #"{ "iconType": { "emoji": 127970 } }"#)])
        XCTAssertEqual(try parse(data).spaces.first?.icon, .emoji("🏢"))
    }

    /// Captured verbatim from a real Arc Space with one of Arc's built-in
    /// icons.
    private let capturedNamedIcon = #"{ "iconType": { "icon": "medical" } }"#

    func testNamedIconRecordYieldsItsName() throws {
        let data = sidebar(spaces: [space("S1", title: "Health", customInfo: capturedNamedIcon)])
        XCTAssertEqual(try parse(data).spaces.first?.icon, .named("medical"))
    }

    func testNoIconRecordYieldsNoIcon() throws {
        let data = sidebar(spaces: [space("S1", title: "Work", customInfo: capturedSingleColorTheme)])
        XCTAssertNil(try parse(data).spaces.first?.icon)
    }

    /// An unreadable icon record costs the icon and nothing else: not the
    /// Space, and not the colour that shares its `customInfo`.
    private func malformedIconRecordSidebar() -> Data {
        sidebar(spaces: [space(
            "S1", title: "Work", profile: customProfile,
            customInfo: singleColorTheme(red: 1, green: 0, blue: 0.5, iconType: #""🧪""#))])
    }

    func testMalformedIconRecordYieldsNoIcon() throws {
        XCTAssertNil(try parse(malformedIconRecordSidebar()).spaces.first?.icon)
    }

    func testMalformedIconRecordKeepsTheSpaceTitleProfileAndColour() throws {
        let space = try XCTUnwrap(try parse(malformedIconRecordSidebar()).spaces.first)
        XCTAssertEqual(space.title, "Work")
        XCTAssertEqual(space.profile, .custom(directoryBasename: "Profile 1"))
        XCTAssertEqual(space.colorHex, "#ff0080")
    }

    /// The other direction of the same rule: the icon and the colour are
    /// decoded apart, so a theme this parser cannot read keeps the icon.
    func testMalformedThemeKeepsTheIcon() throws {
        let customInfo = #"{ "iconType": { "emoji_v2": "🏢", "emoji": 127970 }, "windowTheme": "🧪" }"#
        let space = try XCTUnwrap(try parse(sidebar(spaces: [space("S1", title: "Work", customInfo: customInfo)])).spaces.first)
        XCTAssertEqual(space.icon, .emoji("🏢"))
        XCTAssertNil(space.colorHex)
    }

    // MARK: - Arc Favorites

    /// Two profiles' Favorites containers: F1 lists its tabs in the reverse
    /// of their declaration order; F2 is empty.
    private func favoritesFixture(topApps: String) -> Data {
        sidebar(
            spaces: [space("S1", title: "Work")],
            items: [
                container("F1", children: ["T2", "T1"]),
                container("F2", children: []),
                tab("T1", title: "Linear", url: "https://linear.app"),
                tab("T2", title: "GitHub", url: "https://github.com"),
            ],
            topApps: topApps)
    }

    private var interleavedTopApps: String {
        #"[\#(customProfile), "F1", \#(defaultProfile), "F2"]"#
    }

    func testFavoritesAreAttributedToTheProfileMarkedBeforeTheirContainer() throws {
        let favorites = try parse(favoritesFixture(topApps: interleavedTopApps)).favorites
        XCTAssertEqual(favorites.map(\.profile), [.custom(directoryBasename: "Profile 1"), .default])
    }

    func testFavoritesKeepSourceOrder() throws {
        let favorites = try parse(favoritesFixture(topApps: interleavedTopApps)).favorites
        XCTAssertEqual(favorites.first?.entries, [
            ArcFavorite(title: "GitHub", url: "https://github.com"),
            ArcFavorite(title: "Linear", url: "https://linear.app"),
        ])
    }

    func testEmptyFavoritesContainerYieldsEmptyList() throws {
        let favorites = try parse(favoritesFixture(topApps: interleavedTopApps)).favorites
        XCTAssertEqual(favorites.last?.entries, [])
    }

    func testFavoritesContainerWithoutProfileMarkerIsKeptAsUnknown() throws {
        let favorites = try parse(favoritesFixture(topApps: #"["F1"]"#)).favorites
        XCTAssertEqual(favorites.map(\.profile), [.unknown])
    }

    func testSidebarWithoutFavoritesContainersYieldsNoArcFavorites() throws {
        let data = sidebar(spaces: [space("S1", title: "Work")])
        XCTAssertEqual(try parse(data).favorites.count, 0)
    }

    /// Arc Favorites are read on top of what the import has always read, so an
    /// unreadable `topAppsContainerIDs` must not cost the Spaces — losing them
    /// empties the import window's Space picker and disables Arc import.
    private func malformedFavoritesFieldSidebar() -> Data {
        Data("""
        {
          "sidebarSyncState": { "items": [] },
          "sidebar": { "containers": [ { "global": {} }, {
            "spaces": [ \(space("S1", title: "Work", profile: customProfile, containerIDs: ["pinned", "C1"])) ],
            "items": [
              \(container("C1", spaceID: "S1", children: ["T1"])),
              \(tab("T1", title: "Linear", url: "https://linear.app"))
            ],
            "topAppsContainerIDs": { "unexpected": "shape" }
          } ] }
        }
        """.utf8)
    }

    func testMalformedFavoritesFieldStillYieldsSpaces() throws {
        let spaces = try parse(malformedFavoritesFieldSidebar()).spaces
        XCTAssertEqual(spaces.map(\.title), ["Work"])
    }

    func testMalformedFavoritesFieldKeepsTheSpaceProfileAndBookmarks() throws {
        let space = try XCTUnwrap(try parse(malformedFavoritesFieldSidebar()).spaces.first)
        XCTAssertEqual(space.profile, .custom(directoryBasename: "Profile 1"))
        XCTAssertEqual(space.root.children.map(\.title), ["Linear"])
    }

    func testMalformedFavoritesFieldYieldsNoArcFavorites() throws {
        XCTAssertEqual(try parse(malformedFavoritesFieldSidebar()).favorites.count, 0)
    }

    // MARK: - Split views

    /// An Arc split view is an item of its own — `data.splitView` — whose
    /// children are the tabs it shows side by side. It appears both in a
    /// Space's pinned section (a split bookmark) and in the Arc Favorites row (a
    /// split Arc Favorite). Shape copied from a real sidebar file.
    private func splitView(_ id: String, children: [String], orientation: String = "horizontal") -> String {
        let childIDs = children.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        { "id": "\(id)", "childrenIds": [\(childIDs)], "title": null, "data": { "splitView": { "layoutOrientation": "\(orientation)", "itemWidthFactors": [], "customInfo": null, "focusItemID": null } } }
        """
    }

    private func splitFixture() -> Data {
        sidebar(
            spaces: [space("S1", title: "Fyde Innovations", containerIDs: ["pinned", "C1"])],
            items: [
                container("C1", spaceID: "S1", children: ["SV1"]),
                splitView("SV1", children: ["T1", "T2"]),
                tab("T1", title: "GitHub", url: "https://github.com/"),
                tab("T2", title: "Baidu", url: "https://www.baidu.com/"),
                container("F1", children: ["SV2"]),
                splitView("SV2", children: ["T3", "T4"]),
                tab("T3", title: "FydeOS", url: "https://fydeos.com/"),
                tab("T4", title: "Phi Browser", url: "https://phibrowser.com/"),
            ],
            topApps: #"[\#(defaultProfile), "F1"]"#)
    }

    /// The bug this pins: a split view used to fall through the item decoder
    /// as a nameless container, so it landed as an "Untitled" folder holding
    /// its two tabs.
    func testASplitViewInTheSpacesPinnedSectionIsOneSplitEntry() throws {
        let root = try XCTUnwrap(try parse(splitFixture()).spaces.first?.root)
        XCTAssertEqual(root.children.count, 1)
        let entry = try XCTUnwrap(root.children.first)
        XCTAssertFalse(entry.isFolder)
        XCTAssertEqual(entry.title, "GitHub")
        XCTAssertEqual(entry.url, "https://github.com/")
        XCTAssertEqual(entry.split, ArcSplit(
            secondaryTitle: "Baidu", secondaryURL: "https://www.baidu.com/",
            layout: SplitLayout.vertical.rawValue))
        XCTAssertTrue(entry.children.isEmpty)
    }

    /// The same bug on the Arc Favorites row, where the folder filter dropped the
    /// split view and both tabs with it.
    func testASplitViewInTheFavoritesRowIsOneSplitFavorite() throws {
        let favorites = try XCTUnwrap(try parse(splitFixture()).favorites.first)
        XCTAssertEqual(favorites.entries, [
            ArcFavorite(title: "FydeOS", url: "https://fydeos.com/", split: ArcSplit(
                secondaryTitle: "Phi Browser", secondaryURL: "https://phibrowser.com/",
                layout: SplitLayout.vertical.rawValue)),
        ])
    }

    /// Arc names the axis the panes run along; Phi names the divider. A
    /// stacked Arc split (`vertical`) is a `horizontal` Phi bar, and an
    /// orientation Phi does not know leaves the default.
    func testASplitViewsOrientationBecomesPhisDividerLayout() throws {
        func layout(_ orientation: String) throws -> String? {
            let data = sidebar(
                spaces: [space("S1", title: "Work", containerIDs: ["pinned", "C1"])],
                items: [
                    container("C1", spaceID: "S1", children: ["SV1"]),
                    splitView("SV1", children: ["T1", "T2"], orientation: orientation),
                    tab("T1", title: "A", url: "https://a.example"),
                    tab("T2", title: "B", url: "https://b.example"),
                ])
            return try parse(data).spaces.first?.root.children.first?.split?.layout
        }
        XCTAssertEqual(try layout("vertical"), SplitLayout.horizontal.rawValue)
        XCTAssertNil(try layout("diagonal"))
    }

    /// Phi's split is a pair. A split of any other size falls back to its tabs,
    /// in order, where the split stood — never to a folder.
    func testASplitViewOfThreeTabsFallsBackToItsTabsInPlace() throws {
        let data = sidebar(
            spaces: [space("S1", title: "Work", containerIDs: ["pinned", "C1"])],
            items: [
                container("C1", spaceID: "S1", children: ["T0", "SV1", "T4"]),
                tab("T0", title: "Before", url: "https://before.example"),
                splitView("SV1", children: ["T1", "T2", "T3"]),
                tab("T1", title: "A", url: "https://a.example"),
                tab("T2", title: "B", url: "https://b.example"),
                tab("T3", title: "C", url: "https://c.example"),
                tab("T4", title: "After", url: "https://after.example"),
            ])
        let root = try XCTUnwrap(try parse(data).spaces.first?.root)
        XCTAssertEqual(root.children.map(\.title), ["Before", "A", "B", "C", "After"])
        XCTAssertFalse(root.children.contains { $0.isFolder || $0.split != nil })
    }

    func testASplitViewInsideAFolderStaysInThatFolder() throws {
        let data = sidebar(
            spaces: [space("S1", title: "Work", containerIDs: ["pinned", "C1"])],
            items: [
                container("C1", spaceID: "S1", children: ["L1"]),
                #"{ "id": "L1", "childrenIds": ["SV1"], "title": "Reading", "data": { "list": {} } }"#,
                splitView("SV1", children: ["T1", "T2"]),
                tab("T1", title: "A", url: "https://a.example"),
                tab("T2", title: "B", url: "https://b.example"),
            ])
        let folder = try XCTUnwrap(try parse(data).spaces.first?.root.children.first)
        XCTAssertEqual(folder.title, "Reading")
        XCTAssertEqual(folder.children.map(\.title), ["A"])
        XCTAssertEqual(folder.children.first?.split?.secondaryURL, "https://b.example")
    }
}

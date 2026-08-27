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

    private func singleColorTheme(red: Double, green: Double, blue: Double) -> String {
        """
        { "windowTheme": { "background": { "single": { "_0": { "style": { "color": { "_0": {
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
}

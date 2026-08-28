// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The resolver is a pure function from a source icon to a Phi icon storage
/// value. It is tested against a fixed catalog, so nothing here depends on the
/// host system's emoji font — except the every-row and shared-concept cases,
/// whose point is the catalogs the app actually ships.
final class BrowserMigrationSpaceIconResolverTests: XCTestCase {

    /// Four items in the shipped catalog's own shape: one plain; one the
    /// catalog holds fully qualified (❤️ is `2764-FE0F`); one it holds
    /// unqualified (✅ is `2705`); and one with a skin-tone variant.
    private let catalog = try! JSONDecoder().decode(EmojiCatalog.self, from: Data("""
    { "version": "17.0", "date": "", "source": "", "groups": [ { "name": "Test", "items": [
      { "id": "1F3E2", "text": "🏢", "name": "office building", "subgroup": "place-building", "skinVariants": [] },
      { "id": "2764-FE0F", "text": "\u{2764}\u{FE0F}", "name": "red heart", "subgroup": "heart", "skinVariants": [] },
      { "id": "2705", "text": "\u{2705}", "name": "check mark button", "subgroup": "other-symbol", "skinVariants": [] },
      { "id": "1F44D", "text": "👍", "name": "thumbs up", "subgroup": "hand-fingers-closed", "skinVariants": [
        { "id": "1F44D-1F3FB", "text": "\u{1F44D}\u{1F3FB}", "name": "thumbs up: light skin tone" } ] }
    ] } ] }
    """.utf8))

    private func resolve(_ emoji: String) -> String? {
        BrowserMigrationSpaceIconResolver.storageValue(for: .emoji(emoji), emojiCatalog: catalog)
    }

    private func resolve(arcName: String) -> String? {
        BrowserMigrationSpaceIconResolver.storageValue(for: .arcNamed(arcName), emojiCatalog: catalog)
    }

    private func resolve(zenName: String) -> String? {
        BrowserMigrationSpaceIconResolver.storageValue(for: .zenNamed(zenName), emojiCatalog: catalog)
    }

    /// The icons among `icons` that resolve, against the catalogs the app
    /// ships, to nothing the picker can show.
    private func unplaced(_ icons: [BrowserMigrationSourceIcon]) -> [BrowserMigrationSourceIcon] {
        icons.filter { icon in
            BrowserMigrationSpaceIconResolver.storageValue(for: icon)
                .flatMap { IconPickerSelection.fromStorageValue($0) } == nil
        }
    }

    // MARK: - Emoji

    func testAnEmojiTheCatalogHoldsResolvesToItsStorageValue() {
        XCTAssertEqual(resolve("🏢"), "emoji:1F3E2")
    }

    /// The storage value is the picker's own, so a migrated icon is one the
    /// user could have chosen and edits like any other.
    func testAResolvedEmojiIsOneThePickerCanShow() throws {
        let value = try XCTUnwrap(resolve("🏢"))
        XCTAssertEqual(
            IconPickerSelection.fromStorageValue(value, emojiCatalog: catalog),
            .emoji(id: "1F3E2", text: "🏢"))
    }

    func testAnUnqualifiedEmojiMatchesTheCatalogsQualifiedForm() {
        XCTAssertEqual(resolve("\u{2764}"), "emoji:2764-FE0F")
    }

    func testAQualifiedEmojiMatchesTheCatalogsUnqualifiedForm() {
        XCTAssertEqual(resolve("\u{2705}\u{FE0F}"), "emoji:2705")
    }

    func testASkinToneVariantResolvesToTheVariantsOwnId() {
        XCTAssertEqual(resolve("\u{1F44D}\u{1F3FB}"), "emoji:1F44D-1F3FB")
    }

    func testAnEmojiTheCatalogLacksResolvesToNothing() {
        XCTAssertNil(resolve("🦄"))
    }

    func testAnEmptyEmojiResolvesToNothing() {
        XCTAssertNil(resolve(""))
    }

    func testAnEmojiOfNothingButVariationSelectorsResolvesToNothing() {
        XCTAssertNil(resolve("\u{FE0F}"))
    }

    // MARK: - Arc names

    func testAnArcNameThatLandsOnAPhiIconResolvesToThatIcon() {
        XCTAssertEqual(resolve(arcName: "notifications"), "phi:phi-icon-bell")
    }

    func testAnArcNameThatLandsOnAnEmojiResolvesToThatEmoji() {
        XCTAssertEqual(resolve(arcName: "thumbsUp"), "emoji:1F44D")
    }

    func testAnArcNameNotInTheTableResolvesToNothing() {
        XCTAssertNil(resolve(arcName: "unicorn"))
    }

    /// An emoji target takes the same catalog check a source emoji does: ⭐ is
    /// not in this fixture, so `star` has nowhere to land.
    func testAnArcNameWhoseTargetEmojiTheCatalogLacksResolvesToNothing() {
        XCTAssertNil(resolve(arcName: "star"))
    }

    /// Arc's built-in icon names, as its own model encodes them (61 in Arc's
    /// icon enum), less the two app logos below: the independent list the
    /// table is checked against.
    private let arcVocabulary = [
        "star", "bookmark", "heart", "flag", "flash", "triangle", "medical",
        "notifications", "bulb", "shapes", "grid", "apps", "layers", "server",
        "albums", "copy", "folder", "fileTrayFull", "calendar", "mail",
        "checkbox", "document", "book", "chatBubbleEllipses", "people",
        "terminal", "construction", "square", "egg", "ellipse", "moon", "sunny",
        "planet", "leaf", "cloud", "paw", "bag", "gift", "bed", "restaurant",
        "barbell", "airplane", "musicalNote", "colorPallete", "video", "bandage",
        "code", "baseball", "cloudOutline", "map", "bonfire", "pizza", "skull",
        "receipt", "thumbsUp", "train", "rss", "github", "search",
    ]

    /// Arc's `figma` and `linear` are app logos with no Phi counterpart: left
    /// out of the table on purpose, so they take the default like any unknown
    /// name.
    func testAnArcAppLogoWithNoCounterpartResolvesToNothing() {
        XCTAssertNil(resolve(arcName: "figma"))
        XCTAssertNil(resolve(arcName: "linear"))
    }

    /// The table is data, and this is the test that keeps it honest: it covers
    /// exactly Arc's vocabulary, and every row lands on a Phi icon the icon
    /// catalog knows or an emoji the catalog the app loaded holds — a value
    /// the picker itself can show.
    func testEveryArcTableRowResolvesToAnIconThePickerCanShow() {
        XCTAssertEqual(arcVocabulary.count, 59)
        let names = BrowserMigrationSpaceIconResolver.arcIconNames
        XCTAssertEqual(Set(names), Set(arcVocabulary))
        XCTAssertEqual(unplaced(names.map { .arcNamed($0) }), [])
    }

    // MARK: - Zen names

    func testAZenNameThatLandsOnAPhiIconResolvesToThatIcon() {
        XCTAssertEqual(resolve(zenName: "bell"), "phi:phi-icon-bell")
    }

    func testAZenNameThatLandsOnAnEmojiResolvesToThatEmoji() {
        XCTAssertEqual(resolve(zenName: "checkbox"), "emoji:2705")
    }

    func testAZenNameNotInTheTableResolvesToNothing() {
        XCTAssertNil(resolve(zenName: "unicorn"))
    }

    /// Where Arc and Zen name the same concept they land on the same target,
    /// so a user who used both sees the same Phi icon for the same idea.
    func testAnArcNameAndAZenNameForTheSameConceptLandOnTheSameTarget() throws {
        for name in ["star", "heart", "flag", "pizza", "skull"] {
            let target = try XCTUnwrap(BrowserMigrationSpaceIconResolver.storageValue(for: .arcNamed(name)), name)
            XCTAssertEqual(BrowserMigrationSpaceIconResolver.storageValue(for: .zenNamed(name)), target, name)
        }
    }

    /// Zen's built-in icon names — the `selectable` icon files it ships, 87
    /// of them: the independent list the table is checked against.
    private let zenVocabulary = [
        "airplane", "american-football", "baseball", "basket", "bed", "bell",
        "book", "bookmark", "briefcase", "brush", "bug", "build", "cafe", "call",
        "card", "chat", "checkbox", "circle", "cloud", "code", "coins",
        "construct", "cutlery", "egg", "extension-puzzle", "eye", "fast-food",
        "fish", "flag", "flame", "flask", "folder", "game-controller", "globe-1",
        "globe", "grid-2x2", "grid-3x3", "heart", "ice-cream", "image", "inbox",
        "key", "layers", "leaf", "lightning", "location", "lock-closed",
        "logo-github", "logo-rss", "logo-usd", "mail", "map", "megaphone", "moon",
        "music", "navigate", "nuclear", "page", "palette", "paw", "people",
        "pizza", "planet", "present", "rocket", "school", "shapes", "shirt",
        "skull", "square", "squares", "star-1", "star", "stats-chart", "sun",
        "tada", "terminal", "ticket", "time", "trash", "triangle", "video",
        "volume-high", "wallet", "warning", "water", "weight",
    ]

    /// The Zen table's honesty test, the shape of the Arc one: it covers
    /// exactly Zen's vocabulary, and every row lands on an icon the picker
    /// can show.
    func testEveryZenTableRowResolvesToAnIconThePickerCanShow() {
        XCTAssertEqual(zenVocabulary.count, 87)
        let names = BrowserMigrationSpaceIconResolver.zenIconNames
        XCTAssertEqual(Set(names), Set(zenVocabulary))
        XCTAssertEqual(unplaced(names.map { .zenNamed($0) }), [])
    }
}

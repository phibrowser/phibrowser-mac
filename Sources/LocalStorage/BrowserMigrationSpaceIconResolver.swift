// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Turns a source Space's icon into the Phi icon storage value that stands
/// for it, or nil when Phi has nothing for it. The matching — the named-icon
/// tables and the emoji normalisation — lives here, apart from the planner,
/// so the planner stays the short list of what a run creates; the planner
/// owns the fallback and is the only caller.
enum BrowserMigrationSpaceIconResolver {
    /// An emoji is matched against `emojiCatalog` — by default the one the
    /// app loaded, which has already dropped what the running system cannot
    /// draw — so a migrated emoji is always one the Space strip can show. A
    /// named icon goes through its table to a Phi icon or an emoji; an emoji
    /// target takes the same catalog check a source emoji does.
    static func storageValue(
        for icon: BrowserMigrationSourceIcon,
        emojiCatalog: EmojiCatalog = .shared
    ) -> String? {
        switch icon {
        case .emoji(let text):
            return emojiStorageValue(for: text, in: emojiCatalog)
        case .arcNamed(let name):
            return arcTable[name].flatMap { targetStorageValue(for: $0, in: emojiCatalog) }
        case .zenNamed(let name):
            return zenTable[name].flatMap { targetStorageValue(for: $0, in: emojiCatalog) }
        }
    }

    // MARK: - Named icons

    /// What a named source icon lands on: a Phi icon, by its catalog name, or
    /// — when Phi's icon set has nothing for the concept — an emoji, by its
    /// text. Two source names may share a target.
    private enum Target {
        case phiIcon(String)
        case emoji(String)
    }

    private static func targetStorageValue(for target: Target, in catalog: EmojiCatalog) -> String? {
        switch target {
        case .phiIcon(let name):
            return PhiIconCatalog.icon(named: name)
                .map { IconPickerSelection.phiIcon(id: $0.assetName).storageValue }
        case .emoji(let text):
            return emojiStorageValue(for: text, in: catalog)
        }
    }

    /// Arc's built-in icon names, as Arc's own model encodes them (Ionicons
    /// names in camel case), each on the Phi icon that depicts the same thing
    /// or, failing one, the emoji that does. Arc's icon enum has 61 names; the
    /// two missing here, `figma` and `linear`, are app logos with no Phi
    /// counterpart and take the default on purpose. Plain data: a new Arc
    /// icon is one row here.
    private static let arcTable: [String: Target] = [
        "flash": .phiIcon("lightning-bolt"),
        "notifications": .phiIcon("bell"),
        "bulb": .phiIcon("light-bulb"),
        "grid": .phiIcon("view-grid-add"),
        "apps": .phiIcon("view-grid-add"),
        "albums": .phiIcon("photograph"),
        "copy": .phiIcon("clipboard-list"),
        "fileTrayFull": .phiIcon("archive"),
        "mail": .phiIcon("mail"),
        "chatBubbleEllipses": .phiIcon("chat"),
        "people": .phiIcon("user"),
        "sunny": .phiIcon("sun"),
        "cloud": .phiIcon("cloud"),
        "cloudOutline": .phiIcon("cloud"),
        "gift": .phiIcon("gift"),
        "musicalNote": .phiIcon("music-note"),
        "colorPallete": .phiIcon("color-swatch"),
        "video": .phiIcon("film"),
        "map": .phiIcon("map"),
        "rss": .phiIcon("rss"),
        "server": .phiIcon("server"),
        "moon": .phiIcon("moon"),
        "search": .phiIcon("search-circle"),
        "star": .emoji("⭐"),
        "bookmark": .emoji("🔖"),
        "heart": .emoji("❤️"),
        "flag": .emoji("🚩"),
        "triangle": .emoji("🔺"),
        "medical": .emoji("✳️"),
        "shapes": .emoji("🔷"),
        "layers": .emoji("🗂️"),
        "checkbox": .emoji("✅"),
        "book": .emoji("📖"),
        "terminal": .emoji("🖥️"),
        "construction": .emoji("🛠️"),
        "square": .emoji("⬜"),
        "ellipse": .emoji("⚪"),
        "planet": .emoji("🪐"),
        "leaf": .emoji("🍃"),
        "restaurant": .emoji("🍴"),
        "barbell": .emoji("🏋️"),
        "airplane": .emoji("✈️"),
        "bandage": .emoji("🩹"),
        "code": .emoji("💻"),
        "baseball": .emoji("⚾"),
        "bonfire": .emoji("🔥"),
        "pizza": .emoji("🍕"),
        "skull": .emoji("💀"),
        "receipt": .emoji("🧾"),
        "thumbsUp": .emoji("👍"),
        "train": .emoji("🚆"),
        "egg": .emoji("🥚"),
        "paw": .emoji("🐾"),
        "bag": .emoji("🛍️"),
        "bed": .emoji("🛏️"),
        "folder": .emoji("📁"),
        "calendar": .emoji("📅"),
        "document": .emoji("📄"),
        "github": .emoji("🐙"),
    ]

    /// The names the Arc table knows, for the test that keeps the table honest.
    static var arcIconNames: [String] { Array(arcTable.keys) }

    /// Zen's built-in icon names — the `selectable` icon files it ships, as
    /// the Zen adapter reads them off the icon's URL — each on the Phi icon
    /// that depicts the same thing or, failing one, the emoji that does. All
    /// 87 are covered, and where Arc names the same concept the two tables
    /// land on the same target. Plain data: a new Zen icon is one row here.
    private static let zenTable: [String: Target] = [
        "bell": .phiIcon("bell"),
        "briefcase": .phiIcon("briefcase"),
        "card": .phiIcon("credit-card"),
        "chat": .phiIcon("chat"),
        "cloud": .phiIcon("cloud"),
        "flask": .phiIcon("beaker"),
        "globe": .phiIcon("globe-alt"),
        "globe-1": .phiIcon("globe-alt"),
        "grid-2x2": .phiIcon("view-grid-add"),
        "grid-3x3": .phiIcon("view-grid-add"),
        "image": .phiIcon("photograph"),
        "inbox": .phiIcon("archive"),
        "lightning": .phiIcon("lightning-bolt"),
        "lock-closed": .phiIcon("lock-closed"),
        "logo-rss": .phiIcon("rss"),
        "mail": .phiIcon("mail"),
        "map": .phiIcon("map"),
        "moon": .phiIcon("moon"),
        "music": .phiIcon("music-note"),
        "palette": .phiIcon("color-swatch"),
        "people": .phiIcon("user"),
        "present": .phiIcon("gift"),
        "school": .phiIcon("academic-cap"),
        "stats-chart": .phiIcon("presentation-chart-line"),
        "sun": .phiIcon("sun"),
        "ticket": .phiIcon("ticket"),
        "video": .phiIcon("film"),
        "airplane": .emoji("✈️"),
        "american-football": .emoji("🏈"),
        "baseball": .emoji("⚾"),
        "basket": .emoji("🧺"),
        "bed": .emoji("🛏️"),
        "book": .emoji("📖"),
        "bookmark": .emoji("🔖"),
        "brush": .emoji("🖌️"),
        "bug": .emoji("🐛"),
        "build": .emoji("🔧"),
        "cafe": .emoji("☕"),
        "call": .emoji("📞"),
        "checkbox": .emoji("✅"),
        "circle": .emoji("⚪"),
        "code": .emoji("💻"),
        "coins": .emoji("🪙"),
        "construct": .emoji("🛠️"),
        "cutlery": .emoji("🍴"),
        "egg": .emoji("🥚"),
        "extension-puzzle": .emoji("🧩"),
        "eye": .emoji("👁️"),
        "fast-food": .emoji("🍔"),
        "fish": .emoji("🐟"),
        "flag": .emoji("🚩"),
        "flame": .emoji("🔥"),
        "folder": .emoji("📁"),
        "game-controller": .emoji("🎮"),
        "heart": .emoji("❤️"),
        "ice-cream": .emoji("🍦"),
        "key": .emoji("🔑"),
        "layers": .emoji("🗂️"),
        "leaf": .emoji("🍃"),
        "location": .emoji("📍"),
        "logo-github": .emoji("🐙"),
        "logo-usd": .emoji("💲"),
        "megaphone": .emoji("📣"),
        "navigate": .emoji("🧭"),
        "nuclear": .emoji("☢️"),
        "page": .emoji("📄"),
        "paw": .emoji("🐾"),
        "pizza": .emoji("🍕"),
        "planet": .emoji("🪐"),
        "rocket": .emoji("🚀"),
        "shapes": .emoji("🔷"),
        "shirt": .emoji("👕"),
        "skull": .emoji("💀"),
        "square": .emoji("⬜"),
        "squares": .emoji("🔳"),
        "star": .emoji("⭐"),
        "star-1": .emoji("⭐"),
        "tada": .emoji("🎉"),
        "terminal": .emoji("🖥️"),
        "time": .emoji("⏰"),
        "trash": .emoji("🗑️"),
        "triangle": .emoji("🔺"),
        "volume-high": .emoji("🔊"),
        "wallet": .emoji("👛"),
        "warning": .emoji("⚠️"),
        "water": .emoji("💧"),
        "weight": .emoji("🏋️"),
    ]

    /// The names the Zen table knows, for the test that keeps the table honest.
    static var zenIconNames: [String] { Array(zenTable.keys) }

    // MARK: - Emoji

    /// An exact id match against an item or one of its skin-tone variants
    /// wins; failing that, a match with the `FE0F` variation selectors
    /// ignored on both sides — the catalog is fully qualified (`2764-FE0F`
    /// for ❤️) and a source may store the unqualified form, or the reverse.
    private static func emojiStorageValue(for text: String, in catalog: EmojiCatalog) -> String? {
        let id = emojiID(of: text)
        let bareID = ignoringVariationSelectors(id)
        // Nothing at all, or nothing but variation selectors, is no emoji.
        guard !bareID.isEmpty else { return nil }

        let ids = catalog.allItems.flatMap { [$0.id] + $0.skinVariants.map(\.id) }
        let matchedID = ids.contains(id)
            ? id
            : ids.first { ignoringVariationSelectors($0) == bareID }
        guard let matchedID, let matchedText = catalog.text(for: matchedID) else { return nil }
        return IconPickerSelection.emoji(id: matchedID, text: matchedText).storageValue
    }

    /// The catalog's own id form: each scalar as uppercase hex of at least
    /// four digits, joined with `-` (`00A9-FE0F` for ©️).
    private static func emojiID(of text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: "-")
    }

    private static func ignoringVariationSelectors(_ id: String) -> String {
        id.split(separator: "-").filter { $0 != "FE0F" }.joined(separator: "-")
    }
}

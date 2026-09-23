// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation

struct EmojiCatalog: Decodable {
    struct Group: Decodable, Identifiable, Hashable {
        let name: String
        let items: [EmojiItem]

        var id: String { name }
    }

    let version: String
    let date: String
    let source: String
    let groups: [Group]

    static let shared = EmojiCatalog.loadFromBundle()

    var allItems: [EmojiItem] {
        groups.flatMap(\.items)
    }

    func text(for id: String) -> String? {
        for item in allItems {
            if item.id == id {
                return item.text
            }
            if let variant = item.skinVariants.first(where: { $0.id == id }) {
                return variant.text
            }
        }
        return nil
    }

    /// The id of the emoji whose glyph is `text`, skin variants included.
    /// Variation selectors are ignored so "❤" and "❤️" both match.
    func id(forText text: String) -> String? {
        let key = Self.strippingVariationSelectors(text)
        guard !key.isEmpty else { return nil }
        for item in allItems {
            if Self.strippingVariationSelectors(item.text) == key {
                return item.id
            }
            if let variant = item.skinVariants.first(where: {
                Self.strippingVariationSelectors($0.text) == key
            }) {
                return variant.id
            }
        }
        return nil
    }

    private static func strippingVariationSelectors(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }))
    }

    private static func loadFromBundle() -> EmojiCatalog {
        let url = Bundle.main.url(
            forResource: "emoji-catalog",
            withExtension: "json",
            subdirectory: "Emoji"
        ) ?? Bundle.main.url(
            forResource: "emoji-catalog",
            withExtension: "json"
        )

        guard let url else {
            AppLogError("[EmojiCatalog] emoji-catalog.json is missing from the bundle")
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder()
                .decode(EmojiCatalog.self, from: data)
                .filteringUnsupportedEmoji()
        } catch {
            AppLogError("[EmojiCatalog] Failed to load emoji catalog: \(error)")
            return .empty
        }
    }

    private func filteringUnsupportedEmoji(
        using detector: EmojiRuntimeSupportDetector = EmojiRuntimeSupportDetector()
    ) -> EmojiCatalog {
        let filteredGroups = groups.compactMap { group -> Group? in
            let filteredItems = group.items.compactMap { item -> EmojiItem? in
                guard detector.supportsEmoji(item.text) else { return nil }
                let supportedVariants = item.skinVariants.filter {
                    detector.supportsEmoji($0.text)
                }
                return EmojiItem(
                    id: item.id,
                    text: item.text,
                    name: item.name,
                    subgroup: item.subgroup,
                    skinVariants: supportedVariants
                )
            }

            guard !filteredItems.isEmpty else { return nil }
            return Group(name: group.name, items: filteredItems)
        }

        return EmojiCatalog(
            version: version,
            date: date,
            source: source,
            groups: filteredGroups
        )
    }

    private static let empty = EmojiCatalog(
        version: "",
        date: "",
        source: "",
        groups: []
    )
}

struct EmojiItem: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let name: String
    let subgroup: String
    let skinVariants: [EmojiVariant]

    var hasSkinVariants: Bool {
        !skinVariants.isEmpty
    }
}

struct EmojiVariant: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let name: String
}

struct EmojiRuntimeSupportDetector {
    private static let supportedEmojiTagSequences: Set<String> = [
        "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        "🏴\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"
    ]
    private static let flagRenderCanvasSize = 64
    private static let flagRenderBytesPerPixel = 4
    private static let flagRenderAlphaThreshold: UInt8 = 8
    private static let flagRenderColorThreshold: UInt8 = 8
    private static let minimumFlagColorPixelCount = 8

    private let font: CTFont?
    private let singleEmojiCellWidth: CGFloat

    init() {
        let font = CTFontCreateUIFontForLanguage(.system, 16, nil)
        self.font = font
        self.singleEmojiCellWidth = font.map {
            Self.typographicWidth(for: "😀", font: $0)
        } ?? 0
    }

    func supportsEmoji(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let font else { return false }
        let hasEmojiTags = containsEmojiTags(text)
        guard !hasEmojiTags || Self.supportedEmojiTagSequences.contains(text) else {
            return false
        }

        let attributedString = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributedString)
        let glyphCount = CTLineGetGlyphCount(line)
        guard glyphCount > 0 else { return false }
        guard !hasEmojiTags || glyphCount == 1 else { return false }
        guard occupiesSingleEmojiCell(line) else { return false }
        if isRegionalIndicatorFlag(text) || hasEmojiTags {
            guard rendersColorFlag(text, font: font) else { return false }
        }

        var usesAppleEmojiFont = false
        let runs = CTLineGetGlyphRuns(line)
        for index in 0..<CFArrayGetCount(runs) {
            guard let run = run(at: index, in: runs) else { return false }
            guard runUsesSupportedGlyphs(run, usesAppleEmojiFont: &usesAppleEmojiFont) else {
                return false
            }
        }

        guard usesAppleEmojiFont else { return false }
        return true
    }

    private func runUsesSupportedGlyphs(_ run: CTRun,
                                        usesAppleEmojiFont: inout Bool) -> Bool {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let fontValue = attributes[kCTFontAttributeName as String] else {
            return false
        }
        let fontReference = fontValue as CFTypeRef
        guard CFGetTypeID(fontReference) == CTFontGetTypeID() else {
            return false
        }
        let font = fontValue as! CTFont

        let fontName = CTFontCopyPostScriptName(font) as String
        if fontName == "LastResort" {
            return false
        }
        if fontName.contains("AppleColorEmoji") {
            usesAppleEmojiFont = true
        }

        let glyphCount = CTRunGetGlyphCount(run)
        guard glyphCount > 0 else { return false }

        var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        return !glyphs.contains(0)
    }

    private func rendersColorFlag(_ text: String, font: CTFont) -> Bool {
        let size = Self.flagRenderCanvasSize
        let bytesPerRow = size * Self.flagRenderBytesPerPixel
        var pixels = Array(repeating: UInt8(0), count: size * bytesPerRow)

        return pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.clear(CGRect(x: 0, y: 0, width: size, height: size))
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.textMatrix = .identity

            let attributedString = NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
            let line = CTLineCreateWithAttributedString(attributedString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            context.textPosition = CGPoint(
                x: (CGFloat(size) - width) / 2,
                y: (CGFloat(size) - ascent - descent) / 2 + descent
            )
            CTLineDraw(line, context)

            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var colorPixelCount = 0
            for alphaIndex in stride(from: 3, to: bytes.count, by: Self.flagRenderBytesPerPixel) {
                guard bytes[alphaIndex] > Self.flagRenderAlphaThreshold else { continue }

                let red = bytes[alphaIndex - 3]
                let green = bytes[alphaIndex - 2]
                let blue = bytes[alphaIndex - 1]
                guard max(red, green, blue) > Self.flagRenderColorThreshold else { continue }

                colorPixelCount += 1
                if colorPixelCount >= Self.minimumFlagColorPixelCount {
                    return true
                }
            }

            return false
        }
    }

    private func occupiesSingleEmojiCell(_ line: CTLine) -> Bool {
        guard singleEmojiCellWidth > 0 else { return false }
        let width = Self.typographicWidth(for: line)
        return width > 0 && width <= singleEmojiCellWidth * 1.25
    }

    private func containsEmojiTags(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xE0020...0xE007F).contains(scalar.value)
        }
    }

    private func isRegionalIndicatorFlag(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 2 else { return false }
        return scalars.allSatisfy { scalar in
            (0x1F1E6...0x1F1FF).contains(scalar.value)
        }
    }

    private func run(at index: CFIndex, in runs: CFArray) -> CTRun? {
        guard let pointer = CFArrayGetValueAtIndex(runs, index) else {
            return nil
        }
        let runReference = unsafeBitCast(pointer, to: CFTypeRef.self)
        guard CFGetTypeID(runReference) == CTRunGetTypeID() else {
            return nil
        }
        return unsafeBitCast(pointer, to: CTRun.self)
    }

    private static func typographicWidth(for text: String, font: CTFont) -> CGFloat {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        return typographicWidth(for: CTLineCreateWithAttributedString(attributedString))
    }

    private static func typographicWidth(for line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        return CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    }
}

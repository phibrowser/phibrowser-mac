// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

extension NSFont {
    /// The bundled brand display face at `size`, or the system face when
    /// `string` contains characters that face cannot draw.
    ///
    /// The Ivy Presto and Impact faces shipped in `Resources/Fonts` are
    /// Latin-only: none of them map a single CJK codepoint (verified against
    /// `CTFontCopyCharacterSet`). Setting one on a label holding a localized
    /// title therefore leaves every glyph to system fallback, and on macOS 15
    /// that fallback draws the run clipped — `开始之前` came out as
    /// `丿丨 夂口 乀 刖`, each character shorn of its upper strokes, on the
    /// onboarding pages. macOS 26 falls back cleanly, which is why this only
    /// ever showed up on 15.
    ///
    /// Substituting the whole run keeps the label's font and the drawn glyphs
    /// the same face, so the line metrics the label lays out with are the ones
    /// the glyphs actually need. A cascade list would preserve the brand face
    /// for any Latin in a mixed string, but line height would still come from
    /// the Latin face — the very mismatch that clips the CJK.
    ///
    /// Returns the system face too when the brand font is missing entirely,
    /// where `NSFont(name:size:)` would hand back nil and leave the label on
    /// whatever it had.
    static func brandDisplay(
        _ name: String,
        size: CGFloat,
        renders string: String,
        weight: NSFont.Weight = .semibold
    ) -> NSFont {
        guard let font = NSFont(name: name, size: size),
              font.covers(string) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return font
    }

    /// Whether this face maps a glyph for every character in `string`.
    /// Whitespace is ignored: a face that lacks a space is still usable, and
    /// layout supplies the advance regardless.
    func covers(_ string: String) -> Bool {
        let characters = coveredCharacterSet
        return string.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || characters.contains(scalar)
        }
    }
}

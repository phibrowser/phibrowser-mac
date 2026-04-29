// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Mac-side mirror of Chromium's `tab_groups::TabGroupColorId`.
///
/// Raw values match the wire-format strings produced by the Chromium bridge
/// (see `TabGroupsProxy::ColorIdToWireString`). Keep them in sync; an unknown
/// wire string maps to `.grey` at the bridge boundary.
enum GroupColor: String, Codable, CaseIterable {
    case grey
    case blue
    case red
    case yellow
    case green
    case pink
    case purple
    case cyan
    case orange

    /// Human-readable name used by the auto-name fallback (`displayTitle`)
    /// and by color-picker menus.
    var localizedName: String {
        switch self {
        case .grey:
            return NSLocalizedString(
                "Grey",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .blue:
            return NSLocalizedString(
                "Blue",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .red:
            return NSLocalizedString(
                "Red",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .yellow:
            return NSLocalizedString(
                "Yellow",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .green:
            return NSLocalizedString(
                "Green",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .pink:
            return NSLocalizedString(
                "Pink",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .purple:
            return NSLocalizedString(
                "Purple",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .cyan:
            return NSLocalizedString(
                "Cyan",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .orange:
            return NSLocalizedString(
                "Orange",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        }
    }
}

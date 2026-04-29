// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// UI-side bridge from the data-layer `GroupColor` to a concrete `NSColor`
/// resolved against the asset catalog (light / dark variants live in
/// `Resources/Assets.xcassets/TabGroupColor/`). Kept out of `GroupColor.swift`
/// so the data folder doesn't depend on AppKit.
extension GroupColor {
    var nsColor: NSColor {
        switch self {
        case .grey:   return NSColor(resource: .tabGroupGrey)
        case .blue:   return NSColor(resource: .tabGroupBlue)
        case .red:    return NSColor(resource: .tabGroupRed)
        case .yellow: return NSColor(resource: .tabGroupYellow)
        case .green:  return NSColor(resource: .tabGroupGreen)
        case .pink:   return NSColor(resource: .tabGroupPink)
        case .purple: return NSColor(resource: .tabGroupPurple)
        case .cyan:   return NSColor(resource: .tabGroupCyan)
        case .orange: return NSColor(resource: .tabGroupOrange)
        }
    }
}

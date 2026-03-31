// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Semantic color roles used by the theme system.
public enum ColorRole: String, Hashable, CaseIterable {
    case themeColor
    case themeColorOnHover
    // Phi
    case textPrimary
    case textPrimaryStrong
    case textSecondary
    case textTertiary
    
    case windowOverlayBackground
    case windowBackground
    
    case settingItemBackground
    
    case sidebarTabSelectedBackground
    case sidebarTabHoveredBackground
    
    case border
    case separator
}

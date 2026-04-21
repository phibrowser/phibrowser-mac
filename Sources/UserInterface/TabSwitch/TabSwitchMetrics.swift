// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CoreGraphics

enum TabSwitchMetrics {
    static let maxRecentTabs = 5

    private static let longPressThresholdKey = "TabSwitch.longPressThreshold"
    private static let defaultLongPressThreshold: TimeInterval = 0.25

    static var longPressThreshold: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: longPressThresholdKey)
        return stored > 0 ? stored : defaultLongPressThreshold
    }

    static let windowHorizontalInset: CGFloat = 16
    static let windowVerticalInset: CGFloat = 16
    static let windowCornerRadius: CGFloat = 20
    static let windowShadowRadius: CGFloat = 14

    static let cellWidth: CGFloat = 182
    static let cellHeight: CGFloat = 157
    static let cellSpacing: CGFloat = 8
    static let cellCornerRadius: CGFloat = 8
    static let cellContentInset: CGFloat = 12

    static let previewInset: CGFloat = 12
    static let previewHeight: CGFloat = 105
    static let previewCornerRadius: CGFloat = 8

    static let titleTopSpacing: CGFloat = 8
    static let titleLineLimit = 1
    static let hoverAnimationDuration: TimeInterval = 0.15

}

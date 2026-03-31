// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// NSHostingView subclass for embedding SwiftUI in AppKit with stable layout.
/// - Zeroes safeAreaInsets to prevent content compression.
/// - Disables content-derived size constraints (min/intrinsic/max) so parent layout is not affected.
class ZeroSafeAreaHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        if #available(macOS 13.0, *) {
            sizingOptions = []
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        if #available(macOS 13.0, *) {
            sizingOptions = []
        }
    }

    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

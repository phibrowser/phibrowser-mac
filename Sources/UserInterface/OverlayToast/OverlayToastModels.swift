// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum OverlayToastPlacement: String, CaseIterable, Equatable {
    case topCenter
    case topTrailing
}

enum OverlayToastTarget: Equatable {
    case activeWindow
    case windowId(Int)
}

struct OverlayToastItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String?
    let duration: TimeInterval
    let placement: OverlayToastPlacement
    var shareURLs: [URL] = []
}

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

/// One optional action button on a toast ("Undo", "Show in Finder").
/// Excluded from equality: the closure has no identity, and two toasts with
/// the same id are the same toast.
struct OverlayToastAction {
    let title: String
    let handler: @MainActor () -> Void
}

struct OverlayToastItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String?
    let duration: TimeInterval
    let placement: OverlayToastPlacement
    var shareURL: URL? = nil
    var action: OverlayToastAction?

    static func == (lhs: OverlayToastItem, rhs: OverlayToastItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.duration == rhs.duration
            && lhs.placement == rhs.placement
            && lhs.shareURL == rhs.shareURL
            && (lhs.action == nil) == (rhs.action == nil)
    }
}

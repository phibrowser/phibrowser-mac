// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
// MARK: - SideTabView

struct SideTabView: View {
    static let trailingHoverDeadZoneWidth: CGFloat = 6

    var model: TabViewModel
    var onClose: (() -> Void)? = nil

    @Environment(\.phiAppearance) private var appearance

    private var backgroundColor: Color {
        if model.isActive {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        // Partner of the focused tab in a split — keep the merged-bar look
        // but muted so the focused half visually stands out.
        if model.splitPairPosition != nil && model.isSplitGroupActive {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected)).opacity(0.55)
        }
        // Inactive split group — show a subtle bar so the pair is still merged.
        if model.splitPairPosition != nil {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        if model.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        if model.isActive && appearance == .dark {
            return .white.opacity(0.2)
        }
        // Inactive split pair — outline each half so the merged bar reads as
        // a single grouped unit even when the split isn't focused. The two
        // halves' inner edges overlap at the seam and double as a thin
        // separator between the two tabs.
        if model.splitPairPosition != nil && !model.isSplitGroupActive {
            return .primary.opacity(0.1)
        }
        return .clear
    }

    private var borderWidth: CGFloat {
        if model.isActive { return 1 }
        if model.splitPairPosition != nil && !model.isSplitGroupActive { return 1 }
        return 0
    }

    /// Per-corner radius: drop the corners that touch the partner cell so
    /// two stacked pair cells visually merge into a single rounded bar.
    private var cornerRadii: RectangleCornerRadii {
        let r: CGFloat = 8
        switch model.splitPairPosition {
        case .first:
            return RectangleCornerRadii(topLeading: r, bottomLeading: 0,
                                        bottomTrailing: 0, topTrailing: r)
        case .second:
            return RectangleCornerRadii(topLeading: 0, bottomLeading: r,
                                        bottomTrailing: r, topTrailing: 0)
        case .none:
            return RectangleCornerRadii(topLeading: r, bottomLeading: r,
                                        bottomTrailing: r, topTrailing: r)
        }
    }

    /// Vertical outer padding — collapse the gap on the side that touches
    /// the partner cell so the two cells render edge-to-edge.
    private var verticalPadding: EdgeInsets {
        switch model.splitPairPosition {
        case .first:  return EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0)
        case .second: return EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0)
        case .none:   return EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        }
    }

    private var dropShadowOpacity: Double {
        if model.isActive { return 0.15 }
        // Don't drop-shadow each half of a merged bar — only the active half.
        return 0
    }

    var body: some View {
        HStack(spacing: 8) {
            UnifiedTabFaviconView(viewModel: model)
                .frame(width: 16, height: 16)

            if model.isCurrentlyAudible || model.isAudioMuted {
                UnifiedTabMuteButton(viewModel: model)
            }

            UnifiedTabTitleView(viewModel: model)

            if model.isHovered {
                UnifiedTabCloseButton { onClose?() }
            }
        }
//        .debugBorder(.green)
        .help(model.displayTitle)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
//        .debugBorder()
        .shadow(color: .black.opacity(dropShadowOpacity), radius: 1, x: 0, y: 1)
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, model.isInGroup ? 2 : WebContentConstant.edgesSpacing)
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .scaleEffect(model.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.08), value: model.isPressed)
        .onHover { hovering in
            model.setHovered(hovering)
        }
    }
}

// MARK: - Previews

#Preview("Normal Tabs") {
    VStack(spacing: 6) {
        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = "PhiBrowser"
                vm.url = "https://phibrowser.com"
                vm.isActive = true
                return vm
            }()
        )
        .frame(height: 32)

        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = ""
                vm.url = "https://example.com/some/really/long/path/to/test/truncation"
                vm.isActive = false
                return vm
            }()
        )
        .frame(height: 32)
    }
    .padding(12)
    .frame(width: 320)
}

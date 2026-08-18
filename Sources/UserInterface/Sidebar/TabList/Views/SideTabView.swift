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
    /// Peeked page's view model for the trailing indicator; only read while
    /// `model.showsPeek` is set.
    var peekModel: TabViewModel? = nil
    var onClosePeek: (() -> Void)? = nil

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private var backgroundColor: Color {
        if model.isActive {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if model.isMultiSelected {
            return ThemedColor.tabSubSelectionBackground.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
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
        return .clear
    }

    private var borderWidth: CGFloat {
        model.isActive ? 1 : 0
    }

    private var cornerRadius: CGFloat { 8 }

    private var dropShadowOpacity: Double {
        model.isActive ? 0.15 : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            UnifiedTabFaviconView(viewModel: model)
                .frame(width: 16, height: 16)

            if model.isCurrentlyAudible || model.isAudioMuted {
                UnifiedTabMuteButton(viewModel: model)
            }

            UnifiedTabTitleView(viewModel: model)
                .themedForeground(.textPrimary)

            if model.showsPeek, let peekModel {
                SidebarPeekIndicatorView(viewModel: peekModel,
                                         onClose: { onClosePeek?() })
            }

            // While a peek is attached, the row's only close affordance is
            // the peek indicator's "minus" (same rule as the bookmark row).
            if model.isHovered, !model.showsPeek {
                UnifiedTabCloseButton { onClose?() }
            }
        }
//        .debugBorder(.green)
        .help(model.showsTabPreview ? "" : model.displayTitle)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: .black.opacity(dropShadowOpacity), radius: 1, x: 0, y: 1)
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, model.isInGroup ? 2 : WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(model.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.08), value: model.isPressed)
        .onHover { hovering in
            model.setHovered(hovering)
        }
//        .debugBorder(.red)
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

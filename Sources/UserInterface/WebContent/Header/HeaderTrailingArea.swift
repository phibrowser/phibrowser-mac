// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

struct MoreMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

struct HeaderMoreButton: View {
    let items: [MoreMenuItem]
    let onItemTap: (MoreMenuItem) -> Void
    @State var isHovering: Bool = false
    
    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    onItemTap(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: HeaderExtensionLayout.iconSize, weight: .regular))
                .foregroundStyle(.primary)
                .frame(
                    width: HeaderExtensionLayout.buttonSize,
                    height: HeaderExtensionLayout.buttonSize
                )
                .themedBackground(isHovering ? .hover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

struct HeaderTrailingArea: View {
    let availableWidth: CGFloat
    let pinnedExtensions: [Extension]
    let showDownload: Bool
    let showFeedback: Bool
    let showChat: Bool

    let extensionManager: ExtensionManager?
    let browserState: BrowserState?

    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @Binding var isDownloadPopoverShown: Bool
    @Binding var isExtensionPopoverShown: Bool

    let onFeedbackTap: () -> Void
    let onChatTap: () -> Void

    private enum Metrics {
        static let buttonSize = HeaderExtensionLayout.buttonSize
        static let extensionSpacing = HeaderExtensionLayout.itemSpacing
        static let slotPadding: CGFloat = 6
        static let trailingPadding: CGFloat = 6

        static let extensionMenuWidth = buttonSize
        /// Each pinned extension adds buttonSize + spacing inside the capsule
        static let pinnedExtensionSlot = buttonSize + extensionSpacing
        static let downloadSlot = slotPadding + buttonSize
        static let moreButtonSlot = slotPadding + buttonSize
        /// Matches FeedbackButtonSwiftUI.fullWidth (90)
        static let feedbackSlot: CGFloat = slotPadding + 90
        /// ChatButton fixed width (62)
        static let chatSlot: CGFloat = slotPadding + 62
    }

    private struct LayoutConfig {
        var visiblePinnedCount: Int
        var showDownload: Bool
        var showFeedback: Bool
        var moreItems: [MoreMenuItem]
    }

    var body: some View {
        let config = resolveLayout(for: availableWidth)
        variant(
            pinned: Array(pinnedExtensions.prefix(config.visiblePinnedCount)),
            download: config.showDownload,
            feedback: config.showFeedback,
            moreItems: config.moreItems
        )
    }

    /// Collapse order (first to collapse → last):  Feedback → Pinned extensions (last→first) → Download
    private func resolveLayout(for width: CGFloat) -> LayoutConfig {
        let feedbackMenuItem = MoreMenuItem(
            id: "feedback",
            title: NSLocalizedString("Feedback", comment: "Header more menu - Feedback action"),
            systemImage: "bubble.left"
        )
        let downloadMenuItem = MoreMenuItem(
            id: "download",
            title: NSLocalizedString("Downloads", comment: "Header more menu - Downloads action"),
            systemImage: "arrow.down.circle"
        )

        var budget = width - Metrics.trailingPadding - Metrics.extensionMenuWidth
        if showChat { budget -= Metrics.chatSlot }

        let allPinnedCost = CGFloat(pinnedExtensions.count) * Metrics.pinnedExtensionSlot
        let dlCost = showDownload ? Metrics.downloadSlot : 0
        let fbCost = showFeedback ? Metrics.feedbackSlot : 0

        if allPinnedCost + dlCost + fbCost <= budget {
            return LayoutConfig(
                visiblePinnedCount: pinnedExtensions.count,
                showDownload: showDownload,
                showFeedback: showFeedback,
                moreItems: []
            )
        }

        budget -= Metrics.moreButtonSlot
        var moreItems: [MoreMenuItem] = []
        var localShowFeedback = showFeedback
        var localShowDownload = showDownload
        var visiblePinned = pinnedExtensions.count

        func currentCost() -> CGFloat {
            var cost: CGFloat = 0
            if localShowFeedback { cost += Metrics.feedbackSlot }
            if localShowDownload { cost += Metrics.downloadSlot }
            cost += CGFloat(visiblePinned) * Metrics.pinnedExtensionSlot
            return cost
        }

        if currentCost() > budget && localShowFeedback {
            localShowFeedback = false
            moreItems.append(feedbackMenuItem)
        }

        while currentCost() > budget && visiblePinned > 0 {
            visiblePinned -= 1
        }

        if currentCost() > budget && localShowDownload {
            localShowDownload = false
            moreItems.append(downloadMenuItem)
        }

        return LayoutConfig(
            visiblePinnedCount: visiblePinned,
            showDownload: localShowDownload,
            showFeedback: localShowFeedback,
            moreItems: moreItems
        )
    }

    @ViewBuilder
    private func variant(
        pinned: [Extension],
        download: Bool,
        feedback: Bool,
        moreItems: [MoreMenuItem]
    ) -> some View {
        HStack(spacing: 0) {
            extensionArea(pinned: pinned)

            if download {
                downloadButton
                    .padding(.leading, 6)
            }

            if !moreItems.isEmpty {
                let downloadCollapsed = moreItems.contains { $0.id == "download" }
                HeaderMoreButton(items: moreItems) { item in
                    handleMoreItemTap(item)
                }
                .padding(.leading, 6)
                .popover(
                    isPresented: downloadCollapsed ? $isDownloadPopoverShown : .constant(false),
                    arrowEdge: .bottom
                ) {
                    downloadPopoverContent
                }
            }

            if feedback {
                FeedbackButtonSwiftUI(action: onFeedbackTap)
                    .padding(.leading, 6)
            }

            if showChat {
                ChatButton(action: onChatTap)
                    .frame(width: 62)
                    .padding(.leading, 6)
            }
        }
        .padding(.trailing, 6)
    }

    private func handleMoreItemTap(_ item: MoreMenuItem) {
        switch item.id {
        case "feedback":
            onFeedbackTap()
        case "download":
            isDownloadPopoverShown.toggle()
        default:
            break
        }
    }

    @ViewBuilder
    private func extensionArea(pinned: [Extension]) -> some View {
        if pinned.isEmpty {
            HeaderExtensionMenuButton(
                extensionManager: extensionManager,
                isPopoverShown: $isExtensionPopoverShown
            )
        } else {
            HeaderExtensionContainer(
                pinnedExtensions: pinned,
                extensionManager: extensionManager,
                browserState: browserState,
                isPopoverShown: $isExtensionPopoverShown
            )
        }
    }

    @ViewBuilder
    private var downloadPopoverContent: some View {
        if let manager = downloadViewModel.downloadsManager {
            DownloadsListView(downloadsManager: manager)
                .frame(width: 340, height: 317)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            onTap: {
                isDownloadPopoverShown.toggle()
            }
        )
        .popover(isPresented: $isDownloadPopoverShown, arrowEdge: .bottom) {
            downloadPopoverContent
        }
    }
}

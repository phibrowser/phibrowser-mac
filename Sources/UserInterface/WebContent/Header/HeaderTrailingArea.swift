// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Shared vertical size for the web content header trailing stack (`WebContentHeaderView` + `HeaderTrailingArea`).
enum HeaderTrailingLayout {
    static let rowHeight: CGFloat = 26
}

enum MoreMenuItemIcon {
    case system(String)
    case image(Image)
}

struct MoreMenuItem: Identifiable {
    let id: String
    let title: String
    let icon: MoreMenuItemIcon

    init(id: String, title: String, icon: MoreMenuItemIcon) {
        self.id = id
        self.title = title
        self.icon = icon
    }

    init(id: String, title: String, systemImage: String) {
        self.init(id: id, title: title, icon: .system(systemImage))
    }

    init(id: String, title: String, image: Image) {
        self.init(id: id, title: title, icon: .image(image))
    }
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
                    Label {
                        Text(item.title)
                    } icon: {
                        switch item.icon {
                        case .system(let name):
                            Image(systemName: name)
                        case .image(let image):
                            image
                        }
                    }
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
                .clipShape(Circle())
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
    let showMemory: Bool
    let showFeedback: Bool
    let showChat: Bool

    let extensionManager: ExtensionManager?
    let browserState: BrowserState?

    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @Binding var isDownloadPopoverShown: Bool
    @Binding var isExtensionPopoverShown: Bool

    let onFeedbackTap: () -> Void
    let onChatTap: () -> Void
    let onMemoryTap: () -> Void

    private enum Metrics {
        static let buttonSize = HeaderExtensionLayout.buttonSize
        static let extensionSpacing = HeaderExtensionLayout.itemSpacing
        static let slotPadding: CGFloat = 6
        static let trailingPadding: CGFloat = 6

        static let extensionMenuWidth = buttonSize
        /// Each pinned extension adds buttonSize + spacing inside the capsule
        static let pinnedExtensionSlot = buttonSize + extensionSpacing
        static let downloadSlot = slotPadding + buttonSize
        static let memorySlot = slotPadding + buttonSize
        static let moreButtonSlot = slotPadding + buttonSize
        /// FeedbackButton width in trailing area (100)
        static let feedbackSlot: CGFloat = slotPadding + 100
        /// ChatButton fixed width (60)
        static let chatSlot: CGFloat = slotPadding + 60
    }

    private struct LayoutConfig {
        var visiblePinnedCount: Int
        var showDownload: Bool
        var showMemory: Bool
        var showFeedback: Bool
        var moreItems: [MoreMenuItem]
    }

    var body: some View {
        let config = resolveLayout(for: availableWidth)
        variant(
            pinned: Array(pinnedExtensions.prefix(config.visiblePinnedCount)),
            memory: config.showMemory,
            download: config.showDownload,
            feedback: config.showFeedback,
            moreItems: config.moreItems
        )
    }

    /// Collapse order (first to collapse → last):  Feedback → Pinned extensions (last→first) → Memory → Download
    private func resolveLayout(for width: CGFloat) -> LayoutConfig {
        let feedbackMenuItem = MoreMenuItem(
            id: "feedback",
            title: NSLocalizedString("Feedback", comment: "Header more menu - Feedback action"),
            image: Image(.sidebarFeedback)
        )
        let downloadMenuItem = MoreMenuItem(
            id: "download",
            title: NSLocalizedString("Downloads", comment: "Header more menu - Downloads action"),
            systemImage: "arrow.down.circle"
        )
        let memoryMenuItem = MoreMenuItem(
            id: "memory",
            title: NSLocalizedString("Browser Memory", comment: "Header more menu - AI memory"),
            image: Image(.memoryIcon).renderingMode(.original)
        )

        var budget = width - Metrics.trailingPadding - Metrics.extensionMenuWidth
        if showChat { budget -= Metrics.chatSlot }

        let allPinnedCost = CGFloat(pinnedExtensions.count) * Metrics.pinnedExtensionSlot
        let dlCost = showDownload ? Metrics.downloadSlot : 0
        let memoryCost = showMemory ? Metrics.memorySlot : 0
        let fbCost = showFeedback ? Metrics.feedbackSlot : 0

        if allPinnedCost + dlCost + memoryCost + fbCost <= budget {
            return LayoutConfig(
                visiblePinnedCount: pinnedExtensions.count,
                showDownload: showDownload,
                showMemory: showMemory,
                showFeedback: showFeedback,
                moreItems: []
            )
        }

        budget -= Metrics.moreButtonSlot
        var moreItems: [MoreMenuItem] = []
        var localShowFeedback = showFeedback
        var localShowDownload = showDownload
        var localShowMemory = showMemory
        var visiblePinned = pinnedExtensions.count

        func currentCost() -> CGFloat {
            var cost: CGFloat = 0
            if localShowFeedback { cost += Metrics.feedbackSlot }
            if localShowDownload { cost += Metrics.downloadSlot }
            if localShowMemory { cost += Metrics.memorySlot }
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

        if currentCost() > budget && localShowMemory {
            localShowMemory = false
            moreItems.append(memoryMenuItem)
        }

        if currentCost() > budget && localShowDownload {
            localShowDownload = false
            moreItems.append(downloadMenuItem)
        }

        return LayoutConfig(
            visiblePinnedCount: visiblePinned,
            showDownload: localShowDownload,
            showMemory: localShowMemory,
            showFeedback: localShowFeedback,
            moreItems: moreItems
        )
    }

    @ViewBuilder
    private func variant(
        pinned: [Extension],
        memory: Bool,
        download: Bool,
        feedback: Bool,
        moreItems: [MoreMenuItem]
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            extensionArea(pinned: pinned)

            if memory {
                MemoryButton(action: onMemoryTap, useCircularHoverShape: true)
                    .padding(.leading, 6)
            }

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
                FeedbackButtonSwiftUI(
                    action: onFeedbackTap,
                    contentWidth: 100,
                    contentHeight: HeaderTrailingLayout.rowHeight
                )
                .padding(.leading, 6)
            }

            if showChat {
                ChatButton(
                    action: onChatTap,
                    contentWidth: 60,
                    contentHeight: HeaderTrailingLayout.rowHeight
                )
                .padding(.leading, 6)
            }
        }
        .frame(height: HeaderTrailingLayout.rowHeight)
        .padding(.trailing, 6)
    }

    private func handleMoreItemTap(_ item: MoreMenuItem) {
        switch item.id {
        case "feedback":
            onFeedbackTap()
        case "download":
            isDownloadPopoverShown.toggle()
        case "memory":
            onMemoryTap()
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
            useCircularHoverShape: true,
            onTap: {
                isDownloadPopoverShown.toggle()
            }
        )
        .popover(isPresented: $isDownloadPopoverShown, arrowEdge: .bottom) {
            downloadPopoverContent
        }
    }
}

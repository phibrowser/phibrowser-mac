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
    @Environment(\.colorScheme) private var colorScheme
    let availableWidth: CGFloat
    let pinnedExtensions: [Extension]
    let showDownload: Bool
    let showMemory: Bool
    let showFeedback: Bool
    let feedbackIconOnly: Bool
    let showChat: Bool
    let isInPlaceholderMode: Bool

    let extensionManager: ExtensionManager?
    let browserState: BrowserState?

    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @Binding var isDownloadPopoverShown: Bool
    @Binding var isExtensionPopoverShown: Bool

    let onFeedbackTap: () -> Void
    let onChatTap: () -> Void
    let onMemoryTap: () -> Void
    let onDownloadTap: () -> Void
    var onChatAnchorResolved: ((NSView?) -> Void)? = nil

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
        static let feedbackButtonWidth: CGFloat = 100
        static let feedbackIconWidth: CGFloat = 32
        /// ChatButton's localized content width plus its leading spacing.
        static var chatSlot: CGFloat { slotPadding + ChatButton.preferredContentWidth }

        static func feedbackSlot(iconOnly: Bool) -> CGFloat {
            slotPadding + (iconOnly ? feedbackIconWidth : feedbackButtonWidth)
        }
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

    /// Which trailing items fit at a given width: everything about the
    /// layout that the width decides. `WebContentHeaderView` compares it to
    /// re-render only when a width change moves an item in or out.
    struct WidthFit: Equatable {
        var visiblePinnedCount: Int
        var showDownload: Bool
        var showMemory: Bool
        var showFeedback: Bool
    }

    /// Collapse order (first to collapse → last):  Feedback → Pinned extensions (last→first) → Memory → Download
    static func widthFit(
        availableWidth width: CGFloat,
        pinnedCount: Int,
        showDownload: Bool,
        showMemory: Bool,
        showFeedback: Bool,
        feedbackIconOnly: Bool,
        showChat: Bool
    ) -> WidthFit {
        var budget = width - Metrics.trailingPadding - Metrics.extensionMenuWidth
        if showChat { budget -= Metrics.chatSlot }

        var fit = WidthFit(
            visiblePinnedCount: pinnedCount,
            showDownload: showDownload,
            showMemory: showMemory,
            showFeedback: showFeedback
        )
        func currentCost() -> CGFloat {
            var cost: CGFloat = 0
            if fit.showFeedback {
                cost += Metrics.feedbackSlot(iconOnly: feedbackIconOnly)
            }
            if fit.showDownload { cost += Metrics.downloadSlot }
            if fit.showMemory { cost += Metrics.memorySlot }
            cost += CGFloat(fit.visiblePinnedCount) * Metrics.pinnedExtensionSlot
            return cost
        }

        if currentCost() <= budget { return fit }

        budget -= Metrics.moreButtonSlot
        if currentCost() > budget && fit.showFeedback {
            fit.showFeedback = false
        }
        while currentCost() > budget && fit.visiblePinnedCount > 0 {
            fit.visiblePinnedCount -= 1
        }
        if currentCost() > budget && fit.showMemory {
            fit.showMemory = false
        }
        if currentCost() > budget && fit.showDownload {
            fit.showDownload = false
        }
        return fit
    }

    private func resolveLayout(for width: CGFloat) -> LayoutConfig {
        let fit = Self.widthFit(
            availableWidth: width,
            pinnedCount: pinnedExtensions.count,
            showDownload: showDownload,
            showMemory: showMemory,
            showFeedback: showFeedback,
            feedbackIconOnly: feedbackIconOnly,
            showChat: showChat
        )
        // Collapsed items go to the More menu in the order they collapsed.
        var moreItems: [MoreMenuItem] = []
        if showFeedback && !fit.showFeedback {
            moreItems.append(MoreMenuItem(
                id: "feedback",
                title: NSLocalizedString("browser.headerMoreMenu.feedbackAction", value: "Feedback", comment: "Header more menu - Feedback action"),
                image: Image(.sidebarFeedback)
            ))
        }
        if showMemory && !fit.showMemory {
            moreItems.append(MoreMenuItem(
                id: "memory",
                title: NSLocalizedString("browser.headerMoreMenu.memoryAction", value: "Browser Memory", comment: "Header more menu - AI memory"),
                image: Image(.memoryIcon).renderingMode(.original)
            ))
        }
        if showDownload && !fit.showDownload {
            moreItems.append(MoreMenuItem(
                id: "download",
                title: NSLocalizedString("browser.headerMoreMenu.downloadsAction", value: "Downloads", comment: "Header more menu - Downloads action"),
                systemImage: "arrow.down.circle"
            ))
        }
        return LayoutConfig(
            visiblePinnedCount: fit.visiblePinnedCount,
            showDownload: fit.showDownload,
            showMemory: fit.showMemory,
            showFeedback: fit.showFeedback,
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
            if !isInPlaceholderMode {
                extensionArea(pinned: pinned)
            }

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
                    isIconOnly: feedbackIconOnly,
                    contentWidth: feedbackIconOnly ? nil : Metrics.feedbackButtonWidth,
                    contentHeight: HeaderTrailingLayout.rowHeight
                )
                .padding(.leading, 6)
            }

            if showChat {
                ChatButton(
                    action: onChatTap,
                    contentWidth: ChatButton.preferredContentWidth,
                    contentHeight: HeaderTrailingLayout.rowHeight
                )
                .background(chatAnchorBackground)
                .padding(.leading, 6)
            }
        }
        .frame(height: HeaderTrailingLayout.rowHeight)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private var chatAnchorBackground: some View {
        if let onChatAnchorResolved {
            HeaderControlAnchorView { view in
                onChatAnchorResolved(view)
            }
        }
    }

    private func handleMoreItemTap(_ item: MoreMenuItem) {
        switch item.id {
        case "feedback":
            onFeedbackTap()
        case "download":
            onDownloadTap()
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
                browserState: browserState,
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
            DownloadsListView(downloadsManager: manager) {
                isDownloadPopoverShown = false
                guard let owner = browserState?.windowController,
                      let source = owner.window?.contentView else { return }
                owner.showLibrary(from: source, section: .downloads)
            }
                .frame(width: 340, height: 317)
                .preferredColorScheme(colorScheme)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            useCircularHoverShape: true,
            onTap: {
                onDownloadTap()
                isDownloadPopoverShown.toggle()
            }
        )
        .popover(isPresented: $isDownloadPopoverShown, arrowEdge: .bottom) {
            downloadPopoverContent
        }
    }
}

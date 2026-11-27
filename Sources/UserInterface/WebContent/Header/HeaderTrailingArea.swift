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

/// Which Right-zone items fold into the overflow "…" when the toolbar runs out of room.
enum ToolbarOverflow {
    struct Fit: Equatable {
        var visible: [ToolbarItemID]
        var folded: [ToolbarItemID]
    }

    /// Folds Feedback first, then extensions from the last, then Memory, then
    /// Downloads, reserving `overflowButtonWidth` once anything folds. Items
    /// that do not fold stay even when they do not fit.
    static func fit(
        _ items: [ToolbarItemID],
        width: (ToolbarItemID) -> CGFloat,
        available: CGFloat,
        overflowButtonWidth: CGFloat
    ) -> Fit {
        var cost = items.reduce(0) { $0 + width($1) }
        guard cost > available else { return Fit(visible: items, folded: []) }

        let budget = available - overflowButtonWidth
        let extensions = items.filter { if case .extensionAction = $0 { return true } else { return false } }
        let foldOrder = items.filter { $0 == .feedback }
            + extensions.reversed()
            + items.filter { $0 == .memory }
            + items.filter { $0 == .downloads }
        var folded: [ToolbarItemID] = []
        for item in foldOrder where cost > budget {
            folded.append(item)
            cost -= width(item)
        }
        return Fit(visible: items.filter { !folded.contains($0) }, folded: folded)
    }

    /// The items the "…" menu lists, in fold order.
    static let menuItems: [ToolbarItemID] = [.feedback, .memory, .downloads]

    /// Where the "…" goes among `fit.visible`, or nil when it lists nothing
    /// (folded extensions stay in the extensions menu). It takes the arranged
    /// slot of the first listed item in fold order that is in the zone, shown
    /// or not, so the default arrangement keeps today's spot (Feedback's slot)
    /// even while Feedback is hidden.
    static func overflowIndex(arranged: [ToolbarItemID], fit: Fit) -> Int? {
        guard fit.folded.contains(where: menuItems.contains),
              let anchor = menuItems.lazy.compactMap({ arranged.firstIndex(of: $0) }).first else {
            return nil
        }
        return fit.visible.filter { (arranged.firstIndex(of: $0) ?? 0) < anchor }.count
    }
}

/// The Right zone: its items in arrangement order, with the overflow "…".
struct HeaderTrailingArea: View {
    @Environment(\.colorScheme) private var colorScheme
    let availableWidth: CGFloat
    /// The zone's items that show right now, in drawing order.
    let items: [ToolbarItemID]
    /// The zone's items as arranged, shown or not.
    let arranged: [ToolbarItemID]
    let actions: ToolbarItemActions
    @ObservedObject var state: WebContentHeaderState

    static let trailingPadding: CGFloat = 6
    private static let slotPadding: CGFloat = 6
    static var overflowSlotWidth: CGFloat { slotPadding + HeaderExtensionLayout.buttonSize }

    /// Each item's width in this zone, including its spacing before it. The
    /// extensions button and its pinned icons share a capsule with no outer
    /// spacing, as today.
    static func slotWidth(for item: ToolbarItemID) -> CGFloat {
        switch item {
        case .extensionsButton: return HeaderExtensionLayout.buttonSize
        case .extensionAction: return HeaderExtensionLayout.buttonSize + HeaderExtensionLayout.itemSpacing
        case .chat: return slotPadding + ChatButton.preferredContentWidth
        default: return slotPadding + HeaderExtensionLayout.buttonSize
        }
    }

    static func fit(items: [ToolbarItemID], availableWidth: CGFloat) -> ToolbarOverflow.Fit {
        ToolbarOverflow.fit(
            items,
            width: slotWidth(for:),
            available: availableWidth - trailingPadding,
            overflowButtonWidth: overflowSlotWidth
        )
    }

    var body: some View {
        let fit = Self.fit(items: items, availableWidth: availableWidth)
        // Folded items go to the More menu in the order they folded; folded
        // extensions stay reachable from the extensions menu instead.
        let moreItems = fit.folded.compactMap(Self.moreMenuItem(for:))
        let overflowAnchor = ToolbarOverflow.overflowIndex(arranged: arranged, fit: fit)
        // While customizing nothing folds (the header lifts the width limit).
        ToolbarZoneRow(
            segments: ToolbarZoneSegment.segments(fit.visible, overflowAnchor: overflowAnchor),
            spacing: Self.slotPadding,
            zone: .right,
            actions: actions,
            state: state
        ) {
            moreButton(items: moreItems)
        }
        // An empty zone reserves its drop target's width while customizing.
        .frame(
            width: ToolbarCustomizationLayout.sideZoneReserve(isEmpty: fit.visible.isEmpty, isCustomizing: actions.customization != nil),
            height: HeaderTrailingLayout.rowHeight
        )
        .toolbarCustomizationZone(.right, isEmpty: fit.visible.isEmpty, customization: actions.customization)
        .padding(.trailing, Self.trailingPadding)
    }

    private static func moreMenuItem(for item: ToolbarItemID) -> MoreMenuItem? {
        switch item {
        case .feedback:
            return MoreMenuItem(
                id: "feedback",
                title: NSLocalizedString("browser.headerMoreMenu.feedbackAction", value: "Feedback", comment: "Header more menu - Feedback action"),
                image: Image(.sidebarFeedback)
            )
        case .memory:
            return MoreMenuItem(
                id: "memory",
                title: NSLocalizedString("browser.headerMoreMenu.memoryAction", value: "Browser Memory", comment: "Header more menu - AI memory"),
                image: Image(.memoryIcon).renderingMode(.original)
            )
        case .downloads:
            return MoreMenuItem(
                id: "download",
                title: NSLocalizedString("browser.headerMoreMenu.downloadsAction", value: "Downloads", comment: "Header more menu - Downloads action"),
                systemImage: "arrow.down.circle"
            )
        default:
            return nil
        }
    }

    private func moreButton(items moreItems: [MoreMenuItem]) -> some View {
        let downloadCollapsed = moreItems.contains { $0.id == "download" }
        return HeaderMoreButton(items: moreItems) { item in
            handleMoreItemTap(item)
        }
        .popover(
            isPresented: downloadCollapsed ? $state.isDownloadPopoverShown : .constant(false),
            arrowEdge: .bottom
        ) {
            HeaderDownloadsPopoverContent(
                downloadViewModel: actions.downloadViewModel,
                colorScheme: colorScheme,
                browserState: actions.browserState,
                isShown: $state.isDownloadPopoverShown
            )
        }
    }

    private func handleMoreItemTap(_ item: MoreMenuItem) {
        switch item.id {
        case "feedback":
            actions.onFeedbackTap()
        case "download":
            actions.onDownloadTap()
            state.isDownloadPopoverShown.toggle()
        case "memory":
            actions.onMemoryTap()
        default:
            break
        }
    }
}

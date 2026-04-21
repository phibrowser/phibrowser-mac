// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

enum HeaderExtensionLayout {
    static let buttonSize: CGFloat = 24
    static let iconSize: CGFloat = 14
    static let itemSpacing: CGFloat = 2
}

@Observable
@MainActor
final class WebContentHeaderExtensionsModel {
    private(set) var pinnedExtensions: [Extension] = []

    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()

    init(browserState: BrowserState?) {
        self.browserState = browserState
        bindExtensions()
        refreshExtensionsIfNeeded()
    }

    private func bindExtensions() {
        guard let manager = browserState?.extensionManager else { return }

        manager.$pinedExtensions
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] exts in
                let sorted = exts.sorted { lhs, rhs in
                    if lhs.pinnedIndex == rhs.pinnedIndex {
                        return lhs.name < rhs.name
                    }
                    return lhs.pinnedIndex < rhs.pinnedIndex
                }
                self?.pinnedExtensions = sorted
            }
            .store(in: &cancellables)
    }

    private func refreshExtensionsIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.browserState?.extensionManager.refreshExtensions()
        }
    }
}

struct CircularIconButton: View {
    let image: NSImage?
    let imageResource: ImageResource?
    let systemName: String?
    let accessibilityLabel: String
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    @State private var isHovering = false

    init(
        image: NSImage? = nil,
        imageResource: ImageResource? = nil,
        systemName: String? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.image = image
        self.imageResource = imageResource
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? .sidebarTabHoveredColorEmphasized : Color.clear)

                if let imageResource {
                    Image(imageResource)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: HeaderExtensionLayout.iconSize, weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: HeaderExtensionLayout.buttonSize, height: HeaderExtensionLayout.buttonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .overlay(
            SecondaryClickPassthrough(onSecondaryClick: secondaryAction)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

struct HeaderExtensionMenuButton: View {
    let extensionManager: ExtensionManager?
    @Binding var isPopoverShown: Bool

    @State private var anchorView: NSView?

    var body: some View {
        CircularIconButton(
            imageResource: .extensionIcon,
            accessibilityLabel: NSLocalizedString("Extensions", comment: "Web content header - Extensions menu button")
        ) {
            isPopoverShown.toggle()
        }
        .background(
            AddressBarAnchorView { view in
                anchorView = view
            }
            .allowsHitTesting(false)
        )
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    needSettings: false,
                    onRequestDismiss: { isPopoverShown = false },
                    triggerAnchorView: anchorView
                )
            }
        }
    }
}

struct HeaderExtensionContainer: View {
    let pinnedExtensions: [Extension]
    let extensionManager: ExtensionManager?
    let browserState: BrowserState?
    @Binding var isPopoverShown: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: HeaderExtensionLayout.itemSpacing) {
            ForEach(pinnedExtensions) { ext in
                PinnedExtensionButton(
                    ext: ext,
                    windowId: browserState?.windowId.int64Value ?? 0
                )
            }
            HeaderExtensionMenuButton(
                extensionManager: extensionManager,
                isPopoverShown: $isPopoverShown
            )
        }
        .frame(height: HeaderTrailingLayout.rowHeight)
        .background(
            Capsule()
                .themedStroke(.border)
                .opacity(isHovering ? 1 : 0)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct PinnedExtensionButton: View {
    let ext: Extension
    let windowId: Int64

    @State private var anchorView: NSView?

    var body: some View {
        let image = ext.icon
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            ?? NSImage()

        CircularIconButton(
            image: image,
            accessibilityLabel: ext.name,
            action: {
                let point = anchorView.flatMap(ExtensionPopupAnchor.pointBelowView)
                    ?? ExtensionPopupAnchor.mouseFallback()
                ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
                    withId: ext.id,
                    pointInScreen: point,
                    windowId: windowId
                )
            },
            secondaryAction: {
                let point = anchorView.flatMap(ExtensionPopupAnchor.pointBelowView)
                    ?? ExtensionPopupAnchor.mouseFallback()
                ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                    withId: ext.id,
                    pointInScreen: point,
                    windowId: windowId
                )
            }
        )
        .background(
            AddressBarAnchorView { view in
                anchorView = view
            }
            .allowsHitTesting(false)
        )
    }
}

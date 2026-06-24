// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Right-side buttons area for the TabStrip bar
/// Contains CardEntryButton and future buttons
struct TabStripRightButtons: View {
    @ObservedObject var cardManager: NotificationCardManager
    let onCardEntryTap: () -> Void
    let onSearchTabsTap: (NSView?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if showCardEntry {
                CardEntryButton(action: onCardEntryTap)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity
                        )
                    )
            }

            TabStripSearchTabsButton(action: onSearchTabsTap)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCardEntry)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
//        .offset(y: -4) // Visual alignment adjustment
        .ignoresSafeArea()
    }
    
    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }
}

private struct TabStripSearchTabsButton: View {
    let action: (NSView?) -> Void

    @State private var isHovering = false
    @State private var anchorView: NSView?

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    private var searchTabsLabel: String {
        NSLocalizedString("Search Tabs", comment: "Search Tabs - Button tooltip and accessibility label")
    }

    var body: some View {
        Button {
            action(anchorView)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
                .background(
                    TabStripSearchTabsAnchorReader { anchorView in
                        self.anchorView = anchorView
                    }
                )
        }
        .buttonStyle(.plain)
        .frame(width: buttonSize, height: buttonSize)
        .help(searchTabsLabel)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(Text(searchTabsLabel))
    }
}

private struct TabStripSearchTabsAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughAnchorView()
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }

    private final class PassthroughAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

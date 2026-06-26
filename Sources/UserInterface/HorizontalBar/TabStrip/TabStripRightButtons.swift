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

    // Organize-tabs is an AI feature; hide it when AI is disabled (Kensington
    // isn't running then). `@AppStorage` keeps it reactive to the toggle.
    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

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

            if phiAIEnabled {
                TabStripFarringdonButton()
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

/// "Organize tabs with AI" (Farringdon) button for the horizontal tab strip,
/// shown next to the search button. Triggers the same focused-window organize run
/// as the sidebar broom and sweeps while a run is in progress (driven by the
/// shared `.farringdonOrganizeDidStart` / `.farringdonOrganizeDidFinish` events).
private struct TabStripFarringdonButton: View {
    @State private var isHovering = false
    @State private var isOrganizing = false
    @State private var sweepAngle: Double = 0

    private let buttonSize: CGFloat = 24
    private let iconSize: CGFloat = 22
    private let cornerRadius: CGFloat = 6
    private let sweepAmplitude: Double = 16
    private static let safetyTimeout: TimeInterval = 8.0

    private var label: String {
        NSLocalizedString(
            "Organize tabs with AI",
            comment: "Organize Tabs - Button tooltip and accessibility label")
    }

    var body: some View {
        Button {
            guard !isOrganizing else { return }
            FarringdonOrganizer.organizeFocusedWindow()
        } label: {
            Image("farringdon-broom")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(Color.primary)
                .rotationEffect(.degrees(sweepAngle))
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .frame(width: buttonSize, height: buttonSize)
        .help(label)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(Text(label))
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidStart)) { _ in
            startSweep()
        }
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidFinish)) { _ in
            stopSweep()
        }
    }

    private func startSweep() {
        guard !isOrganizing else { return }
        isOrganizing = true
        sweepAngle = -sweepAmplitude
        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
            sweepAngle = sweepAmplitude
        }
        // Stop even if the completion signal never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.safetyTimeout) {
            stopSweep()
        }
    }

    private func stopSweep() {
        guard isOrganizing else { return }
        isOrganizing = false
        withAnimation(.easeInOut(duration: 0.2)) {
            sweepAngle = 0
        }
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

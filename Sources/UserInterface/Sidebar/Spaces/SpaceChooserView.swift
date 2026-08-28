// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Borderless overlay window that is allowed to become key so its SwiftUI
/// content receives clicks and keyboard shortcuts. Hosted above a browser
/// window (as a child window) to present the Space chooser over a dimmed
/// backdrop. A child window moves with its parent and stays above it.
final class SpaceChooserOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// One row in the Space chooser. Colors are resolved by the presenter from the
/// Space's theme, so this view stays free of ThemeManager / appearance lookups.
struct SpaceChooserItem: Identifiable {
    let id: String          // Space id or action-destination wire id
    let name: String
    let iconName: String
    let isCurrent: Bool
    /// Draw a divider before this destination. Kiosk uses this to remain a
    /// distinct action below the Space choices while staying in the same
    /// keyboard-navigation order.
    let startsSection: Bool
    /// The Space theme's signature color (ColorRole.themeColor).
    let themeColor: Color
    /// A legible icon/text color on top of `themeColor`.
    let textColor: Color
}

/// Modal "Open in which Space?" prompt shown when a navigation matches an
/// "ask every time" URL rule. Dims the source window behind a centered list of
/// destinations: Spaces first (the current one first), then Kiosk in its own
/// section. Replaces the old NSAlert + popup button.
///
/// `onChoose` is invoked exactly once: with the chosen destination id, or with
/// nil when the user keeps the page where it is (Esc, or a tap on the dimmed
/// backdrop). The presenter owns dismissal.
struct SpaceChooserView: View {
    /// Every Space, ordered with the current one first.
    let items: [SpaceChooserItem]
    /// The window's overlay-background color (its alpha is the user's Opacity
    /// setting), layered over the blur so the box matches window translucency.
    let boxBackground: Color
    let onChoose: (String?) -> Void

    @State private var selection: String
    @FocusState private var focused: Bool

    init(items: [SpaceChooserItem],
         boxBackground: Color,
         onChoose: @escaping (String?) -> Void) {
        self.items = items
        self.boxBackground = boxBackground
        self.onChoose = onChoose
        _selection = State(initialValue: items.first?.id ?? "")
    }

    var body: some View {
        ZStack {
            // Dim everything behind the list. A tap on the backdrop (or Esc)
            // keeps the page where it is.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onChoose(nil) }
            spaceList
                .padding(8)
                .frame(width: 300)
                // Overlay tint (carries the Opacity setting) over a blur, so
                // the box reads as translucent like the window itself.
                .background(boxBackground, in: RoundedRectangle(cornerRadius: 16))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { onChoose(selection); return .handled }
        .onKeyPress(.escape) { onChoose(nil); return .handled }
    }

    private var spaceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        if item.startsSection {
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        }
                        row(for: item).id(item.id)
                    }
                }
            }
            .frame(height: listHeight)
            .onChange(of: selection) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    /// Each row shows the destination's icon and name and opens it on click.
    /// Space rows use their theme color; action destinations use a neutral
    /// tint. Keyboard navigation moves the highlighted `selection` (also
    /// followed by hover); Return opens it.
    private func row(for item: SpaceChooserItem) -> some View {
        let isSelected = selection == item.id
        // The keyboard/hover selection gets a distinct accent highlight so it
        // always stands out; every other Space — including the current one —
        // shows its own theme color.
        let background: Color = isSelected ? Color.accentColor.opacity(0.22) : item.themeColor
        let foreground: Color = isSelected ? .primary : item.textColor
        return HStack(spacing: 10) {
            SpaceIconView(storedValue: item.iconName,
                          size: 16,
                          symbolWeight: .regular,
                          tint: foreground)
            Text(item.name)
                .fontWeight(.medium)
            if item.isCurrent {
                Text(NSLocalizedString("sidebar.spaceChooser.currentStatus", value: "Current",
                    comment: "Marks the Space the user is currently in, in the ask-Space list"))
                    .font(.caption)
                    .opacity(0.6)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            if hovering { selection = item.id }
        }
        .onTapGesture { onChoose(item.id) }
    }

    /// Hugs the rows (38pt each + 6pt gaps) and section dividers up to a cap,
    /// so a few destinations don't leave a tall empty area but many still
    /// scroll.
    private var listHeight: CGFloat {
        let count = CGFloat(items.count)
        let content = count * 38 + max(0, count - 1) * 6
        // One extra VStack gap plus the divider's line and vertical padding.
        let sectionHeight = CGFloat(items.filter(\.startsSection).count) * 11
        return min(content + sectionHeight, 360)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selection } ?? 0
        let nextIndex = max(0, min(items.count - 1, currentIndex + delta))
        selection = items[nextIndex].id
    }
}

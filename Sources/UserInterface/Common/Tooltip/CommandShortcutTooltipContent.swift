// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

struct CommandShortcutTooltipContent: View {
    /// With two keycaps the card stays near the 320pt cap of
    /// `DefaultCustomTooltipContent`.
    private static let titleMaxWidth: CGFloat = 240

    let title: String
    let command: CommandWrapper

    @State private var shortcut: ShortcutsKey?
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    init(title: String, command: CommandWrapper) {
        self.title = title
        self.command = command
        _shortcut = State(initialValue: Shortcuts.key(for: command))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.titleMaxWidth, alignment: .leading)

            if let shortcut {
                HStack(spacing: 4) {
                    ForEach(Array(shortcut.keycapTokens.enumerated()), id: \.offset) { _, token in
                        keycap(token)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Near-opaque white / black over the material, matching the Space hover
        // card: the bare material reads as gray in light mode.
        .background(
            (appearance.isDark ? Color.black : Color.white).opacity(0.9),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: shortcut))
        .onAppear(perform: refreshShortcut)
        .onReceive(
            NotificationCenter.default
                .publisher(for: .shortcutsDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            refreshShortcut()
        }
    }

    private var accentColor: Color {
        ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
    }

    private func accessibilityLabel(for shortcut: ShortcutsKey?) -> String {
        guard let shortcut else { return title }
        return "\(title), \(shortcut.displayString)"
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accentColor.opacity(0.14))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.55))
            }
    }

    private func refreshShortcut() {
        shortcut = Shortcuts.key(for: command)
    }
}

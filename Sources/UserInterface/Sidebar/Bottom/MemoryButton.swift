// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// AI memory entry button. Reused in `SidebarBottomBar` (rounded rect hover) and
/// `WebContentHeader` trailing area (circular hover).
struct MemoryButton: View {
    let action: () -> Void
    var useCircularHoverShape: Bool = false

    @State private var isHovering = false

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6

    var body: some View {
        Button(action: action) {
            Image(.memoryIcon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    hoverBackground(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help(NSLocalizedString("sidebar.memoryButton.helpText", value: "Browser Memory",
            comment: "Memory button - Tooltip & Accessibility label for the AI memory entry button shown in the sidebar bottom bar and the web content header trailing area"
        ))
        .accessibilityLabel(NSLocalizedString("sidebar.memoryButton.accessibilityLabel", value: "Browser Memory",
            comment: "Memory button - Tooltip & Accessibility label for the AI memory entry button shown in the sidebar bottom bar and the web content header trailing area"
        ))
    }

    @ViewBuilder
    private func hoverBackground(_ fill: Color) -> some View {
        if useCircularHoverShape {
            Circle().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius).fill(fill)
        }
    }
}

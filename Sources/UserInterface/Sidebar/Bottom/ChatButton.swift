// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

// MARK: - SwiftUI ChatButton

/// Chat button that opens the AI Chat sidebar.
struct ChatButton: View {
    let action: () -> Void
    var contentWidth: CGFloat? = nil
    var contentHeight: CGFloat? = nil

    @State private var isHovering = false
    @Environment(\.phiAppearance) private var appearance
    
    // MARK: - Constants
    
    private enum Constants {
        /// Button background color.
        static let backgroundColor: ThemedColor = .themeColor
        /// Hover background color.
        static let hoveredBackgroundColor: ThemedColor = .themeColorOnHover
        /// Border color in dark appearance.
        static let borderColor = Color.white.opacity(0.4)
        /// Border width.
        static let borderWidth: CGFloat = 0
        /// Capsule corner radius.
        static let cornerRadius: CGFloat = 999
        /// Vertical padding.
        static let verticalPadding: CGFloat = 0
        /// Trailing padding.
        static let trailingPadding: CGFloat = 8
        /// Leading padding.
        static let leadingPadding: CGFloat = 0
        /// Spacing between the icon and label.
        static let spacing: CGFloat = 2
        /// Icon size.
        static let iconSize: CGFloat = 22
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: Constants.spacing) {
                Image(.sidebarChat)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Constants.iconSize, height: Constants.iconSize)
                    .foregroundColor(.white)
                
                Text(NSLocalizedString("Chat", comment: "Sidebar bottom chat button title"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.leading, Constants.leadingPadding)
            .padding(.trailing, Constants.trailingPadding)
            .padding(.vertical, Constants.verticalPadding)
            .frame(width: contentWidth, height: contentHeight)
            .themedBackground(isHovering ? Constants.hoveredBackgroundColor : Constants.backgroundColor)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Constants.borderColor, lineWidth: Constants.borderWidth)
                    .opacity(appearance.isDark ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - AppKit Wrapper

/// AppKit wrapper for `ChatButton`.
class ChatButtonNSView: NSView {
    private var hostingView: ThemedHostingView?
    private let action: () -> Void
    
    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setupHostingView(action: action)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupHostingView(action: @escaping () -> Void) {
        let hosting = ThemedHostingView(rootView: ChatButton(action: action))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        hosting.setContentHuggingPriority(.required, for: .vertical)
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        
        self.hostingView = hosting
    }
}

// MARK: - Preview

#Preview("ChatButton") {
    ChatButton {
        print("Chat button clicked")
    }
    .frame(width: 61, height: 24)
}

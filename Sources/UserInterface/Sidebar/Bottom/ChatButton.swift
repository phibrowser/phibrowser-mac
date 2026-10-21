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
    var showsTitle: Bool = true
    /// Minimum width for contexts that reserve a fixed toolbar slot.
    var contentWidth: CGFloat? = nil
    var contentHeight: CGFloat? = nil

    static var preferredContentWidth: CGFloat {
        let titleWidth = (localizedTitle as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        ).width
        return ceil(titleWidth) + Constants.iconSize + Constants.spacing + Constants.trailingPadding
    }

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

    private static var localizedTitle: String {
        NSLocalizedString(
            "sidebar.chatButton.title",
            value: "Chat",
            comment: "Sidebar bottom chat button title"
        )
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
                
                if showsTitle {
                    Text(Self.localizedTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.leading, Constants.leadingPadding)
            .padding(.trailing, showsTitle ? Constants.trailingPadding : 0)
            .padding(.vertical, Constants.verticalPadding)
            .frame(width: showsTitle ? nil : 24, height: showsTitle ? nil : 24)
            .frame(
                minWidth: contentWidth,
                minHeight: contentHeight,
                maxHeight: contentHeight
            )
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
        .fixedSize(horizontal: true, vertical: false)
        .help(Self.localizedTitle)
        .accessibilityLabel(Self.localizedTitle)
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

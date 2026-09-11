// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Status URL display view (similar to Chromium's StatusBubble)
/// Shows the target URL in a bottom corner when hovering over links
struct StatusURLView: View {
    @ObservedObject var viewModel: StatusURLViewModel

    private static let fontSize: CGFloat = 12
    private static let horizontalPadding: CGFloat = 8
    static let edgeInset: CGFloat = 12

    @State private var displayedURL: String = ""
    @State private var isVisible: Bool = false
    @State private var hideTask: DispatchWorkItem?

    private let hideDelay: TimeInterval = 0.1

    var body: some View {
        Text(displayedURL.isEmpty ? " " : displayedURL)
            .font(.system(size: Self.fontSize))
            .themedForeground(.textPrimary)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: LiquidGlassCompatible.webContentContainerCornerRadius)
                    .themedFill(.contentOverlayBackground)
                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.05), value: isVisible)
            .onChange(of: viewModel.url) { _, newURL in
                handleURLChange(newURL)
            }
            .onAppear {
                if !viewModel.url.isEmpty {
                    displayedURL = viewModel.url
                    isVisible = true
                }
            }
    }

    private func handleURLChange(_ newURL: String) {
        hideTask?.cancel()
        hideTask = nil

        if newURL.isEmpty {
            // Delay hiding to prevent flicker when quickly moving between links
            let task = DispatchWorkItem { [self] in
                isVisible = false
            }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: task)
        } else {
            displayedURL = newURL
            isVisible = true
        }
    }
}

// MARK: - AppKit Hosting

extension StatusURLView {
    static func preferredWidth(for url: String) -> CGFloat {
        ceil((url as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width)
            + horizontalPadding * 2
    }

    static func placement(
        preferredWidth: CGFloat,
        containerBounds: NSRect,
        bubbleFrame: NSRect,
        mouseLocation: NSPoint
    ) -> (usesTrailingEdge: Bool, maximumWidth: CGFloat) {
        let widthLimit = max(0, min(containerBounds.width * 0.5, containerBounds.width - edgeInset * 2))
        // Use the full preferred width, not the currently compressed frame, so
        // shrinking or moving the bubble cannot make it oscillate between sides.
        let leadingFrame = NSRect(
            x: containerBounds.minX + edgeInset,
            y: bubbleFrame.minY,
            width: min(preferredWidth, widthLimit),
            height: bubbleFrame.height
        )
        let pointerClearance: CGFloat = 8
        let usesTrailingEdge = leadingFrame.insetBy(dx: -pointerClearance, dy: -pointerClearance)
            .contains(mouseLocation)
        let availableWidth = containerBounds.maxX - edgeInset - mouseLocation.x - pointerClearance
        return (usesTrailingEdge, usesTrailingEdge ? max(0, min(widthLimit, availableWidth)) : widthLimit)
    }

    static func makeHostingView(viewModel: StatusURLViewModel, themeSource: ThemeStateProvider? = nil) -> StatusURLHostingView {
        let hostingView = StatusURLHostingView(rootView: StatusURLView(viewModel: viewModel), themeSource: themeSource)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        hostingView.wantsLayer = true
        hostingView.layer?.zPosition = 1000

        return hostingView
    }
}

final class StatusURLHostingView: ThemedHostingView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        // SwiftUI can change the bubble's size after the URL publisher fires.
        onLayout?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The status display must never intercept the underlying page's input,
        // including during its delayed fade-out.
        nil
    }
}

#if DEBUG
struct StatusURLView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel1 = StatusURLViewModel()
        viewModel1.url = "https://www.example.com/very/long/path/to/page"

        let viewModel2 = StatusURLViewModel()
        viewModel2.url = "https://github.com"

        let viewModel3 = StatusURLViewModel()
        viewModel3.url = ""

        return VStack(alignment: .leading, spacing: 20) {
            StatusURLView(viewModel: viewModel1)
                .frame(width: 300)

            StatusURLView(viewModel: viewModel2)
                .frame(width: 300)

            StatusURLView(viewModel: viewModel3)
                .frame(width: 300)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
}
#endif

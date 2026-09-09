// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A container view for overlay toasts, covering the entire window.
// Toasts are positioned in their designated areas (e.g., downloads in bottom-right).

import SwiftUI

// MARK: - Hit Test Frame Collection

/// PreferenceKey used to collect hit-testable frames from overlay widgets.
private struct OverlayHitTestFrameKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NotificationCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Marks a view as hit-testable inside the overlay container.
private struct OverlayHitTestableModifier: ViewModifier {
    let coordinateSpace: String
    let expansion: EdgeExpansion
    
    struct EdgeExpansion {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        
        static let zero = EdgeExpansion()
    }
    
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OverlayHitTestFrameKey.self,
                    value: [expandedFrame(geometry.frame(in: .named(coordinateSpace)))]
                )
            }
        )
    }
    
    private func expandedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x - expansion.left,
            y: frame.origin.y - expansion.top,
            width: frame.width + expansion.left + expansion.right,
            height: frame.height + expansion.top + expansion.bottom
        )
    }
}

private extension View {
    /// Marks this view as hit-testable inside the overlay container.
    func overlayHitTestable(
        in coordinateSpace: String,
        expansion: OverlayHitTestableModifier.EdgeExpansion = .zero
    ) -> some View {
        self.modifier(OverlayHitTestableModifier(coordinateSpace: coordinateSpace, expansion: expansion))
    }
}

// MARK: - Overlay Toast Container

struct OverlayToastContainer: View {
    @ObservedObject var viewModel: OverlayToastViewModel
    @State private var notificationCardHeight: CGFloat = 0
    
    /// Padding from window edges.
    private let edgePadding: CGFloat = 16
    
    /// Distance from the top edge for the notification card.
    private let notificationCardTopOffset: CGFloat = 36
    
    /// Distance from the right edge for the notification card.
    private let notificationCardRightOffset: CGFloat = 18

    /// Distance from the right edge for generic top-trailing toasts.
    private let genericToastRightOffset: CGFloat = 16

    /// Vertical spacing between independent overlay surfaces in the same corner.
    private let overlayVerticalSpacing: CGFloat = 8

    /// Animation used when generic toasts appear, disappear, or replace each other.
    private let genericToastAnimation = Animation.easeInOut(duration: 0.125)

    /// Generic toasts drop in from the top, but dismiss without positional motion.
    private let genericToastTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .opacity
    )
    
    /// Fixed width for the notification card.
    private let notificationCardWidth: CGFloat = 220
    
    /// Coordinate space name used for hit-test frame calculations.
    private let coordinateSpaceName = "overlayContainer"
    
    var body: some View {
        GeometryReader { containerGeometry in
            ZStack {
                if !viewModel.isPanel {
                    livingDownloadsArea
                    notificationCardArea
                }
                topCenterToastArea
                topTrailingToastArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: coordinateSpaceName)
            .onPreferenceChange(OverlayHitTestFrameKey.self) { swiftUIFrames in
                let containerHeight = containerGeometry.size.height
                let appKitFrames = swiftUIFrames.map { frame in
                    CGRect(
                        x: frame.origin.x,
                        y: containerHeight - frame.origin.y - frame.height,
                        width: frame.width,
                        height: frame.height
                    )
                }
                viewModel.hitTestFrames = appKitFrames
                AppLogDebug("[OverlayHitTest] frames updated: \(appKitFrames)")
            }
            .onPreferenceChange(NotificationCardHeightKey.self) { height in
                notificationCardHeight = height
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var livingDownloadsArea: some View {
        if viewModel.isLivingDownloadsVisible {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LivingDownloadsListView(manager: viewModel.livingDownloadsManager)
                        .overlayHitTestable(in: coordinateSpaceName)
                        .padding(.trailing, edgePadding)
                        .padding(.bottom, edgePadding)
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: viewModel.isLivingDownloadsVisible)
        }
    }

    private var topCenterToastArea: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.genericToasts(for: .topCenter)) { toast in
                OverlayToastView(toast: toast, toastCenter: viewModel.toastCenter)
                    .overlayHitTestable(in: coordinateSpaceName)
                    .transition(genericToastTransition)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, viewModel.genericToastTopOffset)
        .padding(.horizontal, edgePadding)
        .animation(.easeInOut(duration: 0.25), value: viewModel.layoutMode)
        .animation(genericToastAnimation, value: viewModel.genericToasts(for: .topCenter))
    }

    @ViewBuilder
    private var notificationCardArea: some View {
        if viewModel.isNotificationCardVisible {
            VStack(alignment: .trailing, spacing: 0) {
                NotificationMessageCardView(
                    manager: viewModel.notificationCardManager,
                    layoutMode: .legacy,
                    onRun: { card in
                        NotificationCardManager.shared.decide(card: card, decision: .accept)
                    },
                    onDismiss: { _ in
                        NotificationCardManager.shared.hideCard()
                    },
                    onDelete: { card in
                        NotificationCardManager.shared.decide(card: card, decision: .reject)
                    }
                )
                .frame(width: notificationCardWidth)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: NotificationCardHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                )
                .overlayHitTestable(
                    in: coordinateSpaceName,
                    expansion: .init(left: 6, right: 0, top: 0, bottom: 20)
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, notificationCardTopOffset)
            .padding(.trailing, notificationCardRightOffset)
            .animation(.easeInOut(duration: 0.25), value: viewModel.isNotificationCardVisible)
        }
    }

    private var topTrailingToastArea: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(viewModel.genericToasts(for: .topTrailing)) { toast in
                OverlayToastView(toast: toast, toastCenter: viewModel.toastCenter)
                    .overlayHitTestable(in: coordinateSpaceName)
                    .transition(genericToastTransition)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, topTrailingToastTopOffset)
        .padding(.trailing, genericToastRightOffset)
        .animation(.easeInOut(duration: 0.25), value: viewModel.layoutMode)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isNotificationCardVisible)
        .animation(.easeInOut(duration: 0.25), value: notificationCardHeight)
        .animation(genericToastAnimation, value: viewModel.genericToasts(for: .topTrailing))
    }

    private var topTrailingToastTopOffset: CGFloat {
        guard viewModel.isNotificationCardVisible else {
            return viewModel.genericToastTopOffset
        }

        let notificationCardBottomOffset = notificationCardTopOffset + notificationCardHeight + overlayVerticalSpacing
        return max(viewModel.genericToastTopOffset, notificationCardBottomOffset)
    }
}

#if DEBUG
// Preview using standalone LivingDownloadsManager
struct OverlayToastContainer_Previews: PreviewProvider {
    static var previews: some View {
        // Standalone preview without full OverlayToastViewModel
        ZStack {
            Color.gray.opacity(0.3)
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LivingDownloadsListView(manager: TestLivingDownloadsManager())
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(width: 800, height: 600)
    }
}
#endif

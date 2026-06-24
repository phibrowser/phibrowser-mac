// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

// MARK: - Atomic Components

struct UnifiedTabTitleView: View {
    let viewModel: TabViewModel

    var body: some View {
        UnifiedTabTitleTextView(
            displayTitle: viewModel.displayTitle,
            isShimmering: viewModel.isShimmering,
            isPressed: viewModel.isPressed
        )
    }
}

struct UnifiedTabTitleTextView: View {
    let displayTitle: String
    let isShimmering: Bool
    let isPressed: Bool

    private static let titleFontSize: CGFloat = 13
    private static let titleFont = NSFont.systemFont(ofSize: titleFontSize)
    private static let titleHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
    private static let fadeWidth: CGFloat = 24

    var body: some View {
        titleContent
            .frame(height: Self.titleHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tabTitleShimmer(
                active: isShimmering,
                gradient: Gradient(colors: [
                    .black,
                    .black.opacity(0.1),
                    .black
                ]),
                bandSize: 0.5
            )
            .mask(
                TabTitleTrailingFadeMask(
                    fadeWidth: Self.fadeWidth
                )
            )
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .ignoresSafeArea()
    }

    private var titleContent: some View {
        GeometryReader { proxy in
            titleText
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                .clipped()
        }
    }

    private var titleText: some View {
        Text(displayTitle)
            .font(.system(size: Self.titleFontSize))
            .lineLimit(1)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private struct TabTitleTrailingFadeMask: View {
    let fadeWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(fadeWidth, proxy.size.width))
            }
        }
    }
}

private extension View {
    func tabTitleShimmer(
        active: Bool,
        gradient: Gradient,
        bandSize: CGFloat
    ) -> some View {
        modifier(
            TabTitleShimmerModifier(active: active, gradient: gradient, bandSize: bandSize)
        )
    }
}

private struct TabTitleShimmerModifier: ViewModifier {
    let active: Bool
    let gradient: Gradient
    let bandSize: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            TabTitleShimmerMask(active: active, gradient: gradient, bandSize: bandSize)
        }
    }
}

private struct TabTitleShimmerMask: View {
    let active: Bool
    let gradient: Gradient
    let bandSize: CGFloat

    @Environment(\.layoutDirection) private var layoutDirection

    private let duration: TimeInterval = 1.5

    var body: some View {
        if active {
            TimelineView(.animation) { context in
                LinearGradient(
                    gradient: gradient,
                    startPoint: startPoint(at: context.date),
                    endPoint: endPoint(at: context.date)
                )
            }
        } else {
            Rectangle().fill(.black)
        }
    }

    private func startPoint(at date: Date) -> UnitPoint {
        let phase = phase(at: date)
        let min = 0 - bandSize
        let x = min + (1 - min) * phase

        if layoutDirection == .rightToLeft {
            return UnitPoint(x: 1 - x, y: min)
        }
        return UnitPoint(x: x, y: min)
    }

    private func endPoint(at date: Date) -> UnitPoint {
        let phase = phase(at: date)
        let max = 1 + bandSize
        let x = max * phase

        if layoutDirection == .rightToLeft {
            return UnitPoint(x: 1 - x, y: max)
        }
        return UnitPoint(x: x, y: max)
    }

    private func phase(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSinceReferenceDate
        let normalized = elapsed.truncatingRemainder(dividingBy: duration) / duration
        return CGFloat(normalized)
    }
}

struct UnifiedTabFaviconView: View {
    let viewModel: TabViewModel
    @Environment(\.phiAppearance) private var phiAppearance

    private static let faviconSize: CGFloat = 14
    private static let faviconCornerRadius: CGFloat = 3

    var body: some View {
        Group {
            if let liveFaviconImage = viewModel.liveFaviconImage {
                Image(nsImage: liveFaviconImage)
                    .resizable()
                    .scaledToFit()
            } else if let profileFaviconImage = viewModel.profileFaviconImage {
                Image(nsImage: profileFaviconImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image.favicon(for: viewModel.faviconLoadURL ?? viewModel.url, configuration: .init(cornerRadius: Self.faviconCornerRadius))
                    .id(viewModel.faviconRevision)
            }
        }
        .frame(width: Self.faviconSize, height: Self.faviconSize)
        .clipShape(RoundedRectangle(cornerRadius: Self.faviconCornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if viewModel.isCapturingMedia {
                UnifiedTabRecordingIcon()
                    .offset(x: 3, y: -3)
            }
        }
        .scaleEffect(viewModel.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.1), value: viewModel.isPressed)
        .ignoresSafeArea()
    }
}

struct UnifiedTabCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .themedFill(.hover)
                .opacity(isHovered ? 1 : 0)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .ignoresSafeArea()
    }
}

struct UnifiedTabMuteButton: View {
    let viewModel: TabViewModel
    @State private var isHovered = false

    private var isMuteInteractive: Bool {
        !viewModel.isHorizontalCompactMode || viewModel.isActive
    }

    var body: some View {
        Button {
            viewModel.onToggleMute?()
        } label: {
            Image(viewModel.isAudioMuted ? .speakerMute : .speakerWave)
                .renderingMode(.template)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .themedFill(.hover)
                .opacity(isHovered ? 1 : 0)
        )
//        .help(viewModel.isAudioMuted ?
//                NSLocalizedString("Unmute", comment: "Tab mute button tooltip - unmute") :
//                NSLocalizedString("Mute", comment: "Tab mute button tooltip - mute")
//        )
        .onHover { hovering in
            isHovered = hovering
        }
        .allowsHitTesting(isMuteInteractive)
        .onHover { hovering in
            guard isMuteInteractive else {
                isHovered = false
                return
            }
            isHovered = hovering
        }
        .ignoresSafeArea()
    }
}

/// Standalone mute toggle used by the split-pair sidebar cell. Mirrors
/// `UnifiedTabMuteButton`'s appearance but is parameter-driven so the
/// merged cell can drive two of them without running a full TabViewModel
/// per pane.
struct SplitPaneMuteButton: View {
    let isMuted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(isMuted ? .speakerMute : .speakerWave)
                .renderingMode(.template)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .themedFill(.hover)
                .opacity(isHovered ? 1 : 0)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .ignoresSafeArea()
    }
}

struct UnifiedTabRecordingIcon: View {
    private let iconSize: CGFloat = 8
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: iconSize, height: iconSize)
            .overlay {
                Image(systemName: "circle.fill")
                    .resizable()
                    .foregroundStyle(.red)
                    .frame(width: iconSize - 2, height: iconSize - 2)
                    .opacity(isAnimating ? 0.2 : 1.0)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isAnimating)
            }
            .onAppear { isAnimating = true }
    }
}

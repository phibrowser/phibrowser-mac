// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

// MARK: - Atomic Components

struct UnifiedTabTitleView: View {
    let viewModel: TabViewModel
    
    var body: some View {
        Text(viewModel.displayTitle)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .shimmering(
                active: viewModel.isShimmering,
                gradient: Gradient(colors: [
                    .black,
                    .black.opacity(0.1),
                    .black
                ]),
                bandSize: 0.5
            )
            .scaleEffect(viewModel.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.1), value: viewModel.isPressed)
            .ignoresSafeArea()
    }
}

struct UnifiedTabFaviconView: View {
    let viewModel: TabViewModel
    
    var body: some View {
        Group {
            if let liveFaviconImage = viewModel.liveFaviconImage {
                Image(nsImage: liveFaviconImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image.favicon(for: viewModel.faviconLoadURL ?? viewModel.url, configuration: .init(cornerRadius: 3))
                    .id(viewModel.faviconRevision)
            }
        }
        .frame(width: 14, height: 14)
        .clipped()
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

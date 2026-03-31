// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

/// State model for the sidebar bottom bar.
class SidebarBottomBarState: ObservableObject {
    /// Width threshold below which the feedback button switches to icon-only mode.
    static let compactWidthThreshold: CGFloat = 230
    
    /// Single-row height.
    static let singleRowHeight: CGFloat = 24
    /// Two-row height.
    static let doubleRowHeight: CGFloat = 54
    /// Spacing between the two rows.
    static let rowSpacing: CGFloat = 6
    
    /// Legacy compact layout flag, kept for compatibility.
    @Published var isCompact: Bool = false
    
    /// Whether the feedback button is icon-only.
    @Published var isFeedbackCompact: Bool = false
    
    /// Current bar height.
    var currentHeight: CGFloat {
        isCompact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    
    func height(for compact: Bool) -> CGFloat {
        return compact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    /// Whether the chat button is hidden.
    @Published var isChatHidden: Bool = false
    
    /// Whether the downloads popover is visible.
    @Published var isDownloadPopoverShown: Bool = false
}

/// SwiftUI implementation of the sidebar bottom bar.
struct SidebarBottomBarSwiftUI: View {
    @ObservedObject var state: SidebarBottomBarState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @ObservedObject var cardManager: NotificationCardManager
    
    let onFeedbackTap: () -> Void
    let onBookmarkTap: () -> Void
    let onChatTap: () -> Void
    let onCardEntryTap: () -> Void
    
    var body: some View {
        GeometryReader { geometry in
            regularLayout
                .onChange(of: geometry.size.width) { newWidth in
                    updateFeedbackCompactState(width: newWidth)
                }
                .onChange(of: showCardEntry) { _ in
                    updateFeedbackCompactState(width: geometry.size.width)
                }
                .onChange(of: state.isChatHidden) { _ in
                    updateFeedbackCompactState(width: geometry.size.width)
                }
                .onAppear {
                    updateFeedbackCompactState(width: geometry.size.width)
                }
        }
        .frame(height: SidebarBottomBarState.singleRowHeight)
    }
    
    /// Update whether the feedback button should switch to icon-only mode.
    private func updateFeedbackCompactState(width: CGFloat) {
        let chatButtonExists = !state.isChatHidden
        let bulbButtonExists = showCardEntry
        let widthBelowThreshold = width < SidebarBottomBarState.compactWidthThreshold
        
        let shouldBeCompact = chatButtonExists && bulbButtonExists && widthBelowThreshold
        
        if state.isFeedbackCompact != shouldBeCompact {
//            withAnimation(.easeInOut(duration: 0.05)) {
                state.isFeedbackCompact = shouldBeCompact
//            }
        }
    }
    
    // MARK: - Regular Layout
    
    private var regularLayout: some View {
        HStack(spacing: 4) {
            cardEntryButton
            
            downloadButton
            
            Spacer(minLength: 0)
            
            FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: state.isFeedbackCompact)
                .layoutPriority(1)
            
            if !state.isChatHidden {
                ChatButton(action: onChatTap)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, 8)
    }
    
    // MARK: - Download Button
    
    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            onTap: {
                state.isDownloadPopoverShown.toggle()
            }
        )
        .popover(isPresented: $state.isDownloadPopoverShown, arrowEdge: .top) {
            if let manager = downloadViewModel.downloadsManager {
                DownloadsListView(downloadsManager: manager)
                    .frame(width: 340, height: 317)
            }
        }
    }
    
    // MARK: - Legacy Compact Layout
    
    private var compactLayout: some View {
        VStack(spacing: SidebarBottomBarState.rowSpacing) {
            HStack(spacing: 4) {
                cardEntryButton

                downloadButton
                
                Spacer()
                
                if !state.isChatHidden {
                    ChatButton(action: onChatTap)
                }
            }
            .padding(.leading, 8)
            .frame(height: SidebarBottomBarState.singleRowHeight)
            .animation(showCardEntry ? .spring(response: 0.28, dampingFraction: 0.78) : nil, value: showCardEntry)
            
            FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: false)
                .padding(.leading, 8)
                .frame(height: SidebarBottomBarState.singleRowHeight)
        }
    }

    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }

    @ViewBuilder
    private var cardEntryButton: some View {
        if showCardEntry {
            CardEntryButton(action: onCardEntryTap)
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .identity
                    )
                )
        }
    }
}

// MARK: - Feedback Button

struct FeedbackButtonSwiftUI: View {
    let action: () -> Void
    /// Whether to render the icon-only variant.
    var isIconOnly: Bool = false
    
    /// Width for icon-only mode.
    private let iconOnlyWidth: CGFloat = 32
    /// Width for the full label mode.
    private let fullWidth: CGFloat = 90
    /// Tooltip delay in seconds.
    private let tooltipDelay: TimeInterval = 0.2
    
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: DispatchWorkItem?
    
    var body: some View {
        Button {
            hideTooltip()
            action()
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: NSImage(resource: .sidebarFeedback))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .themedTint(.textPrimary)
                
                if !isIconOnly {
                    Text(NSLocalizedString("Feedback", comment: "Feedback - Sidebar feedback button title"))
                        .font(.system(size: 11))
                        .foregroundColor(Color.primaryLabel)
                }
            }
            .frame(width: isIconOnly ? iconOnlyWidth : fullWidth)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.commonBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .background(alignment: .top) {
            if isIconOnly && showTooltip {
                FastTooltip(text: NSLocalizedString("Feedback", comment: "Feedback - Tooltip text for icon-only feedback button"))
                    .offset(y: -16)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            handleHover(hovering)
        }
        .onChange(of: isIconOnly) { newValue in
            if !newValue {
                showTooltip = false
                hoverTask?.cancel()
                hoverTask = nil
            }
        }
    }
    
    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        
        if hovering && isIconOnly {
            let task = DispatchWorkItem { [self] in
                withAnimation(.easeOut(duration: 0.15)) {
                    showTooltip = true
                }
            }
            hoverTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + tooltipDelay, execute: task)
        } else {
            hideTooltip()
        }
    }
    
    /// Hide the tooltip when clicked or when the pointer leaves.
    private func hideTooltip() {
        hoverTask?.cancel()
        hoverTask = nil
        withAnimation(.easeOut(duration: 0.1)) {
            showTooltip = false
        }
    }
}

// MARK: - Tooltip

private struct FastTooltip: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 8))
            .foregroundColor(Color(nsColor: .controlTextColor))
            .fixedSize()
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .fixedSize()
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let image: NSImage
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Card Entry Button

struct CardEntryButton: View {
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPopping = false

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    private let popScale: CGFloat = 1.18
    private let popDelay: TimeInterval = 0.22
    private let popUpDuration: TimeInterval = 0.12
    private let popDownDuration: TimeInterval = 0.18

    var body: some View {
        Button(action: action) {
            Image(.cardBulbIcon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPopping ? popScale : 1)
        .onAppear {
            isPopping = false
            DispatchQueue.main.asyncAfter(deadline: .now() + popDelay) {
                withAnimation(.easeOut(duration: popUpDuration)) {
                    isPopping = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + popUpDuration) {
                    withAnimation(.easeInOut(duration: popDownDuration)) {
                        isPopping = false
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - NSView Bridge

/// AppKit bridge for the SwiftUI sidebar bottom bar.
class SidebarBottomBarSwiftUIView: NSView {
    private var hostingView: NSHostingView<SidebarBottomBarSwiftUI>?
    private let state = SidebarBottomBarState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var heightConstraint: NSLayoutConstraint?
    
    /// Height change callback.
    var onHeightChange: ((CGFloat) -> Void)?
    
    /// Button callbacks.
    var onFeedbackTap: (() -> Void)?
    var onBookmarkTap: (() -> Void)?
    var onChatTap: (() -> Void)?
    var onCardEntryTap: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupObservers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
        setupObservers()
    }
    
    private func setupHostingView() {
        let swiftUIView = SidebarBottomBarSwiftUI(
            state: state,
            downloadViewModel: downloadViewModel,
            cardManager: NotificationCardManager.shared,
            onFeedbackTap: { [weak self] in self?.onFeedbackTap?() },
            onBookmarkTap: { [weak self] in self?.onBookmarkTap?() },
            onChatTap: { [weak self] in self?.onChatTap?() },
            onCardEntryTap: { [weak self] in self?.onCardEntryTap?() }
        )
        
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        self.hostingView = hosting
    }
    
    private func setupObservers() {
        // Propagate compact-mode height changes to the container.
        state.$isCompact
            .removeDuplicates()
            .sink { [weak self] isCompact in
                guard let self = self else { return }
                self.onHeightChange?(self.state.height(for: isCompact))
            }
            .store(in: &cancellables)
    }
    
    /// Hides or shows the chat button, for example in private mode.
    func setChatHidden(_ hidden: Bool) {
        state.isChatHidden = hidden
    }
    
    /// Binds the downloads manager for progress display.
    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }
    
    /// Current rendered bar height.
    var currentHeight: CGFloat {
        state.currentHeight
    }
}

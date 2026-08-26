// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import PostHog

@MainActor
enum FeatureEntryAnalytics {
    enum Button: String, CaseIterable {
        case chat
        case memory
        case download
        case organizeTabs = "organize_tabs"
    }

    enum Surface: String, CaseIterable {
        case sidebar
        case webContentHeader = "web_content_header"
    }

    static func capture(_ button: Button, surface: Surface) {
        PostHogSDK.shared.capture("feature_entry_tapped", properties: [
            "button": button.rawValue,
            "surface": surface.rawValue,
        ])
    }
}

/// State model for the sidebar bottom bar.
class SidebarBottomBarState: ObservableObject {
    /// Single-row height.
    static let singleRowHeight: CGFloat = 24
    /// Two-row height.
    static let doubleRowHeight: CGFloat = 54
    /// Spacing between the two rows.
    static let rowSpacing: CGFloat = 6
    
    /// Legacy compact layout flag, kept for compatibility.
    @Published var isCompact: Bool = false
    
    /// Whether the feedback button is hidden for the current access mode.
    @Published var isFeedbackHidden: Bool = ApplicationState.shared.isGuest
    
    /// Current bar height.
    var currentHeight: CGFloat {
        isCompact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    
    func height(for compact: Bool) -> CGFloat {
        return compact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    /// Whether the chat button is hidden.
    @Published var isChatHidden: Bool = false

    /// Whether the AI memory button is hidden (mirrors the global Phi AI toggle).
    @Published var isMemoryHidden: Bool = false

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
    let onMemoryTap: () -> Void
    let onDownloadTap: () -> Void
    
    var body: some View {
        regularLayout
            .frame(height: SidebarBottomBarState.singleRowHeight)
    }
    
    // MARK: - Regular Layout
    
    private var regularLayout: some View {
        HStack(spacing: 4) {
            downloadButton

            memoryButton

            cardEntryButton

            Spacer(minLength: 0)

            if !state.isFeedbackHidden {
                ViewThatFits(in: .horizontal) {
                    FeedbackButtonSwiftUI(action: onFeedbackTap)
                    FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: true)
                }
                .layoutPriority(1)
            }

            if !state.isChatHidden {
                ChatButton(action: onChatTap)
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, WebContentConstant.edgesSpacing)
    }

    @ViewBuilder
    private var memoryButton: some View {
        if !state.isMemoryHidden {
            MemoryButton(action: onMemoryTap)
        }
    }
    
    // MARK: - Download Button
    
    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            onTap: {
                onDownloadTap()
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
            HStack(spacing: 2) {
                downloadButton

                memoryButton

                cardEntryButton

                Spacer()

                if !state.isChatHidden {
                    ChatButton(action: onChatTap)
                }
            }
            .padding(.leading, WebContentConstant.edgesSpacing)
            .frame(height: SidebarBottomBarState.singleRowHeight)
            .animation(showCardEntry ? .spring(response: 0.28, dampingFraction: 0.78) : nil, value: showCardEntry)
            
            if !state.isFeedbackHidden {
                FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: false)
                    .padding(.leading, 8)
                    .frame(height: SidebarBottomBarState.singleRowHeight)
            }
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
    var contentWidth: CGFloat? = nil
    var contentHeight: CGFloat? = nil
    
    /// Width for icon-only mode.
    private let iconOnlyWidth: CGFloat = 32
    /// Width for the full label mode.
    private let fullWidth: CGFloat = 90
    /// Minimum horizontal breathing room for the full label mode.
    private let fullContentHorizontalPadding: CGFloat = 2
    
    @State private var isHovering = false
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: NSImage(resource: .sidebarFeedback))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .themedTint(.textPrimary)
                
                if !isIconOnly {
                    Text(NSLocalizedString("sidebar.feedbackButton.title", value: "Feedback", comment: "Feedback - Sidebar feedback button title"))
                        .font(.system(size: 11))
                        .foregroundColor(Color.primaryLabel)
                        .lineLimit(1)
                        .fixedSize(horizontal: contentWidth == nil, vertical: false)
                }
            }
            .padding(.horizontal, isIconOnly ? 0 : fullContentHorizontalPadding)
            .frame(width: isIconOnly ? iconOnlyWidth : contentWidth)
            .frame(minWidth: !isIconOnly && contentWidth == nil ? fullWidth : nil)
            .padding(.vertical, 3)
            .frame(height: contentHeight)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(Color.commonBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("sidebar.feedbackButton.tooltip", value: "Feedback", comment: "Feedback - Tooltip text for feedback button"))
        .onHover { hovering in
            isHovering = hovering
        }
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
    private var hostingView: ThemedHostingView?
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
    var onMemoryTap: (() -> Void)?
    var onDownloadTap: (() -> Void)?
    
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
        let hosting = ThemedHostingView(
            rootView: SidebarBottomBarSwiftUI(
                state: state,
                downloadViewModel: downloadViewModel,
                cardManager: NotificationCardManager.shared,
                onFeedbackTap: { [weak self] in self?.onFeedbackTap?() },
                onBookmarkTap: { [weak self] in self?.onBookmarkTap?() },
                onChatTap: { [weak self] in self?.onChatTap?() },
                onCardEntryTap: { [weak self] in self?.onCardEntryTap?() },
                onMemoryTap: { [weak self] in self?.onMemoryTap?() },
                onDownloadTap: { [weak self] in self?.onDownloadTap?() }
            )
        )
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

        NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.state.isFeedbackHidden = ApplicationState.shared.isGuest
            }
            .store(in: &cancellables)
    }
    
    /// Hides or shows the chat button, for example in private mode.
    func setChatHidden(_ hidden: Bool) {
        state.isChatHidden = hidden
    }

    /// Hides or shows the AI memory button. Should be hidden when Phi AI is disabled.
    func setMemoryHidden(_ hidden: Bool) {
        state.isMemoryHidden = hidden
    }

    /// Hides the hosted controls while the create-Space form covers the bottom
    /// bar. The outer AppKit wrapper stays mounted so its stack height remains
    /// unchanged, while SwiftUI hover and native help tracking are deactivated.
    func setCreateSpaceOverlayInteractionSuppressed(_ suppressed: Bool) {
        hostingView?.isHidden = suppressed
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

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A download button with progress indicator for the sidebar bottom bar.

import SwiftUI
import Combine

// MARK: - Download Button View Model

class DownloadButtonViewModel: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var hasActiveDownloads: Bool = false
    /// Trigger to play the arrow animation once (incremented on each new download)
    @Published var animationPlayCount: Int = 0
    
    private var cancellables = Set<AnyCancellable>()
    /// Downloads manager exposed for popover presentation.
    private(set) weak var downloadsManager: DownloadsManager?
    
    init(downloadsManager: DownloadsManager? = nil) {
        self.downloadsManager = downloadsManager
        setupBindings()
    }
    
    private func setupBindings() {
        guard let downloadsManager = downloadsManager else { return }
        
        downloadsManager.$totalDownloadProgress
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .assign(to: &$progress)
        
        downloadsManager.downloadEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak downloadsManager] event in
                guard let self = self,
                      let manager = downloadsManager else { return }
                
                if event.eventType == .created, event.downloadItem?.isNewlyCreate ?? false {
                    self.animationPlayCount += 1
                }
                
                if event.eventType != .updated {
                    self.hasActiveDownloads = manager.downloads.contains { $0.state == .inProgress }
                }
            }
            .store(in: &cancellables)
        
        downloadsManager.$downloads
            .map { downloads in
                downloads.contains { $0.state == .inProgress }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasActiveDownloads)
    }
    
    func bindTo(_ downloadsManager: DownloadsManager) {
        self.downloadsManager = downloadsManager
        setupBindings()
    }
}

// MARK: - Download Button SwiftUI View

struct DownloadButtonView: View {
    @ObservedObject var viewModel: DownloadButtonViewModel
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    
    /// Download icon tint color (themed)
    var iconTintColor: ThemedColor = .textPrimary

    /// When true, the hover background renders as a circle instead of a rounded rectangle.
    var useCircularHoverShape: Bool = false

    var onTap: () -> Void
    
    /// Button size (matches other sidebar buttons)
    private let buttonSize: CGFloat = 24
    /// Including the stroke, the ring is approximately 18 points across.
    private let ringDiameter: CGFloat = 16.8
    private let ringLineWidth: CGFloat = 1.27
    /// Corner radius for hover background
    private let cornerRadius: CGFloat = 6
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                hoverBackground
                    .fill(isHovered ? Color(nsColor: .sidebarTabHovered) : Color.clear)

                ZStack {
                    Circle()
                        .stroke(Color(nsColor: resolvedTintColor), lineWidth: ringLineWidth)
                        .opacity(viewModel.hasActiveDownloads ? 0 : 1)

                    PhiProgressView(
                        progress: viewModel.progress,
                        style: .circular,
                        progressColor: .phiPrimary,
                        trackColor: Color.phiPrimary.opacity(0.2),
                        lineWidth: ringLineWidth
                    )
                    .opacity(viewModel.hasActiveDownloads ? 1 : 0)
                }
                .frame(width: ringDiameter, height: ringDiameter)
                .animation(.easeInOut(duration: 0.2), value: viewModel.hasActiveDownloads)

                arrowView
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(NSLocalizedString(
            "browser.headerMoreMenu.downloadsAction",
            value: "Downloads",
            comment: "Header more menu - Downloads action"
        ))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
    
    private var hoverBackground: AnyShape {
        useCircularHoverShape ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Resolved tint color based on current theme and appearance
    private var resolvedTintColor: NSColor {
        iconTintColor.resolver(theme, appearance)
    }
    
    private var arrowView: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 6.9))
            path.addLine(to: CGPoint(x: 12, y: 16.3))
            path.move(to: CGPoint(x: 8.7, y: 13))
            path.addLine(to: CGPoint(x: 12, y: 16.3))
            path.addLine(to: CGPoint(x: 15.3, y: 13))
        }
        .stroke(
            Color(nsColor: resolvedTintColor),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
        .frame(width: buttonSize, height: buttonSize)
        .scaleEffect(0.875)
        .phaseAnimator([CGFloat.zero, 1.5, 0], trigger: viewModel.animationPlayCount) { content, offset in
            content.offset(y: reduceMotion ? 0 : offset)
        } animation: { offset in
            offset == 0 ? .easeOut(duration: 0.2) : .easeIn(duration: 0.15)
        }
    }
    
}

// MARK: - NSView Wrapper for AppKit Integration

/// NSView wrapper for DownloadButtonView to use in SidebarBottomBar
class DownloadButtonNSView: NSView {
    private var hostingView: ThemedHostingView?
    private let viewModel: DownloadButtonViewModel
    private var onTap: (() -> Void)?
    
    // MARK: - Initialization
    
    init(downloadsManager: DownloadsManager? = nil, onTap: @escaping () -> Void) {
        self.viewModel = DownloadButtonViewModel(downloadsManager: downloadsManager)
        self.onTap = onTap
        super.init(frame: .zero)
        setupHostingView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    
    private func setupHostingView() {
        let hosting = ThemedHostingView(rootView: DownloadButtonView(viewModel: viewModel, onTap: { [weak self] in
            self?.onTap?()
        }))
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
    
    // MARK: - Public Methods
    
    /// Bind to a DownloadsManager to observe progress
    func bindTo(_ downloadsManager: DownloadsManager) {
        viewModel.bindTo(downloadsManager)
    }
    
    /// Get the view for popover positioning
    var popoverAnchorView: NSView {
        return self
    }
}

// MARK: - Preview

#if DEBUG
struct DownloadButtonView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // No active downloads
            DownloadButtonView(
                viewModel: PreviewDownloadButtonViewModel(progress: 0, hasActive: false),
                onTap: {}
            )
            .previewDisplayName("No Downloads")
            
            // Active download at 30%
            DownloadButtonView(
                viewModel: PreviewDownloadButtonViewModel(progress: 0.3, hasActive: true),
                onTap: {}
            )
            .previewDisplayName("30% Progress")
            
            // Active download at 75%
            DownloadButtonView(
                viewModel: PreviewDownloadButtonViewModel(progress: 0.75, hasActive: true),
                onTap: {}
            )
            .previewDisplayName("75% Progress")
            
            // Almost complete
            DownloadButtonView(
                viewModel: PreviewDownloadButtonViewModel(progress: 0.95, hasActive: true),
                onTap: {}
            )
            .previewDisplayName("95% Progress")
        }
        .padding(20)
//        .background(Color(nsColor: .sidebarBackground))
    }
}

class PreviewDownloadButtonViewModel: DownloadButtonViewModel {
    init(progress: Double, hasActive: Bool, animationCount: Int = 0) {
        super.init(downloadsManager: nil)
        self.progress = progress
        self.hasActiveDownloads = hasActive
        self.animationPlayCount = animationCount
    }
}
#endif

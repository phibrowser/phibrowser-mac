// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A download button with progress indicator for the sidebar bottom bar.
// Designed for extensibility (future Lottie animation support).

import SwiftUI
import Combine
import Lottie

// MARK: - Download Button View Model

class DownloadButtonViewModel: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var hasActiveDownloads: Bool = false
    /// Trigger to play the Lottie animation once (incremented on each new download)
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
    @ObservedObject private var themeObserver = ThemeObserver.shared
    @State private var isHovered = false
    @State private var playbackMode: LottiePlaybackMode = .paused(at: .progress(0))
    
    /// Lottie icon tint color (themed)
    var iconTintColor: ThemedColor = .textPrimary
    
    var onTap: () -> Void
    
    /// Button size (matches other sidebar buttons)
    private let buttonSize: CGFloat = 24
    /// Progress bar dimensions
    private let progressBarWidth: CGFloat = 14
    private let progressBarHeight: CGFloat = 2
    /// Corner radius for hover background
    private let cornerRadius: CGFloat = 6
    
    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Color(nsColor: .sidebarTabHovered) : Color.clear)
                
                iconView
                
                PhiProgressView(
                    progress: viewModel.progress,
                    style: .linear,
                    progressColor: .phiPrimary,
                    trackColor: Color.phiPrimary.opacity(0.2),
                    lineWidth: progressBarHeight,
                    showGradientFade: false
                )
                .frame(width: progressBarWidth, height: progressBarHeight)
                .offset(y: -1)
                .opacity(viewModel.hasActiveDownloads ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: viewModel.hasActiveDownloads)
            }
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onChange(of: viewModel.animationPlayCount, { _, _ in
            triggerAnimation()
        })
    }
    
    // MARK: - Icon View
    
    /// Resolved tint color based on current theme and appearance
    private var resolvedTintColor: NSColor {
        iconTintColor.resolved()
    }
    
    /// The download icon with Lottie animation
    @ViewBuilder
    private var iconView: some View {
        LottieView(animation: .named("download-button", bundle: .main, subdirectory: "LottieFiles"))
            .playbackMode(playbackMode)
            .animationDidFinish { _ in
                playbackMode = .paused(at: .progress(0))
            }
            .configure { animationView in
                let colorProvider = ColorValueProvider(resolvedTintColor.lottieColor)
                animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Fill 1.Color"))
                animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Stroke 1.Color"))
            }
            .id(themeObserver.appearance)
            .frame(width: 24, height: 24)
    }
    
    /// Trigger a single play of the download animation
    private func triggerAnimation() {
        playbackMode = .playing(.toProgress(1, loopMode: .playOnce))
    }
    
}

// MARK: - NSView Wrapper for AppKit Integration

/// NSView wrapper for DownloadButtonView to use in SidebarBottomBar
class DownloadButtonNSView: NSView {
    private var hostingView: NSHostingView<DownloadButtonView>?
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
        let buttonView = DownloadButtonView(viewModel: viewModel, onTap: { [weak self] in
            self?.onTap?()
        })
        
        let hosting = NSHostingView(rootView: buttonView)
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

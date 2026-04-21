// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

private enum LivingDownloadDebugTuning {
    static var autoDismissDuration: TimeInterval {
#if DEBUG
        10.0
#else
        3.0
#endif
    }
}

// MARK: - Living Download Item

/// Wrapper for DownloadItem with auto-dismiss timer support
class LivingDownloadItem: ObservableObject, Identifiable {
    let id: String
    let downloadItem: DownloadItem
    
    @Published var isHovered: Bool = false
    @Published var shouldDismiss: Bool = false
    
    private var dismissTimer: Timer?
    private var dismissDuration: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    
    init(downloadItem: DownloadItem, dismissDuration: TimeInterval = LivingDownloadDebugTuning.autoDismissDuration) {
        self.id = downloadItem.id
        self.downloadItem = downloadItem
        self.dismissDuration = dismissDuration
        
        downloadItem.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        downloadItem.$state
            .sink { [weak self] state in
                if state == .complete || state == .cancelled {
                    self?.startDismissTimer()
                }
            }
            .store(in: &cancellables)

        // Re-evaluate dismiss timer only when safety state actually changes.
        // Download progress updates may re-publish raw safety fields with identical values.
        Publishers.CombineLatest(
            downloadItem.$state,
            Publishers.CombineLatest4(
                downloadItem.$isDangerous,
                downloadItem.$dangerType,
                downloadItem.$isInsecure,
                downloadItem.$insecureDownloadStatus
            )
        )
        .map { [weak downloadItem] _ in
            downloadItem?.safetyState ?? .normal
        }
        .removeDuplicates()
        .dropFirst() // skip initial value (handled below)
        .sink { [weak self] safetyState in
            guard let self = self else { return }
            if safetyState == .normal {
                self.startDismissTimer()
            } else {
                self.pauseDismissTimer()
            }
        }
        .store(in: &cancellables)

        // Do not auto-dismiss items with safety warnings
        if downloadItem.safetyState == .normal {
            startDismissTimer()
        }
    }
    
    deinit {
        dismissTimer?.invalidate()
    }
    
    func startDismissTimer() {
        dismissTimer?.invalidate()
        
        guard !isHovered else { return }
        
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissDuration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.shouldDismiss = true
            }
        }
    }
    
    func pauseDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
    
    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        if hovered {
            pauseDismissTimer()
        } else {
            if downloadItem.safetyState == .normal {
                startDismissTimer()
            }
        }
    }
}

// MARK: - Living Downloads Manager

/// Manages the list of visible download toasts.
class LivingDownloadsManager: ObservableObject {
    @Published var livingItems: [LivingDownloadItem] = []
    
    private weak var downloadsManager: DownloadsManager?
    
    var autoDismissDuration: TimeInterval = LivingDownloadDebugTuning.autoDismissDuration
    
    private var cancellables = Set<AnyCancellable>()
    
    init(downloadsManager: DownloadsManager? = nil) {
        self.downloadsManager = downloadsManager
        
        setupEventSubscription()
    }
    
    private func setupEventSubscription() {
        guard let downloadsManager = downloadsManager else { return }
        
        downloadsManager.downloadEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleDownloadEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleDownloadEvent(_ event: DownloadEvent) {
        switch event.eventType {
        case .created:
            if let item = event.downloadItem, item.isNewlyCreate {
                addDownload(item)
            }
            
        case .completed, .cancelled, .interrupted:
            if let item = event.downloadItem,
               let livingItem = livingItems.first(where: { $0.id == item.id }),
               livingItem.downloadItem.safetyState == .normal {
                livingItem.startDismissTimer()
            }
            
        case .removed, .destroyed:
            if let item = event.downloadItem {
                removeItem(byId: item.id)
            }
            
        default:
            break
        }
    }
    
    fileprivate func addDownload(_ item: DownloadItem) {
        guard !livingItems.contains(where: { $0.id == item.id }) else { return }
        
        let livingItem = LivingDownloadItem(downloadItem: item, dismissDuration: autoDismissDuration)
        
        livingItem.$shouldDismiss
            .filter { $0 }
            .sink { [weak self, weak livingItem] _ in
                guard let livingItem = livingItem else { return }
                self?.removeItem(livingItem)
            }
            .store(in: &cancellables)
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            livingItems.append(livingItem)
        }
    }
    
    private func removeItem(_ item: LivingDownloadItem) {
        withAnimation(.easeOut(duration: 0.25)) {
            livingItems.removeAll { $0.id == item.id }
        }
    }
    
    fileprivate func removeItem(byId id: String) {
        if let item = livingItems.first(where: { $0.id == id }) {
            removeItem(item)
        }
    }
    
    // MARK: - Actions (forwarded to DownloadsManager)
    
    func pauseDownload(_ item: DownloadItem) {
        downloadsManager?.pauseDownload(item)
    }
    
    func resumeDownload(_ item: DownloadItem) {
        downloadsManager?.resumeDownload(item)
    }
    
    func cancelDownload(_ item: DownloadItem) {
        downloadsManager?.cancelDownload(item)
        removeItem(byId: item.id)
    }
    
    func openDownload(_ item: DownloadItem) {
        downloadsManager?.openDownload(item)
    }
    
    func showInFinder(_ item: DownloadItem) {
        downloadsManager?.showInFinder(item)
    }
    
    func copyLink(_ item: DownloadItem) {
        downloadsManager?.copyLink(item)
    }

    func keepDownload(_ item: DownloadItem) {
        downloadsManager?.keepDownload(item)
    }

    func discardDownload(_ item: DownloadItem) {
        downloadsManager?.discardDownload(item)
        removeItem(byId: item.id)
    }

    func dismissItem(_ item: LivingDownloadItem) {
        removeItem(item)
    }
}

// MARK: - Living Downloads List View

struct LivingDownloadsListView: View {
    @ObservedObject var manager: LivingDownloadsManager
    
    private let itemWidth: CGFloat = 320
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(manager.livingItems) { livingItem in
                LivingDownloadItemView(
                    livingItem: livingItem,
                    onPause: { manager.pauseDownload($0) },
                    onResume: { manager.resumeDownload($0) },
                    onCancel: { manager.cancelDownload($0) },
                    onOpen: { manager.openDownload($0) },
                    onCopyLink: { manager.copyLink($0) },
                    onShowInFinder: { manager.showInFinder($0) },
                    onKeep: { manager.keepDownload($0) },
                    onDiscard: { manager.discardDownload($0) },
                    onDismiss: { manager.dismissItem(livingItem) }
                )
                .frame(width: itemWidth)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: manager.livingItems.count)
    }
}

// MARK: - Circular Progress Button

/// A circular progress indicator with a button in the center
struct CircularProgressButton: View {
    var progress: Double
    var progressColor: Color = .phiPrimary
    var trackColor: Color = Color.phiPrimary.opacity(0.15)
    var lineWidth: CGFloat = 2.5
    var buttonIcon: String = "xmark"
    var action: () -> Void

    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            PhiProgressView(
                progress: progress,
                style: .circular,
                progressColor: progressColor,
                trackColor: trackColor,
                lineWidth: lineWidth
            )
            .allowsHitTesting(false)
            
            Button(action: action) {
                Image(systemName: buttonIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(progressColor.opacity(isHovered ? 0.9 : 0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }
}

// MARK: - Living Download Item View

struct LivingDownloadItemView: View {
    @ObservedObject var livingItem: LivingDownloadItem
    @State private var isHovered = false
    
    var onPause: (DownloadItem) -> Void
    var onResume: (DownloadItem) -> Void
    var onCancel: (DownloadItem) -> Void
    var onOpen: (DownloadItem) -> Void
    var onCopyLink: (DownloadItem) -> Void
    var onShowInFinder: (DownloadItem) -> Void
    var onKeep: ((DownloadItem) -> Void)?
    var onDiscard: ((DownloadItem) -> Void)?
    var onDismiss: () -> Void
    
    private let iconSize: CGFloat = 40
    private let actionButtonSize: CGFloat = 32
    
    private var item: DownloadItem { livingItem.downloadItem }

    /// Chromium may disallow opening (e.g. removed file, policy); only normal safety is shown without warnings in this toast.
    private var canOpenCompletedFile: Bool {
        item.state == .complete && item.safetyState == .normal && item.canOpenDownload
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                fileIcon
                
                fileInfo
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            
            actionArea
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .livingToastBackground(cornerRadius: LivingDownloadToastMetrics.cornerRadius)
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            livingItem.setHovered(hovering)
        }
        .onTapGesture {
            guard canOpenCompletedFile else { return }
            onOpen(item)
        }
    }
    
    private var fileIcon: some View {
        let contentType = UTType(mimeType: item.mimeType)
        let image = NSWorkspace.shared.icon(for: contentType ?? .data)
        
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSize, height: iconSize)
    }
    
    private var hasSafetyWarning: Bool {
        item.safetyState != .normal
    }

    private var safetyTintColor: Color {
        switch item.safetyState {
        case .blocked, .policyBlocked:
            return .red
        case .warning, .scanning:
            return .orange
        case .normal:
            return .clear
        }
    }

    private var fileInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayFileName)
                .font(.system(size: 13, weight: .medium))
                .livingToastPrimaryStyle()
                .lineLimit(1)
                .truncationMode(.middle)

            if hasSafetyWarning {
                HStack(spacing: 3) {
                    if item.safetyState == .scanning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: item.safetyState == .blocked || item.safetyState == .policyBlocked
                              ? "xmark.shield.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(safetyTintColor.opacity(0.8))
                    }
                    Text(item.shortSafetyWarningText ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(safetyTintColor.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.safetyWarningText ?? "")
                }
            } else {
                Text("From \(item.sourceHost)")
                    .font(.system(size: 11))
                    .livingToastSecondaryStyle()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
    
    @ViewBuilder
    private var actionArea: some View {
        if hasSafetyWarning {
            safetyActionArea
        } else {
            normalActionArea
        }
    }

    @ViewBuilder
    private var safetyActionArea: some View {
        HStack(spacing: 4) {
            switch item.safetyState {
            case .scanning:
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onCancel(item) },
                    tooltip: NSLocalizedString("Cancel", comment: "Tooltip for cancel button during safety scan in living downloads toast")
                )
            case .warning:
                DownloadActionButton(
                    iconName: "checkmark",
                    action: { onKeep?(item) },
                    tooltip: NSLocalizedString("Keep", comment: "Tooltip for keep button on safety warning in living downloads toast")
                )
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onDiscard?(item) },
                    tooltip: NSLocalizedString("Discard", comment: "Tooltip for discard button on safety warning in living downloads toast")
                )
            case .blocked, .policyBlocked:
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onDiscard?(item) },
                    tooltip: NSLocalizedString("Discard", comment: "Tooltip for discard button on blocked download in living downloads toast")
                )
            case .normal:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var normalActionArea: some View {
        switch item.state {
        case .inProgress:
            CircularProgressButton(
                progress: item.percentComplete >= 0 ? Double(item.percentComplete) / 100.0 : 0,
                progressColor: item.isPaused ? .orange : .phiPrimary,
                action: { onCancel(item) }
            )
            .frame(width: actionButtonSize, height: actionButtonSize)

        case .complete:
            HStack(spacing: 4) {
                DownloadActionButton(
                    icon: .init(.copyLink),
                    action: { onCopyLink(item) },
                    tooltip: NSLocalizedString("Copy Link", comment: "Tooltip for button to copy download URL in living downloads toast")
                )

                DownloadActionButton(
                    icon: .init(.showInFinder),
                    action: { onShowInFinder(item) },
                    tooltip: NSLocalizedString("Show in Finder", comment: "Tooltip for button to reveal downloaded file in Finder in living downloads toast")
                )

                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: onDismiss,
                    tooltip: NSLocalizedString("Dismiss", comment: "Tooltip for button to dismiss living download item")
                )
            }

        case .interrupted:
            HStack(spacing: 4) {
                if item.canResume {
                    DownloadActionButton(
                        iconName: "arrow.clockwise",
                        action: { onResume(item) },
                        tooltip: NSLocalizedString("Retry", comment: "Tooltip for button to retry interrupted download in living downloads toast")
                    )
                }

                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: onDismiss,
                    tooltip: NSLocalizedString("Dismiss", comment: "Tooltip for button to dismiss living download item")
                )
            }

        case .cancelled:
            DownloadActionButton(
                icon: .init(.deleteDownload),
                action: onDismiss,
                tooltip: NSLocalizedString("Dismiss", comment: "Tooltip for button to dismiss living download item")
            )
        }
    }
}

private enum LivingDownloadToastMetrics {
    static let cornerRadius: CGFloat = 10
}

/// HUD-material vibrancy used as the pre-macOS 26 fallback. macOS 26+ renders glass via SwiftUI's `.glassEffect`.
private struct LivingDownloadItemLegacyBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ColoredVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.backgroundColor = NSColor.white
        view.colorAlphaComponent = 0.5
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension View {
    /// macOS 26+ uses native Liquid Glass so primary/secondary label vibrancy adapts to underlying content;
    /// older systems keep the HUD-material fallback with an explicit edge highlight.
    @ViewBuilder
    func livingToastBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(LivingDownloadItemLegacyBackgroundView())
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    /// On macOS 26+ uses semantic `.primary` so glass vibrancy auto-adapts; older systems keep softened phi label color.
    @ViewBuilder
    func livingToastPrimaryStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.foregroundStyle(.primary)
        } else {
            self.foregroundColor(Color.phiPrimary.opacity(0.85))
        }
    }

    @ViewBuilder
    func livingToastSecondaryStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.foregroundStyle(.secondary)
        } else {
            self.foregroundColor(Color.phiPrimary.opacity(0.5))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct LivingDownloadsListView_Previews: PreviewProvider {
    static var previews: some View {
        LivingDownloadsListView(manager: TestLivingDownloadsManager())
            .padding(20)
            .frame(width: 400, height: 300)
            .background(
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.3)
            )
            .previewDisplayName("Living Downloads")
    }
}

class TestLivingDownloadsManager: LivingDownloadsManager {
    override init(downloadsManager: DownloadsManager? = nil) {
        super.init(downloadsManager: nil)
        
        autoDismissDuration = 999
        
        let item1 = DownloadItem(
            id: "living-1",
            fileName: "bfc6-windows-3.4.0-b7942603-0cb4-4d45-b6db-93957644d0c7.exe",
            url: "https://identity.ui.com/downloads/file.exe",
            state: .inProgress,
            percentComplete: 45,
            totalBytes: 100_000_000,
            receivedBytes: 45_000_000
        )
        item1.currentSpeed = 15_000_000
        
        let item2 = DownloadItem(
            id: "living-2",
            fileName: "document.pdf",
            url: "https://example.com/doc.pdf",
            state: .complete
        )
        
        let livingItem1 = LivingDownloadItem(downloadItem: item1, dismissDuration: 999)
        let livingItem2 = LivingDownloadItem(downloadItem: item2, dismissDuration: 999)
        
        livingItems = [livingItem1, livingItem2]
    }
}

// Interactive test view
struct LivingDownloadsTestView: View {
    @StateObject private var manager = InteractiveTestLivingDownloadsManager()
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.gray.opacity(0.2)
                .ignoresSafeArea()
            
            VStack(spacing: 12) {
                Text("Living Downloads Test")
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Button("Add Download") {
                        manager.addTestDownload()
                    }
                    
                    Button("Complete First") {
                        manager.completeFirst()
                    }
                    
                    Button("Cancel First") {
                        manager.cancelFirst()
                    }
                }
                
                Spacer()
            }
            .padding()
            
            // Living downloads
            LivingDownloadsListView(manager: manager)
                .padding(.top, 60)
                .padding(.trailing, 20)
        }
        .frame(width: 500, height: 400)
    }
}

class InteractiveTestLivingDownloadsManager: LivingDownloadsManager {
    private var counter = 0
    
    override init(downloadsManager: DownloadsManager? = nil) {
        super.init(downloadsManager: nil)
        autoDismissDuration = 3.0
    }
    
    func addTestDownload() {
        counter += 1
        let item = DownloadItem(
            id: "test-\(counter)",
            fileName: "test-file-\(counter).zip",
            url: "https://example.com/test-\(counter).zip",
            state: .inProgress,
            percentComplete: Int.random(in: 10...90),
            totalBytes: Int64.random(in: 10_000_000...500_000_000),
            receivedBytes: 0
        )
        item.currentSpeed = Int64.random(in: 5_000_000...20_000_000)
        addDownload(item)
    }
    
    func completeFirst() {
        if let first = livingItems.first {
            first.downloadItem.state = .complete
            first.downloadItem.percentComplete = 100
            first.startDismissTimer()
            objectWillChange.send()
        }
    }
    
    func cancelFirst() {
        if let first = livingItems.first {
            cancelDownload(first.downloadItem)
        }
    }
    
    override func cancelDownload(_ item: DownloadItem) {
        removeItem(byId: item.id)
    }
}

struct LivingDownloadsTestView_Previews: PreviewProvider {
    static var previews: some View {
        LivingDownloadsTestView()
            .previewDisplayName("Interactive Test")
    }
}
#endif

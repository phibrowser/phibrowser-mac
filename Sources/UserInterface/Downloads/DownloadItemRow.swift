// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import UniformTypeIdentifiers
struct DownloadItemRow: View {
    @ObservedObject var item: DownloadItem
    @State private var isHovered = false
    var isLast: Bool
    var onCopyLink: (DownloadItem) -> Void
    var onShowInFinder: (DownloadItem) -> Void
    var onPause: (DownloadItem) -> Void
    var onResume: (DownloadItem) -> Void
    var onCancel: (DownloadItem) -> Void
    var onRemove: (DownloadItem) -> Void
    var onKeep: ((DownloadItem) -> Void)?
    var onDiscard: ((DownloadItem) -> Void)?

    private let iconSize: CGFloat = 30
    private let buttonSize: CGFloat = 24
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // File icon
                fileIcon
                
                // File info
                fileInfo
                
                Spacer(minLength: 0)
                
                // Action buttons
                actionButtons
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            
            // Separator
            if !isLast {
                Rectangle()
                    .themedFill(.textPrimary.withAlphaComponent(0.1))
                    .frame(height: 1)
            }
        }
    }
    
    private var fileIcon: some View {
        // File type icon based on mime type or extension
        fileTypeIcon
    }
    
    @ViewBuilder
    private var fileTypeIcon: some View {
        let contentType = UTType(mimeType: item.mimeType)
        let image = NSWorkspace.shared.icon(for: contentType ?? .data)
        Image(nsImage: image)
    }
    
    /// Whether this item should show strikethrough style
    private var isFailedOrCancelled: Bool {
        item.state == .cancelled || item.state == .interrupted || (item.state == .complete && item.canShowInFolder == false)
    }
    
    /// Status label for failed/cancelled items
    private var statusLabel: String? {
        var label: String?
        switch item.state {
        case .cancelled: label = NSLocalizedString("Canceled", comment: "Download item row - Status label when download was cancelled")
        case .interrupted: label = NSLocalizedString("Failed", comment: "Download item row - Status label when download failed")
        case .complete:
            if item.canShowInFolder == false {
                label = NSLocalizedString("Deleted", comment: "Download item row - Status label when downloaded file was deleted")
            }
        default: break
        }
        return label
    }
    
    /// Format date in a friendly way
    private func formatRelativeDate(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        
        if interval < minute {
            return NSLocalizedString("Just now", comment: "Download item row - Relative time when download completed less than a minute ago")
        } else if interval < hour {
            let minutes = Int(interval / minute)
            return String(format: NSLocalizedString("%d min ago", comment: "Download item row - Relative time showing minutes since download completed"), minutes)
        } else if interval < 12 * hour {
            let hours = Int(interval / hour)
            return String(format: NSLocalizedString("%d hour ago", comment: "Download item row - Relative time showing hours since download completed"), hours)
        } else if interval < 3 * day {
            let days = Int(interval / day)
            if days == 0 {
                return NSLocalizedString("Today", comment: "Download item row - Relative time when download completed today")
            } else if days == 1 {
                return NSLocalizedString("Yesterday", comment: "Download item row - Relative time when download completed yesterday")
            } else {
                return String(format: NSLocalizedString("%d days ago", comment: "Download item row - Relative time showing days since download completed"), days)
            }
        } else {
            // More than 3 days: show specific date
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
    
    /// Secondary info text (source URL or completion date)
    private var secondaryInfoText: String {
        if item.state == .complete, let endTime = item.endTime {
            return formatRelativeDate(endTime)
        } else {
            return String(format: NSLocalizedString("From %@", comment: "Download item row - Source host label showing where the file is downloaded from"), item.sourceHost)
        }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 13))
                    .foregroundColor(Color.phiPrimary.opacity(0.85))
                    .strikethrough(isFailedOrCancelled, color: Color.phiPrimary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let label = statusLabel {
                    Text("· \(label)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.primary.opacity(0.5))
                }
            }

            Group {
                if hasSafetyWarning {
                    safetyWarningInfo
                } else if item.state == .inProgress {
                    progressInfo
                } else {
                    Text(secondaryInfoText)
                        .font(.system(size: 11))
                        .foregroundColor(Color.phiPrimary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private var safetyWarningInfo: some View {
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
    }
    
    @ViewBuilder
    private var progressInfo: some View {
        if isHovered {
            HStack(spacing: 4) {
                if !item.formattedProgress.isEmpty {
                    Text(item.formattedProgress)
                        .font(.system(size: 11))
                        .foregroundColor(Color.phiPrimary.opacity(0.5))
                }
                
                if !item.formattedSpeed.isEmpty && !item.isPaused {
                    Text("・")
                        .font(.system(size: 11))
                        .foregroundColor(Color.phiPrimary.opacity(0.5))
                    
                    Text(item.formattedSpeed)
                        .font(.system(size: 11))
                        .foregroundColor(Color.phiPrimary.opacity(0.5))
                }
                
                if item.isPaused {
                    Text(NSLocalizedString("・Paused", comment: "Download item row - Status indicator when download is paused"))
                        .font(.system(size: 11))
                        .foregroundColor(Color.orange.opacity(0.8))
                }
            }
        } else {
            Spacer()
                .frame(height: 11)
            PhiProgressView(
                progress: item.percentComplete >= 0 ? Double(item.percentComplete) / 100.0 : 0,
                style: .linear,
                progressColor: Color.phiPrimary
            )
            .frame(height: 3)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if hasSafetyWarning {
                safetyActionButtons
            } else {
                normalActionButtons
            }
        }
    }

    @ViewBuilder
    private var safetyActionButtons: some View {
        switch item.safetyState {
        case .scanning:
            DownloadActionButton(
                icon: .init(.deleteDownload),
                action: { onCancel(item) },
                tooltip: NSLocalizedString("Cancel", comment: "Download item row - Tooltip for cancel button during safety scan")
            )
        case .warning:
            DownloadActionButton(
                iconName: "checkmark",
                action: { onKeep?(item) },
                tooltip: NSLocalizedString("Keep", comment: "Download item row - Tooltip for keep button on safety warning")
            )
            DownloadActionButton(
                icon: .init(.deleteDownload),
                action: { onDiscard?(item) },
                tooltip: NSLocalizedString("Discard", comment: "Download item row - Tooltip for discard button on safety warning")
            )
        case .blocked, .policyBlocked:
            DownloadActionButton(
                icon: .init(.deleteDownload),
                action: { onDiscard?(item) },
                tooltip: NSLocalizedString("Discard", comment: "Download item row - Tooltip for discard button on blocked download")
            )
        case .normal:
            EmptyView()
        }
    }

    @ViewBuilder
    private var normalActionButtons: some View {
        switch item.state {
            case .inProgress:
                DownloadActionButton(
                    icon: .init(.copyLink),
                    action: { onCopyLink(item) },
                    tooltip: NSLocalizedString("Copy Link", comment: "Download item row - Tooltip for copy link button")
                )
                // Pause/Resume button
                DownloadActionButton(
                    icon: item.isPaused ? .init(.resumeDownload) : .init(.pauseDownload),
                    action: { item.isPaused ? onResume(item) : onPause(item) },
                    tooltip: item.isPaused ? NSLocalizedString("Resume", comment: "Download item row - Tooltip for resume download button") : NSLocalizedString("Pause", comment: "Download item row - Tooltip for pause download button")
                )
                
                // Cancel button
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onCancel(item) },
                    tooltip: NSLocalizedString("Cancel", comment: "Download item row - Tooltip for cancel download button")
                )
                
            case .complete:
                DownloadActionButton(
                    icon: .init(.copyLink),
                    action: { onCopyLink(item) },
                    tooltip: NSLocalizedString("Copy Link", comment: "Download item row - Tooltip for copy link button")
                )
                
                
                // Show in Finder button
                DownloadActionButton(
                    icon: .init(.showInFinder),
                    action: { onShowInFinder(item) },
                    tooltip: NSLocalizedString("Show in Finder", comment: "Download item row - Tooltip for show in finder button"),
                    isEnabled: item.canShowInFolder
                )
                
                // Remove button
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onRemove(item) },
                    tooltip: NSLocalizedString("Remove", comment: "Download item row - Tooltip for remove download button")
                )
                
                // More options menu
//                moreOptionsMenu
                
            case .cancelled, .interrupted:
                DownloadActionButton(
                    icon: .init(.copyLink),
                    action: { onCopyLink(item) },
                    tooltip: NSLocalizedString("Copy Link", comment: "Download item row - Tooltip for copy link button")
                )
                
                // Retry button (if can resume)
                if item.canResume {
                    DownloadActionButton(
                        iconName: "arrow.clockwise",
                        action: { onResume(item) },
                        tooltip: NSLocalizedString("Retry", comment: "Download item row - Tooltip for retry download button")
                    )
                }
                
                // Remove button
                DownloadActionButton(
                    icon: .init(.deleteDownload),
                    action: { onRemove(item) },
                    tooltip: NSLocalizedString("Remove", comment: "Download item row - Tooltip for remove download button")
                )
            }
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button(action: { onRemove(item) }) {
                Label(NSLocalizedString("Remove from list", comment: "Download item row - Menu option to remove download from list"), systemImage: "trash")
            }
            
            if item.canShowInFolder {
                Button(action: { onShowInFinder(item) }) {
                    Label(NSLocalizedString("Show in Finder", comment: "Download item row - Menu option to reveal file in Finder"), systemImage: "folder")
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.phiPrimary.opacity(0.06) : Color.clear)
                    .frame(width: 24, height: 24)
                
                // Three dots icon
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.phiPrimary.opacity(0.6))
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .frame(width: 24, height: 24)
    }
}

// MARK: - Download Action Button
struct DownloadActionButton: View {
    let iconName: String?
    let icon: Image?
    let isEnabled: Bool
    let action: () -> Void
    var tooltip: String = ""
    
    @State private var isHovered = false
    init(icon: Image? = nil, iconName: String? = nil, action: @escaping () -> Void, tooltip: String, isHovered: Bool = false, isEnabled: Bool = true) {
        self.icon = icon
        self.iconName = iconName
        self.action = action
        self.tooltip = tooltip
        self.isHovered = isHovered
        self.isEnabled = isEnabled
    }
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.phiPrimary.opacity(0.06) : Color.clear)
                
                if let icon {
                    icon
                } else if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .medium))
                        .themedTint(.textPrimary)
                }
            }
            .frame(width: 24, height: 24)
        }
        .disabled(!isEnabled)
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            guard isEnabled else {
                return
            }
            isHovered = hovering
        }
        .help(tooltip)
    }
}

// MARK: - Preview

#if DEBUG
struct DownloadItemRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            // In Progress - 45%
            DownloadItemRow(
                item: PreviewDownloadItem.inProgress,
                isLast: false,
                onCopyLink: { _ in },
                onShowInFinder: { _ in },
                onPause: { _ in },
                onResume: { _ in },
                onCancel: { _ in },
                onRemove: { _ in }
            )
            
            // In Progress - Paused
            DownloadItemRow(
                item: PreviewDownloadItem.paused,
                isLast: false,
                onCopyLink: { _ in },
                onShowInFinder: { _ in },
                onPause: { _ in },
                onResume: { _ in },
                onCancel: { _ in },
                onRemove: { _ in }
            )
            
            // Completed
            DownloadItemRow(
                item: PreviewDownloadItem.completed,
                isLast: false,
                onCopyLink: { _ in },
                onShowInFinder: { _ in },
                onPause: { _ in },
                onResume: { _ in },
                onCancel: { _ in },
                onRemove: { _ in }
            )
            
            // Interrupted/Failed
            DownloadItemRow(
                item: PreviewDownloadItem.failed,
                isLast: false,
                onCopyLink: { _ in },
                onShowInFinder: { _ in },
                onPause: { _ in },
                onResume: { _ in },
                onCancel: { _ in },
                onRemove: { _ in }
            )
            
            // Cancelled
            DownloadItemRow(
                item: PreviewDownloadItem.cancelled,
                isLast: true,
                onCopyLink: { _ in },
                onShowInFinder: { _ in },
                onPause: { _ in },
                onResume: { _ in },
                onCancel: { _ in },
                onRemove: { _ in }
            )
        }
        .padding(.horizontal, 16)
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .previewDisplayName("Download Item States")
    }
}

// MARK: - Preview Test Data

enum PreviewDownloadItem {
    /// In progress download at 45%
    static var inProgress: DownloadItem {
        let item = DownloadItem(
            id: "preview-in-progress",
            fileName: "Xcode_15.2.xip",
            url: "https://developer.apple.com/downloads/Xcode_15.2.xip",
            state: .inProgress,
            percentComplete: 45,
            totalBytes: 8_000_000_000,
            receivedBytes: 3_600_000_000
        )
        item.currentSpeed = 15_000_000 // 15 MB/s
        return item
    }
    
    /// Paused download at 30%
    static var paused: DownloadItem {
        let item = DownloadItem(
            id: "preview-paused",
            fileName: "large-video-file.mp4",
            url: "https://videos.example.com/large-video-file.mp4",
            state: .inProgress,
            percentComplete: 30,
            totalBytes: 2_500_000_000,
            receivedBytes: 750_000_000
        )
        item.isPaused = true
        item.canResume = true
        return item
    }
    
    /// Completed download
    static var completed: DownloadItem {
        let item = DownloadItem(
            id: "preview-completed",
            fileName: "Phi-Browser-1.0.0.dmg",
            url: "https://releases.phi.com/Phi-Browser-1.0.0.dmg",
            state: .complete,
            percentComplete: 100,
            totalBytes: 156_000_000,
            receivedBytes: 156_000_000
        )
        item.canShowInFolder = true
        item.canOpenDownload = true
        item.isDone = true
        return item
    }
    
    /// Failed/Interrupted download
    static var failed: DownloadItem {
        let item = DownloadItem(
            id: "preview-failed",
            fileName: "installer-package.pkg",
            url: "https://downloads.example.com/installer-package.pkg",
            state: .interrupted,
            percentComplete: 67,
            totalBytes: 500_000_000,
            receivedBytes: 335_000_000
        )
        item.canResume = true
        return item
    }
    
    /// Cancelled download
    static var cancelled: DownloadItem {
        let item = DownloadItem(
            id: "preview-cancelled",
            fileName: "old-archive.zip",
            url: "https://archive.example.com/old-archive.zip",
            state: .cancelled,
            percentComplete: 20,
            totalBytes: 100_000_000,
            receivedBytes: 20_000_000
        )
        item.canResume = false
        return item
    }
}
#endif

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
struct DownloadsListView: View {
    @ObservedObject var downloadsManager: DownloadsManager
    @State private var contentSize: CGSize = .zero
    
    private let maxVisibleItems = 5
    private let itemHeight: CGFloat = 56
    private let listWidth: CGFloat = 308
    private let bottomBarHeight: CGFloat = 33
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if downloadsManager.downloads.isEmpty {
                emptyStateView
            } else {
                downloadsList
            }
            
            DownloadsBottomBar()
        }
        .frame(width: 340)
        .background(.clear)
        .onAppear {
            downloadsManager.refreshDownloads()
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .themedTint(.textSecondary)
            
            Text(NSLocalizedString("No Downloads", comment: "Downloads list - Empty state text when no downloads exist"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
    
    private var downloadsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(downloadsManager.downloads.enumerated()), id: \.element.id) { index, item in
                    DownloadItemRow(
                        item: item,
                        isLast: index == downloadsManager.downloads.count - 1,
                        onCopyLink: { downloadsManager.copyLink($0) },
                        onShowInFinder: { downloadsManager.showInFinder($0) },
                        onPause: { downloadsManager.pauseDownload($0) },
                        onResume: { downloadsManager.resumeDownload($0) },
                        onCancel: { downloadsManager.cancelDownload($0) },
                        onRemove: { downloadsManager.removeDownload($0) },
                        onKeep: { downloadsManager.keepDownload($0) },
                        onDiscard: { downloadsManager.discardDownload($0) }
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .mask(
            VStack(spacing: 0) {
                Color.black
                
                LinearGradient(
                    gradient: Gradient(colors: [Color.black, Color.black.opacity(0)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
            }
        )
    }
}

private struct DownloadsBottomBar: View {
    @State private var isHovered: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.phiPrimary.opacity(0.1))
            
            HStack {
                Spacer()
                
                Button(action: {
                    openAllDownloadsPage()
                }) {
                    HStack(spacing: 4) {
                        Text(NSLocalizedString("All Downloads", comment: "Downloads list - Button to open full downloads page"))
                            .font(.system(size: 11))
                            .foregroundColor(Color.phiPrimary.opacity(isHovered ? 1.0 : 0.85))
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.phiPrimary.opacity(isHovered ? 0.85 : 0.6))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHovered ? Color.phiPrimary.opacity(0.06) : Color.clear)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(height: 33)
        }
    }
    
    private func openAllDownloadsPage() {
        let url = URLProcessor.processUserInput("phi://downloads")
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(url)
    }
}

// MARK: - Color Extension
extension Color {
    static let phiPrimary = Color.primary
}

// MARK: - Preview
#if DEBUG
struct DownloadsListView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadsListView(downloadsManager: MockDownloadsManager())
            .frame(width: 340)
            .background(Color.gray.opacity(0.1))
    }
}

class MockDownloadsManager: DownloadsManager {
    override init(browserState: BrowserState? = nil) {
        super.init(browserState: nil)
        
        // Add mock data
        self.downloads = [
            DownloadItem(
                id: "1",
                fileName: "bfc6-windows-3.4.0-b7942603-0cb4-4d45-b6db-93957644d0c7.exe",
                url: "https://identity.ui.com/downloads/file.exe",
                state: .complete
            ),
            DownloadItem(
                id: "2",
                fileName: "document.pdf",
                url: "https://example.com/doc.pdf",
                state: .complete
            ),
            DownloadItem(
                id: "3",
                fileName: "archive.zip",
                url: "https://github.com/release/v1.0.zip",
                state: .inProgress,
                percentComplete: 45,
                totalBytes: 100_000_000,
                receivedBytes: 45_000_000
            ),
            DownloadItem(
                id: "4",
                fileName: "video.mp4",
                url: "https://videos.com/stream.mp4",
                state: .interrupted
            ),
            DownloadItem(
                id: "5",
                fileName: "image.png",
                url: "https://images.com/photo.png",
                state: .complete
            )
            , DownloadItem(
                id: "6",
                fileName: "image.png",
                url: "https://images.com/photo.png",
                state: .complete
            )
            ,DownloadItem(
                id: "7",
                fileName: "image.png",
                url: "https://images.com/photo.png",
                state: .complete
            )
        ]
    }
    
    override func refreshDownloads() {
    }
}
#endif

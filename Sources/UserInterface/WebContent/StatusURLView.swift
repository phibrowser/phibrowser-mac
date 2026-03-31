// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Status URL display view (similar to Chromium's StatusBubble)
/// Shows the target URL in the bottom-left corner when hovering over links
struct StatusURLView: View {
    @ObservedObject var viewModel: StatusURLViewModel

    @State private var displayedURL: String = ""
    @State private var isVisible: Bool = false
    @State private var hideTask: DispatchWorkItem?

    private let hideDelay: TimeInterval = 0.1

    var body: some View {
        Text(displayedURL.isEmpty ? " " : displayedURL)
            .font(.system(size: 12))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: LiquidGlassCompatible.webContentContainerCornerRadius)
                    .themedFill(.contentOverlayBackground)
                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.05), value: isVisible)
            .onChange(of: viewModel.url) { _, newURL in
                handleURLChange(newURL)
            }
            .onAppear {
                if !viewModel.url.isEmpty {
                    displayedURL = viewModel.url
                    isVisible = true
                }
            }
    }

    private func handleURLChange(_ newURL: String) {
        hideTask?.cancel()
        hideTask = nil

        if newURL.isEmpty {
            // Delay hiding to prevent flicker when quickly moving between links
            let task = DispatchWorkItem { [self] in
                isVisible = false
            }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: task)
        } else {
            displayedURL = newURL
            isVisible = true
        }
    }
}

// MARK: - AppKit Hosting

extension StatusURLView {
    static func makeHostingController(viewModel: StatusURLViewModel) -> NSHostingController<StatusURLView> {
        let statusView = StatusURLView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: statusView)
        let hostingView = hostingController.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Enable layer-backing and set z-position to ensure it's always on top.
        hostingView.wantsLayer = true
        hostingView.layer?.zPosition = 1000

        return hostingController
    }
}

#if DEBUG
struct StatusURLView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel1 = StatusURLViewModel()
        viewModel1.url = "https://www.example.com/very/long/path/to/page"

        let viewModel2 = StatusURLViewModel()
        viewModel2.url = "https://github.com"

        let viewModel3 = StatusURLViewModel()
        viewModel3.url = ""

        return VStack(alignment: .leading, spacing: 20) {
            StatusURLView(viewModel: viewModel1)
                .frame(width: 300)

            StatusURLView(viewModel: viewModel2)
                .frame(width: 300)

            StatusURLView(viewModel: viewModel3)
                .frame(width: 300)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
}
#endif

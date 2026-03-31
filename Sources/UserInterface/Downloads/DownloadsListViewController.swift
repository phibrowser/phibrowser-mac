// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftUI

/// Root popover content that lets the visual-effect background extend into the arrow.
struct DownloadsListContentView: View {
    @ObservedObject var downloadsManager: DownloadsManager
    
    var body: some View {
        DownloadsListView(downloadsManager: downloadsManager)
            .background(
                VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                    .ignoresSafeArea()
            )
    }
}

/// NSVisualEffectView wrapper for SwiftUI
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = ColoredVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.colorAlphaComponent = 0.5
        view.backgroundColor = .white
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

class DownloadsListViewController: NSHostingController<DownloadsListContentView> {
    #if DEBUG
    static let mockDownloads = false
    #endif
    
    init(browserState: BrowserState) {
        #if DEBUG
        let manager: DownloadsManager = Self.mockDownloads ? TestDownloadsManager() : browserState.downloadsManager
        #else
        let manager = browserState.downloadsManager
        #endif
        
        let contentView = DownloadsListContentView(downloadsManager: manager)
        super.init(rootView: contentView)
    }
    
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI
class OverlayToastViewController: NSViewController {
    private lazy var viewModel: OverlayToastViewModel = {
        return OverlayToastViewModel(browserState: state)
    }()
    
    private var themeObserver: ThemeObserver
    
    private lazy var toastContainerViewController: NSHostingController<AnyView> = {
        return NSHostingController(rootView: makeRootView())
    }()
    
    let state: BrowserState
    
    init(state: BrowserState) {
        self.state = state
        self.themeObserver = ThemeObserver(themeSource: state.themeContext)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let bgView = BgView()
        bgView.viewModel = viewModel
        view = bgView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Disable NSHostingController's intrinsic content size constraints (macOS 13+)
        if #available(macOS 13.0, *) {
            toastContainerViewController.sizingOptions = []
        }
        
        let hostingView = toastContainerViewController.view
        view.addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    private func makeRootView() -> AnyView {
        AnyView(
            OverlayToastContainer(viewModel: viewModel)
                .phiThemeObserver(themeObserver)
        )
    }
    
}

extension OverlayToastViewController {
    /// A transparent background view that allows click-through for empty areas,
    /// but forwards events to NSHostingView when clicking on toast content areas.
    ///
    /// Uses viewModel to determine if a point is inside any visible toast area.
    /// This approach works because SwiftUI doesn't create separate NSViews for each control -
    /// instead, NSHostingView handles all events internally.
    class BgView: NSView {
        weak var viewModel: OverlayToastViewModel?
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Check if the point is inside any toast area using viewModel
            guard let viewModel = viewModel else {
                AppLogDebug("[OverlayHitTest] viewModel is nil")
                return nil
            }
            // SwiftUI renders the toast stack inside one hosting view, so hit testing
            // always lands on the overlay unless we explicitly gate events by toast frame.
            let shouldHandle = viewModel.shouldHandleHitTest(at: point)
//            AppLogDebug("[OverlayHitTest] point: \(point), toastFrame: \(toastFrame), shouldHandle: \(shouldHandle)")
            
            // If the point is inside a toast area, forward to NSHostingView
            if shouldHandle {
                AppLogDebug("[OverlayHitTest] forwarding to NSHostingView")
                // Return the first subview (NSHostingView) to handle the event
                return subviews.first
            }
            
            // Point is outside all toast areas - allow click-through
            return nil
        }
    }
}

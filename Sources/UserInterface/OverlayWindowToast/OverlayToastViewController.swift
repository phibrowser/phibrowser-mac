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
    
    private lazy var toastContainerViewController: ThemedHostingController<OverlayToastContainer> = {
        return ThemedHostingController(rootView: OverlayToastContainer(viewModel: viewModel), themeSource: state.themeContext)
    }()
    
    let state: BrowserState
    
    init(state: BrowserState) {
        self.state = state
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

        #if DEBUG
        seedOverlayToastForUITestsIfNeeded()
        #endif
    }

    #if DEBUG
    private func seedOverlayToastForUITestsIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest"),
              arguments.contains("-overlayToastUITest")
        else {
            return
        }

        let duration = TimeInterval(arguments.value(after: "-overlayToastUITestDuration") ?? "") ?? 30
        let placement = arguments.value(after: "-overlayToastUITestPlacement") ?? "both"
        let title = arguments.value(after: "-overlayToastUITestTitle") ?? "Overlay Toast UI Test"
        let message = arguments.value(after: "-overlayToastUITestMessage") ?? "Rendered by the shared overlay container."

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [state] in
            if arguments.contains("-overlayToastUITestAllCases") {
                Self.enqueueOverlayToastUITestMatrix(duration: duration, windowId: state.windowId)
                return
            }

            switch placement {
            case OverlayToastPlacement.topCenter.rawValue:
                OverlayToastCenter.shared.show(
                    title: title,
                    message: message,
                    duration: duration,
                    placement: .topCenter,
                    in: .windowId(state.windowId)
                )
            case OverlayToastPlacement.topTrailing.rawValue:
                OverlayToastCenter.shared.show(
                    title: title,
                    message: message,
                    duration: duration,
                    placement: .topTrailing,
                    in: .windowId(state.windowId)
                )
            default:
                OverlayToastCenter.shared.show(
                    title: title,
                    message: message,
                    duration: duration,
                    placement: .topCenter,
                    in: .windowId(state.windowId)
                )
                OverlayToastCenter.shared.show(
                    title: "Overlay Toast Right",
                    message: "Top trailing placement.",
                    duration: duration,
                    placement: .topTrailing,
                    in: .windowId(state.windowId)
                )
            }
        }
    }

    private struct OverlayToastUITestSeed {
        let title: String
        let message: String?
    }

    private typealias OverlayToastUITestPair = (
        topCenter: OverlayToastUITestSeed,
        topTrailing: OverlayToastUITestSeed
    )

    private static func enqueueOverlayToastUITestMatrix(duration: TimeInterval, windowId: Int) {
        let pairs: [OverlayToastUITestPair] = [
            (
                topCenter: .init(
                    title: "Center short title",
                    message: "Center short message"
                ),
                topTrailing: .init(
                    title: "Right short title",
                    message: "Right short message"
                )
            ),
            (
                topCenter: .init(
                    title: "Center long title that wraps across the toast while staying readable inside the liquid glass surface",
                    message: "Center long message with enough detail to exercise multi-line wrapping, vertical padding, and the fallback blur background without clipping text."
                ),
                topTrailing: .init(
                    title: "Right long title that checks trailing toast wrapping behavior near the window edge",
                    message: "Right long message that should remain legible while sharing the top edge with browser controls and window chrome."
                )
            ),
            (
                topCenter: .init(
                    title: "Center title only",
                    message: nil
                ),
                topTrailing: .init(
                    title: "Right title only",
                    message: nil
                )
            ),
            (
                topCenter: .init(
                    title: "",
                    message: "Center message only"
                ),
                topTrailing: .init(
                    title: "",
                    message: "Right message only"
                )
            )
        ]

        for (index, pair) in pairs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * TimeInterval(index)) {
                OverlayToastCenter.shared.show(
                    title: pair.topCenter.title,
                    message: pair.topCenter.message,
                    duration: duration,
                    placement: .topCenter,
                    in: .windowId(windowId)
                )
                OverlayToastCenter.shared.show(
                    title: pair.topTrailing.title,
                    message: pair.topTrailing.message,
                    duration: duration,
                    placement: .topTrailing,
                    in: .windowId(windowId)
                )
            }
        }
    }
    #endif
}

#if DEBUG
private extension [String] {
    func value(after option: String) -> String? {
        guard let index = firstIndex(of: option) else { return nil }
        let valueIndex = self.index(after: index)
        guard valueIndex < endIndex else { return nil }
        return self[valueIndex]
    }
}
#endif

extension OverlayToastViewController {
    /// Allows click-through outside visible toast areas while preserving normal
    /// hit testing for both SwiftUI content and embedded AppKit controls.
    class BgView: NSView {
        weak var viewModel: OverlayToastViewModel?
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let viewModel = viewModel else {
                AppLogDebug("[OverlayHitTest] viewModel is nil")
                return nil
            }
            // AppKit supplies the point in the superview's coordinate space;
            // the published toast frames use this view's local coordinates.
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint), viewModel.shouldHandleHitTest(at: localPoint) else {
                return nil
            }

            // Returning the hosting view directly bypasses native descendants,
            // preventing controls such as the Share button from receiving clicks.
            return super.hitTest(point)
        }
    }
}

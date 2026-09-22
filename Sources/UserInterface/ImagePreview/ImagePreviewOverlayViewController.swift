// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

final class ImagePreviewOverlayViewController: NSViewController {
    private final class OverlayRootView: NSView {
        weak var controller: ImagePreviewOverlayViewController?

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let controller, controller.state.isVisible else {
                return nil
            }
            return super.hitTest(point) ?? self
        }

        override func mouseDown(with event: NSEvent) {
            controller?.handleBackgroundClick(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if controller?.handleKeyDown(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }

    let state: BrowserImagePreviewState
    private let previewViewController: ImagePreviewViewController
    private let dimmingView = NSView()
    private let panelContainer = NSVisualEffectView()
    private var cancellables = Set<AnyCancellable>()

    init(state: BrowserImagePreviewState) {
        self.state = state
        self.previewViewController = ImagePreviewViewController(state: state)
        super.init(nibName: nil, bundle: nil)
        previewViewController.onOpenInWindow = { [weak self] in
            guard let self, self.state.isVisible else { return }
            let controller = ImagePreviewWindowController(items: self.state.items, currentIndex: self.state.currentIndex)
            self.state.close()
            controller.showWindow(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = OverlayRootView()
        rootView.controller = self
        self.view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.isHidden = true

        dimmingView.wantsLayer = true
        dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        panelContainer.material = .hudWindow
        panelContainer.blendingMode = .withinWindow
        panelContainer.state = .active
        panelContainer.wantsLayer = true
        panelContainer.layer?.cornerRadius = 20
        panelContainer.layer?.masksToBounds = true

        view.addSubview(dimmingView)
        view.addSubview(panelContainer)

        addChild(previewViewController)
        panelContainer.addSubview(previewViewController.view)

        dimmingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        panelContainer.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.84).priority(490)
            make.height.equalToSuperview().multipliedBy(0.84).priority(490)
            make.width.lessThanOrEqualTo(1080)
            make.height.lessThanOrEqualTo(820)
            make.leading.greaterThanOrEqualToSuperview().offset(32)
            make.trailing.lessThanOrEqualToSuperview().offset(-32)
            make.top.greaterThanOrEqualToSuperview().offset(32)
            make.bottom.lessThanOrEqualToSuperview().offset(-32)
        }

        previewViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        bindState()
    }

    func handleBackgroundClick(with event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        if panelContainer.frame.contains(point) == false {
            state.close()
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        previewViewController.handleKeyDown(event)
    }

    private func bindState() {
        state.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self else { return }
                view.isHidden = !isVisible
                if isVisible {
                    view.window?.makeFirstResponder(view)
                }
            }
            .store(in: &cancellables)
    }

}

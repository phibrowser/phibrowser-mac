// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

class FeedbackViewModel: ObservableObject {
    @Published var urlString: String = ""
}

class FeedbackViewController: NSViewController {
    let hostWindowController: MainBrowserWindowController
    
    private var viewModel = FeedbackViewModel()
    
    private lazy var feedbackView: FeedbackView = {
        // Pass the viewModel to the View
        let view = FeedbackView(viewModel: viewModel) { [weak self] in
            guard let self else { return }
            // onPrivacyPolicyTap
            hostWindowController.browserState.openTab("https://phibrowser.com/privacy/")
            hostWindowController.window?.orderFront(nil)
        } onTermsOfServiceTap: { [weak self] in
            guard let self else { return }
            hostWindowController.browserState.openTab("https://phibrowser.com/terms-of-service/")
            hostWindowController.window?.orderFront(nil)
        } onCancel: { [weak self] in
            guard let self else { return }
            closeWindow()
        } onSend: {[weak self] payload in
            guard let self else { return }
            ChromiumLauncher.sharedInstance().bridge?.submitFeedback(withParams: payload, windowId: hostWindowController.browserState.windowId.int64Value)
            closeWindow()
        }
        return view
    }()
    
    private lazy var feedbackHosting = ThemedHostingController(rootView: feedbackView)
    
    init(host: MainBrowserWindowController) {
        self.hostWindowController = host
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
//        view.layer?.backgroundColor = .white
        view.phiLayer?.backgroundColor = .white <> NSColor.black.withAlphaComponent(0.7).cgColor
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(feedbackHosting.view)
        feedbackHosting.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 520, height: 652))
        }
        
        if let tab = hostWindowController.browserState.focusingTab {
            updateActiveTabURL(URLProcessor.phiBrandEnsuredUrlString(tab.url ?? "") )
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
    }
    
    func updateActiveTabURL(_ string: String?) {
        // Update ViewModel directly.
        // Since FeedbackView observes this viewModel, it will update UI.
        DispatchQueue.main.async {
            self.viewModel.urlString = string ?? ""
        }
    }
    
    private func closeWindow() {
        view.window?.close()
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

@MainActor
class FeedbackViewController: NSViewController, NSWindowDelegate {
    private(set) var hostWindowController: MainBrowserWindowController
    
    private let viewModel = FeedbackViewModel()
    
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
        } onSend: { [weak self] in
            guard let self else { return }
            submitFeedback()
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
        view = FeedbackBackgroundView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(feedbackHosting.view)
        feedbackHosting.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 520, height: 580))
        }
        
        refreshFeedbackContext()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
    }
    
    func updateActiveTabURL(_ string: String?) {
        // Update ViewModel directly.
        // Since FeedbackView observes this viewModel, it will update UI.
        DispatchQueue.main.async {
            guard self.viewModel.previousSessionCrash == nil else { return }
            self.viewModel.urlString = string ?? ""
        }
    }

    /// When set (renderer crash page → feedback), this immutable snapshot of the
    /// CRASHED tab's url/title is used instead of the focused tab's — a split
    /// partner pane's crash isn't the focused tab, and focus must not be relied
    /// on. Snapshotted (not a weak Tab) so closing or recovering the crashed tab
    /// before the user hits Send can't swap in the focused tab's context.
    private var crashContext: (url: String?, title: String)?

    /// Rebind to the window now reusing this app-global feedback window, so the
    /// report's window-scoped context — the windowId for Chromium system logs and
    /// the focusingTab fallback — follows the window feedback was invoked from,
    /// not whichever window first created the (shared) feedback window.
    func rebindHost(_ host: MainBrowserWindowController) {
        // Don't repoint an in-flight submit: submitFeedback already captured its
        // windowId and is awaiting Chromium logs; rebinding now would let the
        // enqueue mix this window's context with that submit's logs.
        guard !viewModel.isSubmitting else { return }
        hostWindowController = host
    }

    /// Inject (or clear, with nil) the crashed-tab context and re-apply it.
    /// Called when feedback is opened from a crash page, incl. the already-open
    /// window case.
    func setCrashContextTab(_ tab: Tab?) {
        // Leave an in-flight submit's draft untouched (see rebindHost): mutating
        // url/title mid-submit would be read by the pending enqueue after its await.
        guard !viewModel.isSubmitting, viewModel.previousSessionCrash == nil else { return }
        crashContext = tab.map { (url: $0.url, title: $0.title) }
        refreshFeedbackContext()
    }

    @discardableResult
    func setPreviousSessionCrash(_ context: PreviousSessionCrashContext) -> Bool {
        guard viewModel.setPreviousSessionCrash(context) else { return false }
        crashContext = nil
        return true
    }

    private func refreshFeedbackContext() {
        viewModel.componentVersions = hostWindowController.browserState.extensionManager.phiExtensionVersions
        // The current tab after relaunch is not evidence of the crash site.
        // Preserve only the URL the user explicitly enters in this form.
        guard viewModel.previousSessionCrash == nil else { return }
        if let crashContext {
            viewModel.urlString = URLProcessor.phiBrandEnsuredUrlString(crashContext.url ?? "")
            viewModel.pageTitle = crashContext.title
        } else if let tab = hostWindowController.browserState.focusingTab {
            viewModel.urlString = URLProcessor.phiBrandEnsuredUrlString(tab.url ?? "")
            viewModel.pageTitle = tab.title
        }
    }

    private func submitFeedback() {
        guard viewModel.canSend else { return }

        // Snapshot before awaiting logs, while the feedback window still has focus.
        let inputSourceMetadata = FeedbackOutbox.currentInputSourceMetadata()
        refreshFeedbackContext()
        viewModel.isSubmitting = true

        let windowId = Int64(hostWindowController.browserState.windowId)
        let submittingAccountID = AccountController.shared.account?.userID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                viewModel.isSubmitting = false
                if view.window?.isVisible != true {
                    viewModel.clearPreviousSessionCrash()
                }
            }
            let chromiumSystemLogsText = await fetchChromiumSystemLogsText(windowId: windowId)

            do {
                guard AccountController.shared.account?.userID == submittingAccountID else {
                    throw FeedbackOutboxError.missingAccount
                }
                try viewModel.enqueueFeedback(
                    chromiumSystemLogsText: chromiumSystemLogsText,
                    inputSourceMetadata: inputSourceMetadata
                )
                closeWindow()
            } catch {
                AppLogError("Feedback V2 enqueue failed: \(error.localizedDescription)")
                viewModel.localSaveError = error.localizedDescription
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !viewModel.isSubmitting else { return }
        viewModel.clearPreviousSessionCrash()
    }

    private func fetchChromiumSystemLogsText(windowId: Int64) async -> String? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("Feedback V2 Chromium system logs skipped because the bridge is unavailable")
            return nil
        }

        return await withCheckedContinuation { continuation in
            bridge.getFeedbackSystemLogsText(withWindowId: windowId) { text in
                if text == nil {
                    AppLogWarn("Feedback V2 Chromium system logs skipped because Chromium returned no text")
                }
                continuation.resume(returning: text)
            }
        }
    }
    
    private func closeWindow() {
        view.window?.close()
    }
}

private final class FeedbackBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackgroundAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateBackgroundAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundAppearance()
    }

    private func updateBackgroundAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import WebKit

/// A transparent view that allows window dragging when the title bar is hidden
private class WindowDragView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Completely transparent - no drawing needed
    }
    
    override func mouseDown(with event: NSEvent) {
        // Perform window drag
        window?.performDrag(with: event)
    }
}

/// Window controller for displaying account-related web pages in a separate window
class AccountWebWindowController: NSWindowController {
    private var webView: WKWebView!
    private let targetURL: String

    /// Callback that will be called when the window is closed
    var onWindowClosed: (() -> Void)?

    /// Callback that delivers the saved avatar image immediately (before the window closes)
    var onAvatarSaved: ((NSImage) -> Void)?

    init(url: String) {
        self.targetURL = url

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Invitation Code Details", comment: "Account settings - Window title for invitation code details")
        window.center()
        window.minSize = NSSize(width: 600, height: 800)
        window.maxSize = NSSize(width: 768, height: 1024)

        // Make title bar transparent and hide title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        super.init(window: window)

        window.delegate = self
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWebView() {
        guard let window = window, let contentView = window.contentView else { return }

        // Configure web view with token injection
        let configuration = WKWebViewConfiguration()

        // Add message handler to receive token requests from the page
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "tokenHandler")
        userContentController.add(self, name: "avatarHandler")
        configuration.userContentController = userContentController

        // Inject JavaScript to provide chrome.runtime API for token retrieval
        let token = AuthManager.shared.getAccessTokenSyncly() ?? ""
        let injectionScript = """
        (function() {
            // Mock chrome.runtime API for account-frontend
            window.chrome = window.chrome || {};
            window.chrome.runtime = window.chrome.runtime || {};

            // Mock sendMessage to handle get-token requests
            window.chrome.runtime.sendMessage = function(extensionId, message, callback) {
                if (message && message.type === 'get-token') {
                    // Return the token injected from Swift
                    setTimeout(() => {
                        callback({ token: '\(token)' });
                    }, 0);
                    return true;
                }
                return false;
            };

            console.log('[Phi] Chrome runtime API injected for token support');
        })();
        """

        let userScript = WKUserScript(
            source: injectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(userScript)

        webView = WKWebView(frame: contentView.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self

        // Enable developer tools / Inspect Element in DEBUG and NIGHTLY builds
        #if DEBUG || NIGHTLY_BUILD
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        contentView.addSubview(webView)

        // Add draggable area at the top for window movement (since title bar is hidden)
        let dragAreaHeight: CGFloat = 40
        let dragView = WindowDragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dragView)
        
        NSLayoutConstraint.activate([
            dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dragView.heightAnchor.constraint(equalToConstant: dragAreaHeight)
        ])

        // Load URL (token is injected via JavaScript)
        if let url = URL(string: targetURL) {
            AppLogInfo("🔐 [AccountWebWindow] Loading URL: \(targetURL)")
            webView.load(URLRequest(url: url))
        } else {
            AppLogError("❌ [AccountWebWindow] Invalid URL: \(targetURL)")
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.delegate = self
    }
}

// MARK: - WKScriptMessageHandler

extension AccountWebWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        AppLogInfo("📄 [AccountWebWindow] Received message: \(message.name)")

        if message.name == "avatarHandler",
           let base64String = message.body as? String,
           let data = Data(base64Encoded: base64String),
           let image = NSImage(data: data) {
            AppLogInfo("📄 [AccountWebWindow] Avatar image decoded successfully")
            onAvatarSaved?(image)
        }
    }
}

// MARK: - WKNavigationDelegate

extension AccountWebWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        AppLogInfo("📄 [AccountWebWindow] Started loading: \(webView.url?.absoluteString ?? "unknown")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLogInfo("📄 [AccountWebWindow] ✅ Page loaded successfully: \(webView.url?.absoluteString ?? "unknown")")
        AppLogInfo("📄 [AccountWebWindow] Page title: \(webView.title ?? "no title")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogError("❌ [AccountWebWindow] Navigation failed: \(error.localizedDescription)")
        AppLogError("❌ [AccountWebWindow] Error domain: \(error._domain), code: \(error._code)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        AppLogError("❌ [AccountWebWindow] Provisional navigation failed: \(error.localizedDescription)")
        AppLogError("❌ [AccountWebWindow] Error domain: \(error._domain), code: \(error._code)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        AppLogInfo("📄 [AccountWebWindow] Navigation action: \(navigationAction.request.url?.absoluteString ?? "unknown")")
        AppLogInfo("📄 [AccountWebWindow] Navigation type: \(navigationAction.navigationType.rawValue)")

        // When user clicks a link, open it in the main browser window instead of this WebView
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            AppLogInfo("📄 [AccountWebWindow] Opening link in main browser: \(url.absoluteString)")
            MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(url.absoluteString, focusAfterCreate: true)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        AppLogInfo("📄 [AccountWebWindow] Navigation response: \(navigationResponse.response.url?.absoluteString ?? "unknown")")
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            AppLogInfo("📄 [AccountWebWindow] HTTP Status: \(httpResponse.statusCode)")
            AppLogInfo("📄 [AccountWebWindow] Headers: \(httpResponse.allHeaderFields)")
        }
        decisionHandler(.allow)
    }
}

// MARK: - NSWindowDelegate

extension AccountWebWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppLogInfo("🪟 [AccountWebWindow] Window closing, calling completion handler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tokenHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "avatarHandler")
        onWindowClosed?()
    }
}

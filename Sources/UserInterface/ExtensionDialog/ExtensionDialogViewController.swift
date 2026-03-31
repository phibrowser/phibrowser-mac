// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import WebKit

final class ExtensionDialogViewController: NSViewController {
    let sessionId: String
    private let html: String
    private let measureContentSize: Bool
    private var webView: WKWebView!
    weak var delegate: ExtensionDialogViewControllerDelegate?

    private static let bridgeScript = """
    window.phiMacClient = {
        postMessage: function(data) {
            window.webkit.messageHandlers.notification.postMessage({
                type: "submit",
                data: typeof data === 'string' ? data : JSON.stringify(data)
            });
        },
        close: function() {
            window.webkit.messageHandlers.notification.postMessage({ type: "close" });
        }
    };
    """

    init(html: String, sessionId: String, size: NSSize = NSSize(width: 480, height: 360), measureContentSize: Bool = false) {
        self.html = html
        self.sessionId = sessionId
        self.measureContentSize = measureContentSize
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = size
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        userContentController.add(self, name: "notification")

        let script = WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(script)

        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: NSRect(origin: .zero, size: preferredContentSize), configuration: configuration)
        webView.navigationDelegate = self

        #if DEBUG || NIGHTLY_BUILD
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        view = webView
    }

    func loadContent() {
        _ = view
        webView.loadHTMLString(html, baseURL: nil)
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notification")
    }
}

// MARK: - WKScriptMessageHandler

extension ExtensionDialogViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "notification",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "submit":
            let data = body["data"] as? String ?? ""
            delegate?.dialogViewController(self, didPostMessage: data)
        case "close":
            delegate?.dialogViewControllerDidClose(self)
        default:
            AppLogDebug("[ExtDialog] Unknown message type: \(type)")
        }
    }
}

// MARK: - WKNavigationDelegate

extension ExtensionDialogViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard measureContentSize else { return }

        let js = """
        (function() {
            var body = document.body;
            var children = body.children;
            if (!children.length) return JSON.stringify({ width: 0, height: 0 });
            var cs = getComputedStyle(body);
            var pb = parseFloat(cs.paddingBottom) || 0;
            var pr = parseFloat(cs.paddingRight) || 0;
            var maxBottom = 0, maxRight = 0;
            for (var i = 0; i < children.length; i++) {
                var r = children[i].getBoundingClientRect();
                if (r.bottom > maxBottom) maxBottom = r.bottom;
                if (r.right > maxRight) maxRight = r.right;
            }
            return JSON.stringify({
                width: Math.ceil(maxRight + pr),
                height: Math.ceil(maxBottom + pb)
            });
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self,
                  error == nil,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let width = dict["width"],
                  let height = dict["height"] else { return }

            self.delegate?.dialogViewController(self, contentSizeMeasured: NSSize(width: width, height: height))
        }
    }
}

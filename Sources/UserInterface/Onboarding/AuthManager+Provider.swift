//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.
    

import Foundation
import Auth0
extension AuthManager {
    func makeExternalBrowserAuthProvider() -> WebAuthProvider {
        return { [weak self] authorizeURL, callback in
            let listenerRegistration: (@escaping (URL) -> Void) -> (() -> Void) = { listener in
                guard let self else { return {} }
                return self.registerBrowserAuthCallbackListener(listener)
            }

            return AuthManagerExternalBrowserWebAuthUserAgent(
                authorizeURL: authorizeURL,
                callback: callback,
                registerCallbackURLListener: listenerRegistration
            )
        }
    }

    func resumeExternalBrowserAuthentication(with url: URL) -> Bool {
        guard url.host == domain else {
            return false
        }
        let callback = browserAuthCallbackQueue.sync { pendingBrowserAuthCallback }
        guard let callback else {
            return false
        }
        callback(url)
        return true
    }

    func cancelOngoingWebAuthentication() {
        WebAuthentication.cancel()
        clearBrowserAuthCallbackListener()
    }

    func registerBrowserAuthCallbackListener(_ listener: @escaping (URL) -> Void) -> (() -> Void) {
        let token = UUID()
        browserAuthCallbackQueue.sync {
            pendingBrowserAuthCallbackToken = token
            pendingBrowserAuthCallback = listener
        }
        return { [weak self] in
            self?.clearBrowserAuthCallbackListener(for: token)
        }
    }

    func clearBrowserAuthCallbackListener(for token: UUID? = nil) {
        browserAuthCallbackQueue.sync {
            guard token == nil || token == pendingBrowserAuthCallbackToken else {
                return
            }
            pendingBrowserAuthCallbackToken = nil
            pendingBrowserAuthCallback = nil
        }
    }

}

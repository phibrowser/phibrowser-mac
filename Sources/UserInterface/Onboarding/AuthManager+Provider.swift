//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.
    

import Foundation
import Auth0
extension AuthManager {
    func makeExternalBrowserAuthProvider(
        accountDeletionReplacementLoginToken: UUID? = nil
    ) -> WebAuthProvider {
        return { [weak self] authorizeURL, callback in
            let listenerRegistration: (@escaping (URL) -> Void) -> (() -> Void) = { listener in
                guard let self else { return {} }
                return self.registerBrowserAuthCallbackListener(
                    listener,
                    accountDeletionReplacementLoginToken: accountDeletionReplacementLoginToken
                )
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
        let (callback, replacementLoginToken) = browserAuthCallbackQueue.sync {
            (
                pendingBrowserAuthCallback,
                pendingBrowserAuthCallbackReplacementLoginToken
            )
        }
        guard permitsExternalBrowserAuthentication(
            accountDeletionReplacementLoginToken: replacementLoginToken
        ) else {
            return false
        }
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

    func registerBrowserAuthCallbackListener(
        _ listener: @escaping (URL) -> Void,
        accountDeletionReplacementLoginToken: UUID? = nil
    ) -> (() -> Void) {
        guard permitsExternalBrowserAuthentication(
            accountDeletionReplacementLoginToken: accountDeletionReplacementLoginToken
        ) else {
            return {}
        }
        let token = UUID()
        browserAuthCallbackQueue.sync {
            pendingBrowserAuthCallbackToken = token
            pendingBrowserAuthCallback = listener
            pendingBrowserAuthCallbackReplacementLoginToken =
                accountDeletionReplacementLoginToken
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
            pendingBrowserAuthCallbackReplacementLoginToken = nil
        }
    }

}

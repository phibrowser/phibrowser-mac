// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class CommonMessageRouter {
    static let shared = CommonMessageRouter()
    private let messanger: ExtensionMessagingProtocol
    
    init(messanger: ExtensionMessagingProtocol = ExtensionMessaging.shared) {
        self.messanger = messanger
    }

    func handle(_ context: ExtensionMessageContext) -> String? {
        switch context.type {
        case "getAuth0Profile":
            handleAuth0ProfileRequest(context)
            return nil
        case "getWindowTheme":
            WindowThemeMessageRouter.shared.handleGetWindowTheme(context)
            return nil
        default:
            AppLogDebug("[CommonMessage] Unhandled message type: \(context.type)")
            return nil
        }
    }
    
    private func handleAuth0ProfileRequest(_ context: ExtensionMessageContext) {
        func _handleResponse(_ user: User?) {
            guard let user else {
                messanger.sendError("Retrive user info failed", requestId: context.requestId)
                return
            }
            
            let info = [
                "name": user.name ?? "",
                "email": user.email ?? "",
                "picture": user.picture ?? ""
            ]
            guard let data = try? JSONEncoder().encode(info),
                  let json = String(data: data, encoding: .utf8) else {
                messanger.sendError("Retrive user info failed", requestId: context.requestId)
                return
            }
            messanger.sendResponse(json, requestId: context.requestId)
        }
        Task {
            
            // Priority 1: Cached profile (includes user-modified name from Settings)
            if let userDefaults = AccountController.shared.account?.userDefaults,
               let profile: Profile = userDefaults.codableValue(forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue) {
                _handleResponse(.init(name: profile.name, email: profile.email, picture: profile.picture, sub: nil))
                return
            }

            // Priority 2: ID token claims (always available when logged in)
            await AuthManager.shared.refreshAuthStatus()
            guard let credentials = AuthManager.shared.currentCredentials else {
                _handleResponse(nil)
                return
            }
            let user = AuthManager.retriveUserInfo(from: credentials)
            _handleResponse(user)
        }
    }
    
}

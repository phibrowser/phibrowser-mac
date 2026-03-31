// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
struct DeeplinkHandler {
    static let nativeLinkPrefix = "phi://native"
    /// Returns whether the URL should be handled by native code.
    static func shouldHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme,
              let host = url.host else {
            return false
        }
        let prefix = "\(scheme)://\(host)".lowercased()
        return prefix == nativeLinkPrefix.lowercased()
    }
    
    @discardableResult
    static func handle(_ urlStr: String) -> Bool {
        guard let url = URL(string: urlStr) else {
            return false
        }
        return handle(url)
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard shouldHandle(url) else { return false }

        if isOpenPage(url) {
            return handleOpenPage(url)
        }
        
        return false
    }
}

extension DeeplinkHandler {
    enum Action {
        case openPage(PageRootParam? = nil)
        
        var path: String {
            switch self {
            case .openPage:
                return "/openpage"
            @unknown default:
                AppLogError("not supported action")
                return ""
            }
        }
    }
}

extension DeeplinkHandler {
    enum PageRootParam {
        case settings(SettingsPage?)
        
        static let key = "page"
    }
    enum SettingsPage: String {
        case account, general, aisetting, imchannels, shortcus
        
        static let key = "section"
    }
}

extension DeeplinkHandler {
    /// Returns whether the deeplink action is `openpage`.
    static func isOpenPage(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let path = components.path.lowercased()
        return path == Action.openPage().path
    }

    /// Opens a native page from a `phi://native/openpage?...` deeplink.
    static func handleOpenPage(_ url: URL) -> Bool {
        guard isOpenPage(url) else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let queryItems = components.queryItems ?? []
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }

        guard let pageName = params[PageRootParam.key]?.lowercased() else {
            return false
        }
        let sectionName = params[SettingsPage.key]?.lowercased()
        
        switch pageName {
        case "settings":
            var settingsPage: SettingsPage = .account
            if let sectionName = sectionName, let page = SettingsPage(rawValue: sectionName) {
                settingsPage = page
            }
            let pageParam = PageRootParam.settings(settingsPage)
            AppController.shared.handleOpenPage(pageParam)
            return true
        default:
            AppLogWarn("Unsupported page name: \(pageName)")
        }
        
        return false
    }
}

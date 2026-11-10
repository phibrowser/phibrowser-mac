// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Converts user-entered text into a browser URL string.
public struct URLProcessor {
    
    /// Converts user input into a valid URL string.
    public static func processUserInput(_ searchText: String) -> String {
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedText.hasPrefix("http://") || trimmedText.hasPrefix("https://") {
            return trimmedText
        } else if trimmedText.hasPrefix("chrome://") || trimmedText.hasPrefix("about://") {
            return trimmedText
        } else if trimmedText.hasPrefix("file://") || trimmedText.hasPrefix("chrome-extension://") {
            // Already complete URLs. Their file names contain a dot, so the
            // domain check below would otherwise prefix them with https://.
            return trimmedText
        } else if trimmedText.hasPrefix("phi://") {
            return trimmedText.replacingOccurrences(of: "phi://", with: "chrome://")
        } else if isURL(trimmedText) {
            return "https://\(trimmedText)"
        } else {
            return "https://www.google.com/search?q=\(trimmedText)"
        }
    }

    /// Compares URLs for bookmark and pinned-tab origin navigation.
    /// HTTP(S) `www.` variants and an optional root slash are equivalent;
    /// scheme, port, non-root path, query, and fragment differences remain significant.
    static func areEquivalentForOriginNavigation(_ lhs: String, _ rhs: String) -> Bool {
        guard let normalizedLHS = normalizedForOriginNavigation(lhs),
              let normalizedRHS = normalizedForOriginNavigation(rhs) else {
            return lhs == rhs
        }

        return normalizedLHS == normalizedRHS
    }
    
    /// Returns whether the text looks like a URL.
    public static func isURL(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedText.hasPrefix("http://") || 
           trimmedText.hasPrefix("https://") ||
           trimmedText.hasPrefix("chrome://") ||
           trimmedText.hasPrefix("about://") ||
           trimmedText.hasPrefix("file://") ||
           trimmedText.hasPrefix("chrome-extension://") ||
           trimmedText.hasPrefix("phi://") {
            return true
        }
        
        let domainPattern = #"^[^\s]+\.[^\s]+$"#
        let regex = try? NSRegularExpression(pattern: domainPattern)
        let range = NSRange(location: 0, length: trimmedText.utf16.count)
        return regex?.firstMatch(in: trimmedText, range: range) != nil
    }
    
    /// Extracts a display-friendly hostname from a URL.
    public static func displayName(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        
        if urlString.hasPrefix("chrome-extension:") {
            return ""
        }
        
        let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return displayHost
    }
    
    static func phiBrandEnsuredUrlString(_ string: String) -> String {
        guard string.hasPrefix("chrome://") else { return string }
        let startIndex = string.index(string.startIndex, offsetBy: "chrome://".count)
        return "phi://" + string[startIndex...]
    }

    private static func normalizedForOriginNavigation(_ rawURL: String) -> String? {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        components.scheme = scheme
        if let host = components.host?.lowercased() {
            let stripsWWW = (scheme == "http" || scheme == "https") &&
                host.hasPrefix("www.") && host.count > 4
            components.host = stripsWWW ? String(host.dropFirst(4)) : host
        }
        if components.path == "/" {
            components.path = ""
        }

        return components.string
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Kingfisher
#if canImport(SwiftUI)
import SwiftUI
#endif

struct FaviconConfiguration {
    /// Corner radius for the favicon image
    var cornerRadius: CGFloat = 4
    /// Fade transition duration in seconds
    var fadeTransition: TimeInterval = 0.2
    /// Whether to cache the original image
    var cacheOriginalImage: Bool = true
    /// Placeholder image when loading or on failure
    var placeholder: NSImage? = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

    static let `default` = FaviconConfiguration()

    static let noCornerRadius = FaviconConfiguration(cornerRadius: 0)

    /// Path prefixes for internal scheme URLs (`phi://` or `chrome://`) that should
    /// display the default Phi favicon instead of fetching a remote icon.
    static let defaultFaviconPathPrefixes: [String] = [
        "newtab",
        "conversation"
    ]

    /// Whether the URL is an internal page that should display the default Phi favicon.
    static func shouldUseDefaultFavicon(for url: URL) -> Bool {
        let str = url.absoluteString
        if str.isNTPUrlString { return true }

        let path: Substring
        if str.hasPrefix("phi://") {
            path = str.dropFirst("phi://".count)
        } else if str.hasPrefix("chrome://") {
            path = str.dropFirst("chrome://".count)
        } else {
            return false
        }

        return defaultFaviconPathPrefixes.contains { path.hasPrefix($0) }
    }
}

extension NSImageView {
    private func applyFaviconMask(cornerRadius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = max(0, cornerRadius)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }

    /// Sets favicon for the given URL string
    /// - Parameters:
    ///   - urlString: The page URL string to fetch favicon for
    ///   - configuration: Favicon loading configuration
    ///   - completion: Optional completion handler called with the result
    /// - Returns: DownloadTask that can be cancelled
    @discardableResult
    func setFavicon(
        for urlString: String?,
        configuration: FaviconConfiguration = .default,
        completion: ((Result<RetrieveImageResult, KingfisherError>) -> Void)? = nil
    ) -> DownloadTask? {
        applyFaviconMask(cornerRadius: configuration.cornerRadius)

        guard let urlString = urlString,
              let url = URL(string: urlString) else {
            image = configuration.placeholder
            return nil
        }
        return setFavicon(for: url, configuration: configuration, completion: completion)
    }

    /// Sets favicon for the given URL
    /// - Parameters:
    ///   - url: The page URL to fetch favicon for
    ///   - configuration: Favicon loading configuration
    ///   - completion: Optional completion handler called with the result
    /// - Returns: DownloadTask that can be cancelled
    @discardableResult
    func setFavicon(
        for url: URL,
        configuration: FaviconConfiguration = .default,
        completion: ((Result<RetrieveImageResult, KingfisherError>) -> Void)? = nil
    ) -> DownloadTask? {
        applyFaviconMask(cornerRadius: configuration.cornerRadius)

        if FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
            self.image = .phiDefaultFavicon
            return nil
        }
        
        let provider = FaviconDataProvider(pageURL: url)
        var options: KingfisherOptionsInfo = []

        if configuration.fadeTransition > 0 {
            options.append(.transition(.fade(configuration.fadeTransition)))
        }
        if configuration.cacheOriginalImage {
            options.append(.cacheOriginalImage)
        }

        return kf.setImage(
            with: provider,
            placeholder: configuration.placeholder,
            options: options
        ) { [weak self] result in
            switch result {
            case .failure:
                // When a previous task is cancelled due to cell reuse/rebind, avoid overriding
                // a newer successful image with placeholder.
                if self?.image == nil {
                    self?.image = configuration.placeholder
                }
            case .success:
                break
            }
            completion?(result)
        }
    }
}

#if canImport(SwiftUI)
extension Image {
    /// Creates a SwiftUI favicon view for the given URL string.
    static func favicon(
        for urlString: String?,
        configuration: FaviconConfiguration = .default
    ) -> some View {
        SwiftUIFaviconView(urlString: urlString, configuration: configuration)
    }
}

private struct SwiftUIFaviconView: View {
    let urlString: String?
    let configuration: FaviconConfiguration

    var body: some View {
        Group {
            if let urlString,
               let url = URL(string: urlString) {
                faviconView(for: url)
            } else {
                placeholderView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func faviconView(for url: URL) -> some View {
        if FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
            Image(nsImage: .phiDefaultFavicon)
                .resizable()
                .scaledToFit()
        } else {
            let provider = FaviconDataProvider(pageURL: url)

            if configuration.cacheOriginalImage {
                KFImage(source: .provider(provider))
                    .placeholder { placeholderView }
                    .cacheOriginalImage()
                    .fade(duration: configuration.fadeTransition)
                    .resizable()
                    .scaledToFit()
            } else {
                KFImage(source: .provider(provider))
                    .placeholder { placeholderView }
                    .fade(duration: configuration.fadeTransition)
                    .resizable()
                    .scaledToFit()
            }
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        if let placeholder = configuration.placeholder {
            Image(nsImage: placeholder)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}
#endif

// MARK: - Favicon Cache Utilities
extension FaviconDataProvider {
    struct FaviconCache {}
    
    static func setupCache() {
        FaviconCache.setupCache()
    }
    
    static func clearCache(for url: URL) {
        FaviconCache.clearCache(for: url)
    }
    
    static func clearCache(for url: URL) async {
        await FaviconCache.clearCache(for: url)
    }
}

extension FaviconDataProvider.FaviconCache {
    static func setupCache() {
        let diskCacheDir = (FileSystemUtils.cacheDirctory() as NSString).appendingPathComponent("KFImageCaches")
        try? FileManager.default.createDirectory(atPath: diskCacheDir, withIntermediateDirectories: true)
        guard let customCache = try? ImageCache(name: "PhiImageCache", cacheDirectoryURL: URL(filePath: diskCacheDir)) else {
            return
        }
        customCache.memoryStorage.config.cleanInterval = 60 * 60
        customCache.memoryStorage.config.countLimit = 10 * 1024 * 1024
        customCache.diskStorage.config.expiration = .days(5)
        KingfisherManager.shared.cache = customCache
    }
    /// Gets the cache key for a given URL
    static func cacheKey(for url: URL) -> String {
        return FaviconDataProvider(pageURL: url).cacheKey
    }

    /// Returns the cache key for a URL string.
    static func cacheKey(for urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return cacheKey(for: url)
    }

    /// Clears the cached favicon for one URL.
    static func clearCache(for url: URL) {
        let key = cacheKey(for: url)
        KingfisherManager.shared.cache.removeImage(forKey: key)
    }
    
    static func clearCache(for url: URL) async {
        let key = cacheKey(for: url)
        try? await KingfisherManager.shared.cache.removeImage(forKey: key)
    }

    /// Clears the entire favicon cache.
    static func clearAllCache() {
        KingfisherManager.shared.cache.clearCache()
    }
}

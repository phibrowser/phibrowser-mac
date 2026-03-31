// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Kingfisher
struct FaviconDataProvider: ImageDataProvider {
    let pageURL: URL
    
    var cacheKey: String {
        pageURL.host ?? pageURL.absoluteString
    }
    
    func data(handler: @escaping (Result<Data, Error>) -> Void) {
        if pageURL.absoluteString.starts(with: "chrome://newtab") ||
        pageURL.absoluteString.starts(with: "phi://newtab") ||
            pageURL.absoluteString.isNTPUrlString {
            if let data = NSImage(resource: .phiDefaultFavicon).pngData() {
                handler(.success(data))
                return
            }
        }
        ChromiumLauncher.sharedInstance().bridge?.getFaviconForURL(pageURL.absoluteString) { imageData in
            guard let data = imageData else {
                handler(.failure(NSError(domain: "FaviconProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "No favicon image"])))
                return
            }
            handler(.success(data))
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return data
    }
}

protocol ProfileScopedFaviconFetching: AnyObject {
    func getFavicon(profileId: String, pageURLString: String, completion: @escaping (Data?) -> Void)
}

struct ProfileScopedFaviconRequest {
    let profileId: String?
    let pageURLString: String?
    let snapshotData: Data?

    var cacheKey: String? {
        guard let profileId,
              !profileId.isEmpty,
              let pageURLString,
              !pageURLString.isEmpty else {
            return nil
        }
        return "\(profileId)|\(pageURLString)"
    }
}

enum ProfileScopedFaviconSource: Equatable {
    case snapshot
    case chromium
    case placeholder
}

struct ProfileScopedFaviconResult {
    let image: NSImage
    let data: Data?
    let source: ProfileScopedFaviconSource
}

final class ProfileScopedFaviconLoadHandle {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
final class ProfileScopedFaviconRepository {
    static let shared = ProfileScopedFaviconRepository(fetcher: ChromiumBridgeProfileScopedFaviconFetcher())

    private let fetcher: any ProfileScopedFaviconFetching
    private let memoryCache = NSCache<NSString, NSData>()

    init(fetcher: any ProfileScopedFaviconFetching) {
        self.fetcher = fetcher
    }

    @discardableResult
    func loadFavicon(
        for request: ProfileScopedFaviconRequest,
        completion: @escaping (ProfileScopedFaviconResult) -> Void
    ) -> ProfileScopedFaviconLoadHandle? {
        if let snapshotData = request.snapshotData,
           let snapshotImage = NSImage(data: snapshotData),
           request.pageURLString.flatMap(URL.init(string:)) == nil {
            completion(.init(image: snapshotImage, data: snapshotData, source: .snapshot))
            return nil
        }

        guard let url = request.pageURLString.flatMap(URL.init(string:)) else {
            completion(.init(image: Self.placeholderImage, data: nil, source: .placeholder))
            return nil
        }

        if FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
            let defaultImage = NSImage.phiDefaultFavicon
            completion(.init(image: defaultImage, data: defaultImage.pngData(), source: .placeholder))
            return nil
        }

        let handle = ProfileScopedFaviconLoadHandle()
        let initialData = request.snapshotData ?? cachedData(for: request)
        var lastDeliveredData = initialData

        if let initialData, let initialImage = NSImage(data: initialData) {
            store(initialData, for: request)
            completion(.init(image: initialImage, data: initialData, source: .snapshot))
        }

        guard let profileId = request.profileId, !profileId.isEmpty else {
            if initialData == nil {
                completion(.init(image: Self.placeholderImage, data: nil, source: .placeholder))
            }
            return handle
        }

        let pageURLString = url.absoluteString
        fetcher.getFavicon(profileId: profileId, pageURLString: pageURLString) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, !handle.isCancelled else { return }
                guard let data, let image = NSImage(data: data) else {
                    if lastDeliveredData == nil {
                        completion(.init(image: Self.placeholderImage, data: nil, source: .placeholder))
                    }
                    return
                }

                self.store(data, for: request)
                guard data != lastDeliveredData else { return }
                lastDeliveredData = data
                completion(.init(image: image, data: data, source: .chromium))
            }
        }

        return handle
    }

    private func cachedData(for request: ProfileScopedFaviconRequest) -> Data? {
        guard let cacheKey = request.cacheKey,
              let data = memoryCache.object(forKey: cacheKey as NSString) else {
            return nil
        }
        return Data(referencing: data)
    }

    private func store(_ data: Data, for request: ProfileScopedFaviconRequest) {
        guard let cacheKey = request.cacheKey else { return }
        memoryCache.setObject(data as NSData, forKey: cacheKey as NSString)
    }

    private static var placeholderImage: NSImage {
        NSImage(systemSymbolName: "globe", accessibilityDescription: "Website") ?? NSImage()
    }
}

@MainActor
private final class ChromiumBridgeProfileScopedFaviconFetcher: ProfileScopedFaviconFetching {
    func getFavicon(profileId: String, pageURLString: String, completion: @escaping (Data?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[FaviconRepository] bridge unavailable for \(pageURLString)")
            completion(nil)
            return
        }

        bridge.getFaviconForURL(pageURLString, profileId: profileId) { data in
            completion(data)
        }
    }
}

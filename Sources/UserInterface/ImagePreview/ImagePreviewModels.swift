// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

enum ImagePreviewSource: Equatable {
    case localFile(URL)
    case remoteURL(URL)
    case rawData(Data, mimeType: String?)

    var url: URL? {
        switch self {
        case .localFile(let url), .remoteURL(let url):
            return url
        case .rawData:
            return nil
        }
    }

    var cacheKey: String {
        switch self {
        case .localFile(let url):
            return "local:\(url.path)"
        case .remoteURL(let url):
            return "remote:\(url.absoluteString)"
        case .rawData(let data, let mimeType):
            let hash = data.hashValue
            return "rawdata:\(hash):\(mimeType ?? "unknown")"
        }
    }

    /// Resolves a plugin-supplied address string to a local file, remote HTTP(S) URL, or inline base64 data.
    static func resolved(from address: String) -> ImagePreviewSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parseDataURI(trimmed) {
            return .rawData(parsed.data, mimeType: parsed.mimeType)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath

        if let url = URL(string: expanded), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            if url.isFileURL || scheme == "file" {
                return .localFile(url.standardizedFileURL)
            }
            return .remoteURL(url)
        }

        if expanded.hasPrefix("/") {
            return .localFile(URL(fileURLWithPath: expanded).standardizedFileURL)
        }

        return .localFile(URL(fileURLWithPath: expanded).standardizedFileURL)
    }

    /// Parses `data:[<mediatype>][;base64],<data>` URIs and returns decoded bytes + MIME type.
    private static func parseDataURI(_ string: String) -> (data: Data, mimeType: String?)? {
        guard string.lowercased().hasPrefix("data:") else { return nil }
        let afterScheme = String(string.dropFirst(5))

        guard let commaIndex = afterScheme.firstIndex(of: ",") else { return nil }
        let meta = afterScheme[afterScheme.startIndex..<commaIndex]
        let payload = String(afterScheme[afterScheme.index(after: commaIndex)...])

        let parts = meta.split(separator: ";", omittingEmptySubsequences: false)
        let mimeType = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        let isBase64 = parts.contains(where: { $0.lowercased() == "base64" })

        guard isBase64, let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            return nil
        }

        return (decoded, mimeType)
    }
}

struct ImagePreviewItem: Equatable, Identifiable {
    let id: String
    let source: ImagePreviewSource
    let title: String?
    let mimeType: String?
    let suggestedFilename: String?

    static func items(fromAddressStrings addresses: [String]) -> [ImagePreviewItem] {
        addresses.enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ImagePreviewItem(
                id: "image-preview-\(index)",
                source: .resolved(from: trimmed),
                title: nil,
                mimeType: nil,
                suggestedFilename: nil
            )
        }
    }
}

enum ImagePreviewError: Error, Equatable {
    case invalidSource
    case networkFailed
    case unsupportedFormat
    case decodeFailed
    case fileNotFound

    var message: String {
        switch self {
        case .invalidSource:
            return NSLocalizedString("Invalid image source", comment: "Image preview error")
        case .networkFailed:
            return NSLocalizedString("Failed to load remote image", comment: "Image preview error")
        case .unsupportedFormat:
            return NSLocalizedString("Unsupported image format", comment: "Image preview error")
        case .decodeFailed:
            return NSLocalizedString("Failed to decode image", comment: "Image preview error")
        case .fileNotFound:
            return NSLocalizedString("Image file not found", comment: "Image preview error")
        }
    }
}

struct ImagePreviewAsset {
    let image: NSImage
    let pixelSize: CGSize
    let formatIdentifier: String
    let isAnimated: Bool
}

enum ImagePreviewLoadState {
    case idle
    case loading
    case loaded(ImagePreviewAsset)
    case failed(ImagePreviewError)
}

protocol ImagePreviewLoading {
    func load(_ item: ImagePreviewItem) async throws -> ImagePreviewAsset
    func preloadAdjacentItems(around items: [ImagePreviewItem], currentIndex: Int)
    func cancelCurrentLoad()
}

struct ImagePreviewBridgeRequest: Decodable {
    let windowId: Int
    let currentIndex: Int
    private let wireItems: [BridgeItemWire]

    var itemAddresses: [String] {
        wireItems.map(\.address)
    }

    enum CodingKeys: String, CodingKey {
        case windowId
        case currentIndex
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowId = try container.decode(Int.self, forKey: .windowId)
        currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        wireItems = try container.decode([BridgeItemWire].self, forKey: .items)
    }
}

/// Accepts either a plain string URL/path or the legacy object shape from older extensions.
private enum BridgeItemWire: Decodable {
    case string(String)
    case legacy(LegacyImagePreviewBridgeItem)

    var address: String {
        switch self {
        case .string(let s):
            return s
        case .legacy(let item):
            return item.resolvedAddress
        }
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let string = try? single.decode(String.self) {
            self = .string(string)
            return
        }
        self = .legacy(try LegacyImagePreviewBridgeItem(from: decoder))
    }
}

private struct LegacyImagePreviewBridgeItem: Decodable {
    let resolvedAddress: String

    private struct SourcePayload: Decodable {
        let type: String
        let url: String?
        let path: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case type
        case url
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let sourcePayload = try container.decodeIfPresent(SourcePayload.self, forKey: .source) {
            resolvedAddress = sourcePayload.url ?? sourcePayload.path ?? ""
        } else {
            _ = try container.decode(String.self, forKey: .type)
            resolvedAddress = try container.decodeIfPresent(String.self, forKey: .url)
                ?? container.decodeIfPresent(String.self, forKey: .path)
                ?? ""
        }
    }
}

enum ImagePreviewMessageHandler {
    static func handle(_ context: ExtensionMessageContext) {
        do {
            let request = try JSONDecoder().decode(ImagePreviewBridgeRequest.self, from: Data(context.payload.utf8))
            let items = ImagePreviewItem.items(fromAddressStrings: request.itemAddresses)

            guard let controller = MainBrowserWindowControllersManager.shared.controller(for: request.windowId) ?? MainBrowserWindowControllersManager.shared.activeWindowController
            else {
                AppLogWarn("[ImagePreview] Window not found for id: \(request.windowId)")
                return
            }

            Task { @MainActor in
                controller.browserState.imagePreviewState.open(items: items, currentIndex: request.currentIndex)
            }
        } catch {
            AppLogError("[ImagePreview] Failed to decode extension payload: \(error)\nRaw payload: \(context.payload.prefix(500))")
        }
    }
}

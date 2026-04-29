// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import ImageIO

class Extension: ObservableObject, Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let version: String
    @Published var isPinned: Bool
    let pinnedIndex: Int
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? ""
        self.name = dict["name"] as? String ?? ""
        self.version = dict["version"] as? String ?? ""
        self.isPinned = dict["isPinned"] as? Bool ?? false
        self.pinnedIndex = dict["pinnedIndex"] as? Int ?? -1
        
        if let iconBase64 = dict["icon"] as? String,
           let image = Self.imageFromBase64(iconBase64) {
            self.icon = image
        } else {
            self.icon = nil
        }
    }
    
    // Decodes a base64-encoded extension icon (PNG bytes from Chromium's
    // `extensions_proxy.cc`) and returns an `NSImage` pre-baked for the toolbar
    // / menu / list display sites only.
    //
    // Returned image carries bitmap representations at 14, 16, 18, 32 pt, each
    // rendered at 2x retina (28 / 32 / 36 / 64 px) using ImageIO high-quality
    // resampling. `NSImage.size` is 32 pt. Callers rendering at any of those
    // logical sizes get a 1:1 pixel draw with no further resampling; sizes in
    // between get a small downscale; sizes above 32 pt will upscale and look
    // soft.
    //
    // **Do not use this for larger renderings (e.g. extension detail / settings
    // pages at 48 pt+).** Either widen `displayPointSizes` here or decode the
    // raw `data:image/png;base64,...` payload separately at the call site.
    //
    // TODO: Move this into a shared image utility once extension icon handling stabilizes.
    static func imageFromBase64(_ base64String: String) -> NSImage? {
        // Strip optional `data:image/...;base64,` prefixes before decoding.
        let cleanBase64: String
        if let commaIndex = base64String.firstIndex(of: ",") {
            cleanBase64 = String(base64String[base64String.index(after: commaIndex)...])
        } else {
            cleanBase64 = base64String
        }

        guard let imageData = Data(base64Encoded: cleanBase64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return multiResolutionIcon(from: imageData) ?? NSImage(data: imageData)
    }

    // Display sites in pt: HeaderExtensionsView=14, WebContentAddressBarMenu=16,
    // HoverableButton(SideAddressBar)=16, ExtensionList=18. Pre-render one
    // high-quality bitmap rep per logical size at 2x retina pixel density so
    // NSImage's best-rep matching gives display sites a 1:1 pixel draw,
    // bypassing SwiftUI/AppKit default `.medium` interpolation on the hot path.
    // 32 pt is a backstop rep for any future site that renders larger than 18 pt.
    private static let displayPointSizes: [CGFloat] = [14, 16, 18, 32]
    private static let retinaScale: CGFloat = 2

    private static func multiResolutionIcon(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let image = NSImage()
        for pointSize in displayPointSizes {
            let pixelSize = Int((pointSize * retinaScale).rounded())
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else {
                continue
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = NSSize(width: pointSize, height: pointSize)
            image.addRepresentation(rep)
        }

        guard !image.representations.isEmpty else {
            return nil
        }
        // Match logical size to the largest rep so callers that don't constrain
        // frame fall back to the highest-quality bitmap.
        image.size = NSSize(
            width: displayPointSizes.last ?? 18,
            height: displayPointSizes.last ?? 18
        )
        return image
    }
}

extension Extension: Equatable {
    static func == (lhs: Extension, rhs: Extension) -> Bool {
        return lhs.name == rhs.name &&
        lhs.id == rhs.id &&
        lhs.pinnedIndex == rhs.pinnedIndex &&
        lhs.isPinned == rhs.isPinned
    }
}

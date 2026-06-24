// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Shared CGWindowList-based snapshot helper for GPU-rendered content (Chromium
/// web content). Local snapshot APIs (`cacheDisplay` /
/// `bitmapImageRepForCachingDisplay` / `CALayer.render(in:)`) return blank for
/// the remote layer; capturing the app's OWN window via `CGWindowListCreateImage`
/// is permission-free (Screen Recording permission only governs capturing OTHER
/// apps/screens).
///
/// Used by tab dragging (`.nominalResolution`) and active-tab close masking
/// (`.bestResolution`). Best-effort: returns nil on near-edge clipping, blank
/// capture, or missing window — callers degrade gracefully.
enum WebContentSnapshotter {
    /// Captures the on-screen pixels of `view`'s region from the window server.
    /// - Parameter resolution: `.nominalResolution` (drag) or `.bestResolution` (close).
    /// - Returns: the captured image, or nil if capture failed / looked clipped / blank.
    static func captureOnScreen(_ view: NSView, resolution: CGWindowImageOption, insetBy inset: CGFloat = 0) -> NSImage? {
        guard let window = view.window else { return nil }

        // Optional inset, e.g. to exclude an ancestor-drawn outline from the capture.
        let captureBounds = view.bounds.insetBy(dx: inset, dy: inset)
        guard captureBounds.width > 0, captureBounds.height > 0 else { return nil }

        // Convert capture bounds to window coordinates, then to screen coordinates.
        let viewFrameInWindow = view.convert(captureBounds, to: nil)
        let viewFrameInScreen = window.convertToScreen(viewFrameInWindow)

        // CGWindowListCreateImage uses top-left origin coordinate system.
        // Convert from bottom-left (Cocoa) to top-left (CG) using global desktop maxY.
        let desktopMaxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? viewFrameInScreen.maxY
        let cgRect = CGRect(
            x: viewFrameInScreen.origin.x,
            y: desktopMaxY - viewFrameInScreen.origin.y - viewFrameInScreen.height,
            width: viewFrameInScreen.width,
            height: viewFrameInScreen.height
        )

        // Capture only the specific window to avoid capturing overlapping windows.
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            cgRect,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, resolution]
        ) else { return nil }

        // When source window is near/off screen edges, WindowServer may return a clipped region.
        // Using a clipped snapshot looks visually broken (one side cut off), so fallback instead.
        if isWindowServerCaptureLikelyClipped(
            cgImage,
            viewFrameInScreen: viewFrameInScreen,
            expectedAspect: boundsAspectRatio(of: view)
        ) {
            return nil
        }

        // Validate the captured image is not blank (check if it has non-transparent pixels).
        if isImageBlank(cgImage) {
            return nil
        }

        return NSImage(cgImage: cgImage, size: captureBounds.size)
    }

    private static func boundsAspectRatio(of view: NSView) -> CGFloat {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return bounds.width / bounds.height
    }

    private static func isWindowServerCaptureLikelyClipped(
        _ image: CGImage,
        viewFrameInScreen: NSRect,
        expectedAspect: CGFloat
    ) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }
        guard viewFrameInScreen.width > 1, viewFrameInScreen.height > 1 else { return true }

        let scaleX = CGFloat(image.width) / viewFrameInScreen.width
        let scaleY = CGFloat(image.height) / viewFrameInScreen.height
        let normalizedScaleDelta = abs(scaleX - scaleY) / max(scaleX, scaleY)
        if normalizedScaleDelta > 0.12 {
            return true
        }

        guard expectedAspect > 0 else { return false }
        let capturedAspect = CGFloat(image.width) / CGFloat(image.height)
        let normalizedAspectDelta = abs(capturedAspect - expectedAspect) / expectedAspect
        return normalizedAspectDelta > 0.12
    }

    /// Checks if a CGImage is effectively blank (sampled pixels are all transparent).
    /// This intentionally avoids treating white/solid-color pages as blank.
    static func isImageBlank(_ image: CGImage) -> Bool {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return true
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard width > 0, height > 0, bytesPerRow > 0 else { return true }

        let length = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data), length > 0 else { return true }

        guard let alphaOffset = alphaOffset(for: image.alphaInfo, bytesPerPixel: bytesPerPixel) else {
            // If we cannot reliably locate alpha, only consider it blank when all sampled bytes are zero.
            let sampleStride = max(1, length / 128)
            for i in stride(from: 0, to: length, by: sampleStride) {
                if ptr[i] != 0 {
                    return false
                }
            }
            return true
        }

        let sampleXCount = min(8, width)
        let sampleYCount = min(8, height)
        for sy in 0..<sampleYCount {
            let y = sampleYCount == 1 ? 0 : (sy * (height - 1)) / (sampleYCount - 1)
            for sx in 0..<sampleXCount {
                let x = sampleXCount == 1 ? 0 : (sx * (width - 1)) / (sampleXCount - 1)
                let pixelStart = y * bytesPerRow + x * bytesPerPixel
                let alphaIndex = pixelStart + alphaOffset
                if alphaIndex >= 0, alphaIndex < length, ptr[alphaIndex] > 0 {
                    return false
                }
            }
        }

        return true
    }

    private static func alphaOffset(for alphaInfo: CGImageAlphaInfo, bytesPerPixel: Int) -> Int? {
        switch alphaInfo {
        case .first, .premultipliedFirst, .last, .premultipliedLast:
            break
        default:
            return nil
        }

        switch alphaInfo {
        case .first, .premultipliedFirst:
            return 0
        case .last, .premultipliedLast:
            return max(0, bytesPerPixel - 1)
        default:
            return nil
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import ImageIO

/// The last look of each Space's sidebar band — the content-only image
/// `SpaceSwitchBandSurface.snapshotSpaceSwitchBand()` renders — kept in
/// memory and on disk, per appearance.
///
/// It exists for the cold Space switch. A dormant Space's list holds only
/// what the Swift side knows ahead of its Browser (pinned tabs, bookmarks,
/// group headers); its normal tabs arrive when Chromium materializes the
/// parked window, ~100 ms after the click, so the band would slide in with
/// its rows missing and have them pop in near the end. The switch shows
/// this snapshot in the entering band instead, until the live rows exist.
///
/// Captured whenever a Space leaves the screen (the leaving side of a
/// switch, the visible Space at shell close and at quit) and dropped when
/// the Space is deleted. Stale by construction — it is what the band looked
/// like the last time it was shown — which for a parked Space is also
/// exactly right, since nothing changes a parked window.
///
/// Never for an Incognito Space: its band carries tab titles, and the file
/// would outlive the private session. `capture` refuses such ids, and the
/// first use of the cache deletes any file an older build wrote for one.
///
/// Scoped to the account whose local data is on screen, on disk under its
/// data directory: Space ids repeat across accounts (the default Space is
/// `default-space` in every one), and one account's tab titles must never
/// stand in for another's band. Deleting the account's directory takes its
/// bands with it.
final class SpaceBandSnapshotCache {
    static let shared = SpaceBandSnapshotCache()

    struct Snapshot {
        let pixels: CGImage
        let size: NSSize
    }

    private var snapshots: [String: Snapshot] = [:]
    private let queue = DispatchQueue(label: "com.phibrowser.spaceBandSnapshots", qos: .utility)
    private static let directoryName = "SpaceBandSnapshots"
    private var createdDirectories: Set<String> = []
    /// Tests pin the account instead of depending on the host's login state.
    var accountForTesting: Account?

    private init() {
        purgeLegacySharedDirectory()
    }

    /// The current account's cache scope: its id (the memory key prefix) and
    /// its on-disk directory. nil while no account's data is available.
    private func scope() -> (accountId: String, directory: URL)? {
        guard let account = accountForTesting ?? AccountController.shared.localDataAccount else { return nil }
        let url = account.userDataStorage
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        if createdDirectories.insert(url.path).inserted {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (account.userID, url)
    }

    /// Appearance half of the key: a light snapshot over a dark backdrop
    /// (or the reverse) would show the wrong text colors.
    static func appearanceKey(for view: NSView) -> String {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    /// Snapshots `surface`'s band for `spaceId` now (main thread; the
    /// render is a few milliseconds) and writes it to disk off the main
    /// thread.
    func capture(_ surface: any SpaceSwitchBandSurface, spaceId: String) {
        guard !SpaceManager.isIncognitoSpaceId(spaceId), let scope = scope() else { return }
        guard let image = surface.snapshotSpaceSwitchBand(), Self.hasVisibleContent(image) else { return }
        let key = Self.key(spaceId, Self.appearanceKey(for: surface.view))
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let size = image.size
        snapshots[Self.memoryKey(scope.accountId, key)] = Snapshot(pixels: pixels, size: size)
        let url = Self.fileURL(key, in: scope.directory)
        queue.async {
            // Encode immutable pixels away from AppKit's event thread. The
            // old TIFF-to-PNG conversion ran between consecutive clicks.
            autoreleasepool {
                guard let png = Self.pngData(pixels: pixels, logicalSize: size) else { return }
                try? png.write(to: url, options: .atomic)
            }
        }
    }

    static func pngData(pixels: CGImage, logicalSize: NSSize) -> Data? {
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        // Preserve point dimensions when the PNG is loaded on a Retina
        // display; raw pixel dimensions would double the stand-in's size.
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: CGFloat(pixels.width) / logicalSize.width * 72,
            kCGImagePropertyDPIHeight: CGFloat(pixels.height) / logicalSize.height * 72
        ]
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The cached band for `spaceId` in `view`'s appearance, from memory or
    /// disk (a small PNG, read synchronously; callers ask when they can
    /// afford it — a dormant session's warm-up — and again at the switch).
    func image(for spaceId: String, appearanceOf view: NSView) -> NSImage? {
        guard let snapshot = snapshot(for: spaceId, appearanceOf: view) else { return nil }
        return NSImage(cgImage: snapshot.pixels, size: snapshot.size)
    }

    func snapshot(for spaceId: String, appearanceOf view: NSView) -> Snapshot? {
        guard let scope = scope() else { return nil }
        let key = Self.key(spaceId, Self.appearanceKey(for: view))
        let memoryKey = Self.memoryKey(scope.accountId, key)
        if let snapshot = snapshots[memoryKey] { return snapshot }
        guard let source = CGImageSourceCreateWithURL(Self.fileURL(key, in: scope.directory) as CFURL, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpiX = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiY = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        let size = NSSize(width: Double(pixels.width) * 72 / max(1, dpiX),
                          height: Double(pixels.height) * 72 / max(1, dpiY))
        guard Self.hasVisibleContent(NSImage(cgImage: pixels, size: size)) else { return nil }
        let snapshot = Snapshot(pixels: pixels, size: size)
        snapshots[memoryKey] = snapshot
        return snapshot
    }

    /// A band captured while its live rows were suppressed is transparent.
    /// It must never replace a cold Space's available native controls.
    private static func hasVisibleContent(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        }
    }

    /// Loads `spaceId`'s snapshots into memory ahead of a switch.
    func prefetch(spaceId: String, appearanceOf view: NSView) {
        _ = snapshot(for: spaceId, appearanceOf: view)
    }

    /// The Space is gone; so is its band.
    func remove(spaceId: String) {
        guard let scope = scope() else { return }
        for appearance in ["light", "dark"] {
            let key = Self.key(spaceId, appearance)
            snapshots.removeValue(forKey: Self.memoryKey(scope.accountId, key))
            let url = Self.fileURL(key, in: scope.directory)
            queue.async {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Deletes the app-wide directory older builds wrote every account's
    /// bands into (Incognito ones included), which no account can claim.
    private func purgeLegacySharedDirectory() {
        let legacy = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory())
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        queue.async {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func key(_ spaceId: String, _ appearance: String) -> String {
        "\(spaceId)-\(appearance)"
    }

    private static func memoryKey(_ accountId: String, _ key: String) -> String {
        "\(accountId)/\(key)"
    }

    private static func fileURL(_ key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("png")
    }
}

/// A layer-hosted image with no AppKit image drawing pass on the click path.
/// Preserve the cached point size and top-left alignment when the panel resizes.
final class SpaceBandSnapshotView: NSView {
    init(snapshot: SpaceBandSnapshotCache.Snapshot, frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        let image = CALayer()
        image.contents = snapshot.pixels
        image.frame = CGRect(origin: CGPoint(x: 0, y: frame.height - snapshot.size.height),
                             size: snapshot.size)
        image.contentsGravity = .resize
        image.contentsScale = CGFloat(snapshot.pixels.width) / snapshot.size.width
        root.addSublayer(image)
        layer = root
        wantsLayer = true
        // AppKit initializes view-layer clipping when the layer is installed.
        root.frame = bounds
        root.masksToBounds = true
        autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

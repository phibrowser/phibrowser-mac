// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import CoreGraphics
import Foundation
import Kingfisher
/// Tracks a single in-flight tab dragging interaction within a BrowserState.
///
/// This is intentionally NOT a singleton. Each `BrowserState` owns one instance so state never leaks
/// across windows/profiles/incognito contexts.
@MainActor
final class TabDraggingSession {
    /// Static size for tab page snapshot drag image.
    static let tabSnapshotSize = NSSize(width: 220, height: 160)
    static let tabSnapshotCornerRadius: CGFloat = 12
    enum Phase: Equatable {
        case idle
        case dragging
    }

    struct Snapshot {
        var phase: Phase
        /// Opaque dragging item chosen by caller (e.g. `Tab`, `Bookmark`, pasteboard payload, etc).
        /// This intentionally uses `Any?` so different sources can store different types.
        var draggingItem: Any?
        /// Last known cursor location in screen coordinates (CoreGraphics screen space).
        var screenLocation: CGPoint?
        var updatedAt: Date

        var isDragging: Bool { phase == .dragging }
    }

    enum Event {
        case began(Snapshot)
        case moved(Snapshot)
        case ended(Snapshot)
        case cancelled(Snapshot)
        case itemChanged(Snapshot)
    }

    @Published private(set) var snapshot: Snapshot
    var isDraggingPublisher: AnyPublisher<Bool, Never> {
        $snapshot.map(\.isDragging).removeDuplicates().eraseToAnyPublisher()
    }

    private let eventsSubject = PassthroughSubject<Event, Never>()
    var events: AnyPublisher<Event, Never> { eventsSubject.eraseToAnyPublisher() }

    /// Native AppKit dragging session for the current drag, if available (owned by AppKit).
    /// We keep it weak to avoid extending its lifetime.
    private(set) weak var nativeSession: NSDraggingSession?

    /// The window that initiated the drag (fallback for boundary checks when no explicit container is provided).
    private var sourceWindow: NSWindow? { state?.windowController?.window }
    private(set) weak var state: BrowserState?
    private weak var dragBoundaryContainerView: NSView?
    private var lastIsInsideDragBoundary: Bool?
    
    /// Strongly held reference to the current dragging item.
    /// This ensures the item is not deallocated during the drag session.
    private(set) var currentDraggingItem: Any?

    /// Drag image mode for Tab drags.
    private enum TabDragImageMode {
        case original
        case pageSnapshot
    }
    private var tabDragImageMode: TabDragImageMode = .original

    /// Cached original providers/frames so we can restore them after swapping to snapshot.
    private typealias DragImageComponentsProvider = (() -> [NSDraggingImageComponent])
    private var cachedOriginalDraggingItems: [(frame: NSRect, provider: DragImageComponentsProvider?)]?
    /// Cached page snapshot image (generated when leaving the window).
    private var cachedTabSnapshotImage: NSImage?
    /// Cached original drag image provided by source (e.g. snapshot of tab cell).
    /// This is the only reliable way to restore the "previous" drag image because AppKit's default drag image
    /// is not guaranteed to be reconstructible after we override it with `setDraggingFrame(..., contents:)`.
    private var cachedOriginalDragImage: NSImage?
    
    private struct PendingTearOffWindowPlacement {
        let dropScreenLocation: CGPoint
        let sourceWindowNumber: Int?
        let requestedAt: Date
    }
    private static let tearOffPlacementTimeout: TimeInterval = 4.0
    private var pendingTearOffWindowPlacement: PendingTearOffWindowPlacement?
    private var mainWindowCreatedObserver: NSObjectProtocol?

    // MARK: - Drag image switching predicate
    
    /// Custom predicate to determine if drag image switching should be enabled for a given item.
    /// If not set, defaults to checking if the item is a `SidebarItem`.
    var shouldSwitchDragImageHandler: ((_ draggingItem: Any) -> Bool)?
    
    /// Determines whether the drag image switching logic should be applied for the given item.
    /// - Parameter item: The dragging item to check.
    /// - Returns: `true` if drag image should switch when leaving/entering window, `false` otherwise.
    func shouldSwitchDragImage(for item: Any) -> Bool {
        if let handler = shouldSwitchDragImageHandler {
            return handler(item)
        }
        guard let item  = item as? SidebarItem else {
            return false
        }
        return item.shouldTrackDraggingImage()
    }

    #if DEBUG
    private var lastMoveLogAt: Date?
    private var lastMoveLogLocation: CGPoint?
    #endif
    
    init(state: BrowserState) {
        self.snapshot = Snapshot(phase: .idle, draggingItem: nil, screenLocation: nil, updatedAt: Date())
        self.state = state
        registerMainWindowCreatedObserver()
    }
    
    deinit {
        if let mainWindowCreatedObserver {
            NotificationCenter.default.removeObserver(mainWindowCreatedObserver)
        }
    }

    func attachNativeSession(_ session: NSDraggingSession) {
        self.nativeSession = session
        // Immediately try to capture the original drag image from the native session.
        // This is more reliable than waiting until the first image switch.
        captureOriginalDragImageFromNativeSessionIfNeeded()
    }
    
    /// Attempts to capture the original drag image from the native session immediately after attach.
    /// This ensures we have the original image before any modifications occur.
    private func captureOriginalDragImageFromNativeSessionIfNeeded() {
        guard cachedOriginalDragImage == nil else { return }
        guard let session = nativeSession else { return }
        
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { [weak self] draggingItem, _, stop in
            guard let self else { return }
            if self.cachedOriginalDragImage != nil {
                stop.pointee = true
                return
            }
            
            if let provider = draggingItem.imageComponentsProvider {
                let components = provider()
                if let extractedImage = self.extractImageFromComponents(components) {
                    self.cachedOriginalDragImage = extractedImage
                    #if DEBUG
                    self.debugLogTabImageModeChange("early-extracted original image size=\(String(format: "%.0fx%.0f", extractedImage.size.width, extractedImage.size.height))")
                    #endif
                    stop.pointee = true
                }
            }
        }
    }

    func detachNativeSession() {
        self.nativeSession = nil
    }

    /// Provide the original drag image (typically captured by the source view/controller at drag begin).
    func setOriginalDragImage(_ image: NSImage?) {
        cachedOriginalDragImage = image
        #if DEBUG
        if let image {
            debugLogTabImageModeChange("setOriginalDragImage size=\(String(format: "%.0fx%.0f", image.size.width, image.size.height))")
        } else {
            debugLogTabImageModeChange("setOriginalDragImage nil")
        }
        #endif
    }

    /// Convenience for performing AppKit operations on the current native dragging session (e.g. updating drag image).
    func withNativeSession(_ body: (NSDraggingSession) -> Void) {
        guard let session = nativeSession else { return }
        body(session)
    }

    func begin(draggingItem: Any?, screenLocation: CGPoint?, containerView: NSView? = nil) {
        snapshot.phase = .dragging
        snapshot.draggingItem = draggingItem
        snapshot.screenLocation = screenLocation
        snapshot.updatedAt = Date()
        currentDraggingItem = draggingItem
        dragBoundaryContainerView = containerView
        eventsSubject.send(.began(snapshot))
        debugLog(event: "began", snapshot: snapshot)

        lastIsInsideDragBoundary = nil
        tabDragImageMode = .original
        cachedOriginalDraggingItems = nil
        cachedTabSnapshotImage = nil
        pendingTearOffWindowPlacement = nil
        // NOTE: Do not clear cachedOriginalDragImage here because sources may call `setOriginalDragImage`
        // before `begin(...)`. We clear it on end/cancel instead to avoid stale reuse across sessions.
    }

    /// Updates the ongoing dragging session. If the session wasn't started yet, this will start it implicitly.
    func update(draggingItem: Any? = nil, screenLocation: CGPoint?, containerView: NSView? = nil) {
        let hadItem = snapshot.draggingItem != nil
        if snapshot.phase != .dragging {
            begin(draggingItem: draggingItem, screenLocation: screenLocation, containerView: containerView)
            return
        }

        if let draggingItem {
            snapshot.draggingItem = draggingItem
            currentDraggingItem = draggingItem
        } else if currentDraggingItem == nil {
            currentDraggingItem = snapshot.draggingItem
        }
        if let containerView {
            dragBoundaryContainerView = containerView
        }
        snapshot.screenLocation = screenLocation
        snapshot.updatedAt = Date()

        // Emit a specific signal if the drag item becomes known/changes mid-drag (common for external drags).
        if !hadItem, snapshot.draggingItem != nil {
            eventsSubject.send(.itemChanged(snapshot))
            debugLog(event: "itemChanged", snapshot: snapshot)
        }

        eventsSubject.send(.moved(snapshot))
        debugLogMoveIfNeeded(snapshot: snapshot)
        
        // Tab drag image switching:
        // - Show page snapshot only when cursor leaves source container and is not inside any other browser window.
        // - Restore original drag image when cursor is inside source container OR any other browser window.
        guard let draggingItem = snapshot.draggingItem else { return }
        guard let screenLocation else { return }
        let isInside = !shouldUsePageSnapshotPreview(for: screenLocation)
        if lastIsInsideDragBoundary != isInside {
            lastIsInsideDragBoundary = isInside
            if shouldSwitchDragImage(for: draggingItem),
               nativeSession != nil,
               let sidebarItem = draggingItem as? SidebarItem {
                if isInside {
                    // Re-enable return animation when cursor comes back inside boundary.
                    nativeSession?.animatesToStartingPositionsOnCancelOrFail = true
                    restoreOriginalDragImageIfNeeded()
                } else {
                    // Disable return animation when cursor leaves boundary (for tear-off to new window).
                    nativeSession?.animatesToStartingPositionsOnCancelOrFail = false
                    switchToTabSnapshotDragImageIfNeeded(item: sidebarItem, screenLocation: screenLocation)
                }
            }
        } else if tabDragImageMode == .pageSnapshot, nativeSession != nil {
            // Keep snapshot drag image following the cursor (frame only).
            updateSnapshotDragFrame(screenLocation: screenLocation)
        }
    }

    func end(screenLocation: CGPoint? = nil, dragOperation: NSDragOperation? = nil) {
        guard snapshot.phase == .dragging else { return }
        snapshot.screenLocation = screenLocation ?? snapshot.screenLocation
        let didPerformDrop = dragOperation.map { !$0.isEmpty } ?? false
        handleDraggingSessionEndOutOfBoundary(snapshot.draggingItem, didPerformDrop: didPerformDrop)
        snapshot.updatedAt = Date()
        eventsSubject.send(.ended(snapshot))
        debugLog(event: "ended", snapshot: snapshot)
        resetDraggingState()
    }

    func cancel(screenLocation: CGPoint? = nil) {
        guard snapshot.phase == .dragging else { return }
        snapshot.screenLocation = screenLocation ?? snapshot.screenLocation
        snapshot.updatedAt = Date()
        eventsSubject.send(.cancelled(snapshot))
        debugLog(event: "cancelled", snapshot: snapshot)
        resetDraggingState()
    }
    
    /// Resets all dragging state after end or cancel.
    private func resetDraggingState() {
        snapshot.phase = .idle
        snapshot.draggingItem = nil
        snapshot.screenLocation = nil
        snapshot.updatedAt = Date()
        detachNativeSession()
        lastIsInsideDragBoundary = nil
        dragBoundaryContainerView = nil
        currentDraggingItem = nil
        tabDragImageMode = .original
        cachedOriginalDraggingItems = nil
        cachedTabSnapshotImage = nil
        cachedOriginalDragImage = nil
    }
    
    private func handleDraggingSessionEndOutOfBoundary(_ item: Any?, didPerformDrop: Bool) {
        if didPerformDrop {
            return
        }
        guard let web = item as? WebContentRepresentable,
              lastIsInsideDragBoundary == false,
              let item = snapshot.draggingItem,
              shouldSwitchDragImage(for: item) else {
            return
        }
        
        if let webContentWrapper = web.webContentWrapper {
            recordPendingTearOffWindowPlacement(screenLocation: snapshot.screenLocation)
            webContentWrapper.updateTabCustomValue("")
            webContentWrapper.moveSelf(toNewWindow: true)
        } else {
//            ChromiumLauncher.sharedInstance().bridge?.openURL(inNewWindow: web.url ?? "")
        }
        
    }

    func shouldUsePageSnapshotPreview(at screenLocation: CGPoint?) -> Bool {
        guard let screenLocation else { return false }
        return shouldUsePageSnapshotPreview(for: screenLocation)
    }

    private func shouldUsePageSnapshotPreview(for screenLocation: CGPoint) -> Bool {
        if dragBoundaryContainerView != nil {
            return !isInsideContainerBoundary(screenLocation) && !isInsideAnyOtherBrowserTabDragBoundary(screenLocation)
        }
        return !isInsideAnyBrowserWindow(screenLocation)
    }

    private func isInsideContainerBoundary(_ screenLocation: CGPoint) -> Bool {
        guard let container = dragBoundaryContainerView,
              let window = container.window else {
            return false
        }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenLocation.x, y: screenLocation.y))
        let pointInContainer = container.convert(pointInWindow, from: nil)
        return container.bounds.contains(pointInContainer)
    }

    private func isInsideAnyBrowserWindow(_ screenLocation: CGPoint) -> Bool {
        let point = NSPoint(x: screenLocation.x, y: screenLocation.y)
        let windows = MainBrowserWindowControllersManager.shared.getAllWindows()
        if !windows.isEmpty {
            return windows.contains { $0.window?.frame.contains(point) == true }
        }
        return sourceWindow?.frame.contains(point) == true
    }

    private func isInsideAnyOtherBrowserTabDragBoundary(_ screenLocation: CGPoint) -> Bool {
        let point = NSPoint(x: screenLocation.x, y: screenLocation.y)
        let sourceWindowNumber = sourceWindow?.windowNumber
        let windows = MainBrowserWindowControllersManager.shared.getAllWindows()
        if !windows.isEmpty {
            return windows.contains { controller in
                guard let window = controller.window else { return false }
                if let sourceWindowNumber, window.windowNumber == sourceWindowNumber {
                    return false
                }
                return window.frame.contains(point) && controller.containsTabDragBoundary(at: screenLocation)
            }
        }
        return false
    }
    
    private func registerMainWindowCreatedObserver() {
        mainWindowCreatedObserver = NotificationCenter.default.addObserver(
            forName: .mainBrowserWindowCreated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMainBrowserWindowCreated(notification)
        }
    }
    
    private func recordPendingTearOffWindowPlacement(screenLocation: CGPoint?) {
        guard let screenLocation else { return }
        pendingTearOffWindowPlacement = PendingTearOffWindowPlacement(
            dropScreenLocation: screenLocation,
            sourceWindowNumber: sourceWindow?.windowNumber,
            requestedAt: Date()
        )
    }
    
    private func handleMainBrowserWindowCreated(_ notification: Notification) {
        guard let request = pendingTearOffWindowPlacement else { return }
        guard Date().timeIntervalSince(request.requestedAt) <= Self.tearOffPlacementTimeout else {
            pendingTearOffWindowPlacement = nil
            return
        }
        guard let createdWindow = notification.object as? NSWindow else {
            return
        }
        if let sourceWindowNumber = request.sourceWindowNumber,
           createdWindow.windowNumber == sourceWindowNumber {
            return
        }
        guard let targetFrame = resolvedTearOffWindowFrame(
            for: createdWindow,
            dropScreenLocation: request.dropScreenLocation
        ) else {
            pendingTearOffWindowPlacement = nil
            return
        }
        
        createdWindow.setFrame(targetFrame, display: true)
        pendingTearOffWindowPlacement = nil
    }
    
    private func resolvedTearOffWindowFrame(for window: NSWindow, dropScreenLocation: CGPoint) -> NSRect? {
        guard let targetScreen = targetScreen(for: dropScreenLocation) else { return nil }
        let bounds = targetScreen.visibleFrame
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        
        let windowSize = window.frame.size
        let rx = normalizedRatio(dropScreenLocation.x, min: bounds.minX, max: bounds.maxX)
        let ry = normalizedRatio(dropScreenLocation.y, min: bounds.minY, max: bounds.maxY)
        
        let rawOriginX = dropScreenLocation.x - rx * windowSize.width
        let rawOriginY = dropScreenLocation.y - ry * windowSize.height
        
        let minOriginX = bounds.minX
        let maxOriginX = max(bounds.minX, bounds.maxX - windowSize.width)
        let minOriginY = bounds.minY
        let maxOriginY = max(bounds.minY, bounds.maxY - windowSize.height)
        
        let clampedX = min(max(rawOriginX, minOriginX), maxOriginX)
        let clampedY = min(max(rawOriginY, minOriginY), maxOriginY)
        
        return NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: windowSize)
    }
    
    private func targetScreen(for screenLocation: CGPoint) -> NSScreen? {
        let point = NSPoint(x: screenLocation.x, y: screenLocation.y)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        
        if let containing = screens.first(where: { $0.frame.contains(point) }) {
            return containing
        }
        
        return screens.min { lhs, rhs in
            distanceSquared(from: point, to: lhs.frame) < distanceSquared(from: point, to: rhs.frame)
        }
    }
    
    private func normalizedRatio(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let span = max - min
        guard span > 0 else { return 0.5 }
        return Swift.min(1, Swift.max(0, (value - min) / span))
    }
    
    private func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        
        return dx * dx + dy * dy
    }
}

// MARK: - Drag image switching (Tab)
extension TabDraggingSession {
    private func enumerateDraggingItems(_ body: (NSDraggingItem) -> Void) -> Int {
        var count = 0
        withNativeSession { session in
            session.enumerateDraggingItems(
                options: [],
                for: nil,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { draggingItem, _, _ in
                count += 1
                body(draggingItem)
            }
        }
        return count
    }

    private func captureOriginalDraggingItemsIfNeeded() {
        guard cachedOriginalDraggingItems == nil else { return }
        withNativeSession { session in
            var captured: [(NSRect, DragImageComponentsProvider?)] = []
            session.enumerateDraggingItems(
                options: [],
                for: nil,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { draggingItem, _, _ in
                captured.append((draggingItem.draggingFrame, draggingItem.imageComponentsProvider))
            }
            self.cachedOriginalDraggingItems = captured.isEmpty ? nil : captured
            debugLogTabImageModeChange("captureOriginal count=\(captured.count)")
        }
    }
    
    /// Attempts to extract an NSImage from drag image components.
    /// Combines multiple components into a single image if needed.
    private func extractImageFromComponents(_ components: [NSDraggingImageComponent]) -> NSImage? {
        guard !components.isEmpty else { return nil }
        
        // Single component case: directly extract the image.
        if components.count == 1, let first = components.first {
            return first.contents as? NSImage
        }
        
        // Multiple components: composite them into a single image.
        // Calculate bounding box that contains all component frames.
        var unionFrame = components[0].frame
        for component in components.dropFirst() {
            unionFrame = unionFrame.union(component.frame)
        }
        
        guard unionFrame.width > 0, unionFrame.height > 0 else { return nil }
        
        let compositeImage = NSImage(size: unionFrame.size)
        compositeImage.lockFocus()
        defer { compositeImage.unlockFocus() }
        
        for component in components {
            guard let image = component.contents as? NSImage else { continue }
            // Translate component frame relative to the union origin.
            let drawRect = NSRect(
                x: component.frame.origin.x - unionFrame.origin.x,
                y: component.frame.origin.y - unionFrame.origin.y,
                width: component.frame.width,
                height: component.frame.height
            )
            image.draw(in: drawRect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        }
        
        return compositeImage
    }

    private func restoreOriginalDragImageIfNeeded() {
        guard tabDragImageMode != .original else { return }
        captureOriginalDraggingItemsIfNeeded()
        guard let cached = cachedOriginalDraggingItems else { return }

        // Prefer restoring using the cached original image (provided by source). This is reliable.
        if let originalImage = cachedOriginalDragImage, let first = cached.first {
            let count = enumerateDraggingItems { draggingItem in
                draggingItem.imageComponentsProvider = nil
                draggingItem.setDraggingFrame(first.frame, contents: originalImage)
            }
            tabDragImageMode = .original
            cachedTabSnapshotImage = nil
            debugLogTabImageModeChange("restoreOriginal(image) items=\(count)")
            return
        }

        // Fallback: restore provider/frame (may not restore AppKit default image if provider was nil).
        withNativeSession { session in
            var idx = 0
            session.enumerateDraggingItems(
                options: [],
                for: nil,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { draggingItem, _, _ in
                if idx < cached.count {
                    let entry = cached[idx]
                    if let provider = entry.provider {
                        draggingItem.imageComponentsProvider = provider
                    } else {
                        draggingItem.imageComponentsProvider = nil
                    }
                    draggingItem.setDraggingFrame(entry.frame, contents: nil)
                }
                idx += 1
            }
        }

        tabDragImageMode = .original
        cachedTabSnapshotImage = nil
        debugLogTabImageModeChange("restoreOriginal(provider) count=\(cached.count)")
    }

    private func switchToTabSnapshotDragImageIfNeeded(item: SidebarItem, screenLocation: CGPoint) {
        guard nativeSession != nil else { return }
        guard tabDragImageMode != .pageSnapshot else { return }
        captureOriginalDraggingItemsIfNeeded()

        if cachedTabSnapshotImage == nil {
            cachedTabSnapshotImage = resolveOutsideWindowDragImage(for: item)
        }

        guard let snapshotImage = cachedTabSnapshotImage else { return }
        let targetFrame = snapshotDragFrame(around: screenLocation, size: snapshotImage.size)

        let count = enumerateDraggingItems { draggingItem in
            // Force replacement by setting contents directly.
            draggingItem.imageComponentsProvider = nil
            draggingItem.setDraggingFrame(targetFrame, contents: snapshotImage)
        }

        tabDragImageMode = .pageSnapshot
        debugLogTabImageModeChange("switchToSnapshot items=\(count)")
    }

    private func updateSnapshotDragFrame(screenLocation: CGPoint) {
        guard let image = cachedTabSnapshotImage else { return }
        let frame = snapshotDragFrame(around: screenLocation, size: image.size)
        _ = enumerateDraggingItems { draggingItem in
            draggingItem.setDraggingFrame(frame, contents: image)
        }
    }

    /// Resolve the drag image to use when the cursor is outside the source window.
    private func resolveOutsideWindowDragImage(for item: SidebarItem) -> NSImage? {
        if let tab = item as? Tab {
            return makeTabSnapshotImage(tab) ?? makeTabPlaceholderImage(url: tab.url, title: tab.title)
        } else if let bookmark = item as? Bookmark,
                  !bookmark.isFolder,
                  bookmark.isActive,
                  let nativeView = bookmark.webContentWrapper?.nativeView
        {
            return makeTabSnapshotImage(nativeView)
                ?? makeTabPlaceholderImage(url: bookmark.url, title: bookmark.title)
        }
        return makeTabPlaceholderImage(url: item.url, title: item.title)
    }

    func pageSnapshotImage(for item: SidebarItem) -> NSImage? {
        resolveOutsideWindowDragImage(for: item)
    }

    private func snapshotDragFrame(around screenLocation: CGPoint, size: NSSize) -> NSRect {
        // Put the snapshot slightly above the cursor so it doesn't fully cover drop targets.
        let origin = NSPoint(
            x: screenLocation.x - size.width * 0.5,
            y: screenLocation.y - size.height * 0.25
        )
        return NSRect(origin: origin, size: size)
    }

    private func makeTabSnapshotImage(_ tab: Tab) -> NSImage? {
        if tab.isActive, let view = tab.webContentView,
           let live = makeTabSnapshotImage(view) {
            // Active tab: prefer live view capture (most up-to-date).
            return live
        }
        // Inactive tab, or active tab whose live capture failed:
        // use Chromium's cached thumbnail.
        return requestChromiumThumbnail(for: tab)
    }

    /// Returns Chromium's cached JPEG thumbnail as a rounded snapshot image, or nil.
    private func requestChromiumThumbnail(for tab: Tab) -> NSImage? {
        guard let jpegData = ChromiumLauncher.sharedInstance().bridge?.thumbnail(forTab: Int64(tab.guid)),
              let image = NSImage(data: jpegData) else {
            return nil
        }
        return image.drawnAsRoundedSnapshot(
            targetSize: Self.tabSnapshotSize,
            cornerRadius: Self.tabSnapshotCornerRadius
        )
    }
    
    private func makeTabSnapshotImage(_ webContentView: NSView) -> NSImage? {
        snapshotImage(
            of: webContentView,
            targetSize: Self.tabSnapshotSize,
            cornerRadius: Self.tabSnapshotCornerRadius
        )
    }

    private func makeTabPlaceholderImage(url: String?, title: String) -> NSImage {
        let fallbackFavicon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website") ?? NSImage()
        let favicon: NSImage
        if let urlString = url {
            favicon = cachedFavicon(for: urlString) ?? fallbackFavicon
        } else {
            favicon = fallbackFavicon
        }
        return Self.makeTabPlaceholderSnapshot(favicon: favicon, title: title)
    }

    private func cachedFavicon(for urlStr: String) -> NSImage? {
        guard let url = URL(string: urlStr) else {
            return nil
        }
        let key = FaviconDataProvider(pageURL: url).cacheKey
        return KingfisherManager.shared.cache.retrieveImageInMemoryCache(forKey: key)
    }

    /// Create a placeholder snapshot image using favicon + title.
    /// - Parameters:
    ///   - favicon: Favicon image to render (will be scaled to a fixed size).
    ///   - title: Title text; centered and limited to at most 2 lines (truncated with ellipsis if needed).
    static func makeTabPlaceholderSnapshot(favicon: NSImage, title: String) -> NSImage {
        let canvasSize = Self.tabSnapshotSize
        let cornerRadius = Self.tabSnapshotCornerRadius

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let canvasRect = NSRect(origin: .zero, size: canvasSize)
        let clipPath = NSBezierPath(roundedRect: canvasRect, xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()

        // Background (subtle, so it looks like a card).
        let bg = NSColor.controlBackgroundColor.withAlphaComponent(0.98)
        bg.setFill()
        canvasRect.fill()

        // Border
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        clipPath.lineWidth = 1
        clipPath.stroke()

        // Layout constants
        let horizontalInset: CGFloat = 12
        let iconSize = NSSize(width: 28, height: 28)
        let iconToTitleSpacing: CGFloat = 10

        // Text setup
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        let maxLines = 2
        let lineHeight = ceil(font.ascender - font.descender) + 3
        let maxTextHeight = lineHeight * CGFloat(maxLines)
        let maxTextWidth = canvasSize.width - horizontalInset * 2
        let maxTextSize = NSSize(width: maxTextWidth, height: maxTextHeight)

        func measuredHeight(for text: String) -> CGFloat {
            let str = NSAttributedString(string: text, attributes: attrs)
            let rect = str.boundingRect(with: maxTextSize, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(rect.height)
        }

        func truncateToFitTwoLines(_ text: String) -> String {
            if measuredHeight(for: text) <= maxTextSize.height { return text }
            let ellipsis = "…"
            var low = 0
            var high = text.count
            var best = ellipsis

            while low <= high {
                let mid = (low + high) / 2
                let prefix = String(text.prefix(mid)).trimmingCharacters(in: .whitespacesAndNewlines)
                let candidate = prefix.isEmpty ? ellipsis : (prefix + ellipsis)
                if measuredHeight(for: candidate) <= maxTextSize.height {
                    best = candidate
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return best
        }

        // Measure title height
        let finalTitle = truncateToFitTwoLines(title)
        let titleString = NSAttributedString(string: finalTitle, attributes: attrs)
        let titleMeasuredRect = titleString.boundingRect(with: maxTextSize, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let titleHeight = ceil(titleMeasuredRect.height)

        // Calculate total content height (icon + spacing + title) and center vertically
        let totalContentHeight = iconSize.height + iconToTitleSpacing + titleHeight
        let contentTopY = (canvasSize.height + totalContentHeight) * 0.5

        // Draw icon (centered horizontally, positioned from content top)
        let iconOrigin = NSPoint(
            x: (canvasSize.width - iconSize.width) * 0.5,
            y: contentTopY - iconSize.height
        )
        let iconRect = NSRect(origin: iconOrigin, size: iconSize)
        favicon.draw(
            in: iconRect,
            from: NSRect(origin: .zero, size: favicon.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // Draw title (centered horizontally, fixed spacing below icon)
        let titleDrawRect = NSRect(
            x: horizontalInset,
            y: iconRect.minY - iconToTitleSpacing - titleHeight,
            width: maxTextWidth,
            height: titleHeight
        )
        titleString.draw(with: titleDrawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        return image
    }

    private func snapshotImage(of view: NSView, targetSize: NSSize, cornerRadius: CGFloat) -> NSImage? {
        // Ensure we have a non-zero size to snapshot.
        let bounds = view.bounds
        guard bounds.width > 2, bounds.height > 2 else { return nil }

        // For GPU-rendered views (e.g., Chromium web content), use CGWindowListCreateImage.
        // On macOS 26+, traditional methods like `bitmapImageRepForCachingDisplay`/`cacheDisplay`
        // and `CALayer.render(in:)` may return blank for GPU-accelerated views.
        if let image = snapshotImageUsingWindowServer(view: view) {
            return image.drawnAsRoundedSnapshot(targetSize: targetSize, cornerRadius: cornerRadius)
        }
        
        // Fallback: try layer-based rendering.
        if view.wantsLayer, let layer = view.layer {
            if let image = snapshotImageFromLayer(layer, bounds: bounds) {
                return image.drawnAsRoundedSnapshot(targetSize: targetSize, cornerRadius: cornerRadius)
            }
        }

        // Last resort: traditional view-based snapshot for non-layer views.
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        return image.drawnAsRoundedSnapshot(targetSize: targetSize, cornerRadius: cornerRadius)
    }
    
    /// Captures a snapshot using CGWindowListCreateImage, which works for GPU-rendered content.
    /// This method captures the actual on-screen pixels of the view's region.
    private func snapshotImageUsingWindowServer(view: NSView) -> NSImage? {
        guard let window = view.window else { return nil }
        
        // Convert view bounds to window coordinates, then to screen coordinates.
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
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
            [.boundsIgnoreFraming, .nominalResolution]
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
        
        return NSImage(cgImage: cgImage, size: view.bounds.size)
    }
    
    private func boundsAspectRatio(of view: NSView) -> CGFloat {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return bounds.width / bounds.height
    }
    
    private func isWindowServerCaptureLikelyClipped(
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
    private func isImageBlank(_ image: CGImage) -> Bool {
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
    
    private func alphaOffset(for alphaInfo: CGImageAlphaInfo, bytesPerPixel: Int) -> Int? {
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
    
    /// Captures a snapshot of the given CALayer by rendering it into a bitmap context.
    private func snapshotImageFromLayer(_ layer: CALayer, bounds: NSRect) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        
        guard width > 0, height > 0 else { return nil }
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        
        guard let cgImage = context.makeImage() else { return nil }
        
        // Check if the layer render produced a blank image.
        if isImageBlank(cgImage) {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: bounds.size)
    }
}

private extension NSImage {
    func drawnAsRoundedSnapshot(targetSize: NSSize, cornerRadius: CGFloat) -> NSImage {
        guard size.width > 0, size.height > 0, targetSize.width > 0, targetSize.height > 0 else { return self }

        // Aspect-fill into target size, then clip to rounded rect.
        let scale = max(targetSize.width / size.width, targetSize.height / size.height)
        let scaledSize = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(
            x: (targetSize.width - scaledSize.width) * 0.5,
            y: (targetSize.height - scaledSize.height) * 0.5
        )
        let destRect = NSRect(origin: origin, size: scaledSize)

        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: targetSize)).fill()

        let clipPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: targetSize), xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()

        draw(in: destRect, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        return newImage
    }
}

extension TabDraggingSession {
    #if DEBUG
    private func debugLogTabImageModeChange(_ action: String) {
        AppLogDebug("[TabDraggingSession] tabDragImage \(action)")
    }
    #else
    private func debugLogTabImageModeChange(_ action: String) {}
    #endif
}

// MARK: - Debug logging
extension TabDraggingSession {
    #if DEBUG
    private func debugLog(event: String, snapshot: Snapshot) {
        AppLogDebug("[TabDraggingSession] \(event) phase=\(snapshot.phase) item=\(format(item: snapshot.draggingItem)) screen=\(format(point: snapshot.screenLocation))")
    }
    
    private func debugLogMoveIfNeeded(snapshot: Snapshot) {
        // Avoid spamming logs; only log "move" when the cursor moved enough or after a short interval.
        let now = snapshot.updatedAt
        let minInterval: TimeInterval = 0.25
        let minDistance: CGFloat = 24
        
        if let lastAt = lastMoveLogAt, now.timeIntervalSince(lastAt) < minInterval {
            if let lastLoc = lastMoveLogLocation, let loc = snapshot.screenLocation {
                let dx = loc.x - lastLoc.x
                let dy = loc.y - lastLoc.y
                if (dx * dx + dy * dy) < (minDistance * minDistance) {
                    return
                }
            } else {
                // No location info to compare; don't spam.
                return
            }
        }
        
        lastMoveLogAt = now
        lastMoveLogLocation = snapshot.screenLocation
        AppLogDebug("[TabDraggingSession] moved item=\(format(item: snapshot.draggingItem)) screen=\(format(point: snapshot.screenLocation))")
    }
    
    private func format(item: Any?) -> String {
        guard let item else { return "nil" }
        return String(describing: type(of: item))
    }

    private func format(point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.1f, %.1f)", point.x, point.y)
    }
    #else
    private func debugLog(event: String, snapshot: Snapshot) {}
    private func debugLogMoveIfNeeded(snapshot: Snapshot) {}
    #endif
}

extension SidebarItem {
    func shouldTrackDraggingImage() -> Bool {
        if self is Tab {
            return true
        }
        if let bookmark = self as? Bookmark {
            return !bookmark.isFolder
        }
        return false
    }
}

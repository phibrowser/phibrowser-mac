// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Keeps a Space instance's content surface (chromium ADR 0014) told the
/// corner radii, stacking order, rect and visible part of every web view in
/// its hosting container, as views tells `NativeViewHostMac` upstream.
///
/// It reconciles once per run-loop pass, as `TrafficLightPositioner` does
/// with the traffic lights. Mounting a web view, restacking a tab's view, a
/// layout pass, docking DevTools and opening the AI Chat panel can each
/// change what the surface has to be told, an animation that moves only a
/// web view's ancestors (the AI Chat panel's slide) changes it every frame,
/// and a web view the surface attaches again starts out square and on top;
/// mounted controllers supply candidate pages through `contentSurfaceTabs`,
/// alongside the placeholder wrapper. Each pass checks their actual ancestry
/// and geometry. New mounting paths must expose their pages as candidates,
/// including pages still mounted while a model change awaits view teardown.
/// A pass with nothing new sends nothing, since each send makes Chromium
/// draw a frame.
@MainActor
final class ContentSurfaceHosting {
    /// What one web view's host is told: the radii of its four on-screen
    /// corners, its stacking order among the web views of the container,
    /// where it is and the part of it that shows.
    struct Hosting: Equatable {
        var topLeft: CGFloat = 0
        var topRight: CGFloat = 0
        var bottomRight: CGFloat = 0
        var bottomLeft: CGFloat = 0
        var zOrder = 0
        /// The web view's rect in the window, flipped to a top-left origin by
        /// the window's height, as Chromium keeps a view's bounds in its window.
        var frame: CGRect = .zero
        /// The part of `frame` its clipping ancestors leave visible, in the
        /// same coordinates; empty when none is.
        var clip: CGRect = .zero
    }

    private struct Sent {
        weak var address: NSObject?
        var hosting: Hosting
    }

    private weak var container: NSView?
    /// The surface's view: in `container`, or in the overlay of a page
    /// lifted into content fullscreen (`update`).
    private weak var surfaceView: NSView?
    private weak var browserState: BrowserState?
    private let hostedTabs: () -> [Tab]
    private var observer: CFRunLoopObserver?
    /// Last `Hosting` sent, keyed by address.
    private var sent: [ObjectIdentifier: Sent] = [:]
    /// The surface's view's superview when `sent` was recorded. When the
    /// view moves (lent to a page in content fullscreen, reclaimed),
    /// Chromium settles every web view below its new superview, and one
    /// that was off the surface gets a new host item, square and on top.
    /// One mounted while the view was away is such a view, and Chromium
    /// ignored what it was told meanwhile; so `sent` no longer holds.
    private weak var sentUnder: NSView?
    /// Set while the page container holds the surface's view at its frame
    /// from before an extension side panel slides in
    /// (`WebContentContainerViewController`), so the surface keeps room for
    /// a page that narrows with its card on every frame. Passes go on
    /// meanwhile (`clippingRect(of:)`).
    var isHeld = false
    /// Whether the framework takes a web view's rect and visible part
    /// (`setContentHosting(_:frameInWindow:…)`). An older one takes only the
    /// radii and the z order, so only those are compared and sent: a move
    /// sends it nothing. Asked once, on the first pass with a bridge; tests
    /// set it.
    var takesPlacement: Bool?
    /// Replaces the bridge sends in tests.
    var sendForTesting: ((_ address: NSObject, _ hosting: Hosting) -> Void)?

    /// After AppKit's flush observer, so the views are laid out.
    private static let observerOrder = CFIndex.max

    init(container: NSView, surfaceView: NSView, browserState: BrowserState?,
         hostedTabs: @escaping () -> [Tab]) {
        self.container = container
        self.surfaceView = surfaceView
        self.browserState = browserState
        self.hostedTabs = hostedTabs
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true,
            Self.observerOrder
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
        self.observer = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    deinit {
        if let observer {
            CFRunLoopObserverInvalidate(observer)
        }
    }

    /// The stacking order is the web views' back-to-front order below the
    /// container, so docked DevTools, mounted below its page, stays below it.
    /// Only the current tab's views are mounted there, so the web views of
    /// two tabs never overlap. A page lifted into content fullscreen takes
    /// the surface's view with it into an overlay over the window
    /// (`WebContentViewController.applyContentFullscreenState`): its web
    /// views are enumerated below that overlay, above every web view left in
    /// the container, and with no rounded ancestor up there they go square.
    private func update() {
        guard let container, let browserState,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              let window = container.window,
              !container.isHiddenOrHasHiddenAncestor else {
            // A web view attached again meanwhile has lost what it was told.
            sent.removeAll()
            return
        }
        if takesPlacement == nil {
            // Its twin addressed by web view came with it.
            takesPlacement = bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setContentHosting(
                _:frameInWindow:clipInWindow:topLeftRadius:topRightRadius:bottomRightRadius:bottomLeftRadius:zOrder:)))
        }
        let sendsPlacement = takesPlacement == true
        if surfaceView?.superview !== sentUnder {
            sent.removeAll()
            sentUnder = surfaceView?.superview
        }
        // Controllers supply the pages they host, including split panes and
        // embedded chat. Reading every background wrapper's nativeView here
        // makes each run-loop pass scale with the entire Space's tab count.
        let tabs = hostedTabs()
        var wrappers = tabs.compactMap(\.webContentWrapper)
        if let placeholder = browserState.placeholderWrapper {
            wrappers.append(placeholder)
        }
        // A web view is addressed by its wrapper. Docked DevTools has none and
        // is addressed by its web view, the view Chromium handed over.
        var addresses = wrappers.map { (address: $0 as NSObject, webView: $0.nativeView) }
        addresses += tabs.compactMap(\.devToolsView)
            .map { (address: $0 as NSObject, webView: Optional($0)) }
        var seen = Set<ObjectIdentifier>()
        addresses = addresses.filter { seen.insert(ObjectIdentifier($0.address)).inserted }
        var roots = [container]
        if let overlay = surfaceView?.superview, overlay !== container {
            roots.append(overlay)
        }
        let mounted = roots.flatMap { root in
            addresses
                .compactMap { item -> (address: NSObject, webView: NSView, root: NSView, path: [Int])? in
                    guard let webView = item.webView, webView.window === window,
                          let path = Self.indexPath(of: webView, below: root) else { return nil }
                    return (item.address, webView, root, path)
                }
                .sorted { $0.path.lexicographicallyPrecedes($1.path) }
        }

        var nowSent: [ObjectIdentifier: Sent] = [:]
        for (zOrder, item) in mounted.enumerated() {
            var hosting = Self.hosting(of: item.webView, zOrder: zOrder, below: item.root,
                                       windowHeight: window.frame.height)
            if !sendsPlacement {
                hosting.frame = .zero
                hosting.clip = .zero
            }
            let key = ObjectIdentifier(item.address)
            if sent[key]?.address !== item.address || sent[key]?.hosting != hosting {
                if let sendForTesting {
                    sendForTesting(item.address, hosting)
                } else if let wrapper = item.address as? WebContentWrapper {
                    if sendsPlacement {
                        bridge.setContentHosting?(wrapper,
                                                  frameInWindow: hosting.frame,
                                                  clipInWindow: hosting.clip,
                                                  topLeftRadius: hosting.topLeft,
                                                  topRightRadius: hosting.topRight,
                                                  bottomRightRadius: hosting.bottomRight,
                                                  bottomLeftRadius: hosting.bottomLeft,
                                                  zOrder: hosting.zOrder)
                    } else {
                        bridge.setContentHosting?(wrapper,
                                                  topLeftRadius: hosting.topLeft,
                                                  topRightRadius: hosting.topRight,
                                                  bottomRightRadius: hosting.bottomRight,
                                                  bottomLeftRadius: hosting.bottomLeft,
                                                  zOrder: hosting.zOrder)
                    }
                } else if sendsPlacement {
                    bridge.setContentHosting?(forWebView: item.webView,
                                              frameInWindow: hosting.frame,
                                              clipInWindow: hosting.clip,
                                              topLeftRadius: hosting.topLeft,
                                              topRightRadius: hosting.topRight,
                                              bottomRightRadius: hosting.bottomRight,
                                              bottomLeftRadius: hosting.bottomLeft,
                                              zOrder: hosting.zOrder)
                } else {
                    bridge.setContentHosting?(forWebView: item.webView,
                                              topLeftRadius: hosting.topLeft,
                                              topRightRadius: hosting.topRight,
                                              bottomRightRadius: hosting.bottomRight,
                                              bottomLeftRadius: hosting.bottomLeft,
                                              zOrder: hosting.zOrder)
                }
            }
            nowSent[key] = Sent(address: item.address, hosting: hosting)
        }
        sent = nowSent
    }

    /// Subview indices from `container` down to `view`, or nil when `view` is
    /// not below it. Ordered lexicographically, these give the back-to-front
    /// order in which AppKit draws the views.
    private static func indexPath(of view: NSView, below container: NSView) -> [Int]? {
        var path: [Int] = []
        var child = view
        while let parent = child.superview {
            guard let index = parent.subviews.firstIndex(of: child) else { return nil }
            path.append(index)
            if parent === container {
                return path.reversed()
            }
            child = parent
        }
        return nil
    }

    /// Where `webView` is in the window and the part of it that its clipping
    /// ancestors below `container`, and `container`, whose bounds the surface
    /// draws in, leave visible (`clippingRect(of:)`). Also the radii AppKit
    /// gives that part's corners: at each corner, the largest corner radius
    /// among those ancestors whose own corner it reaches. The surface rounds
    /// that part, not the whole web view (cc rounds a layer's bounds cut to
    /// its clip rect), so a page overrunning its host keeps the host's
    /// corners. A corner that reaches none stays square: one next to docked
    /// DevTools, the top of a page under the address bar.
    private static func hosting(of webView: NSView, zOrder: Int, below container: NSView,
                                windowHeight: CGFloat) -> Hosting {
        var hosting = Hosting(zOrder: zOrder)
        let frame = webView.convert(webView.bounds, to: nil)
        var visible = frame.intersection(clippingRect(of: container))
        var clips: [(view: NSView, rect: CGRect)] = []
        var ancestor = webView.superview
        while let clip = ancestor, clip !== container {
            ancestor = clip.superview
            guard clip.layer?.masksToBounds == true else {
                continue
            }
            let clipping = clippingRect(of: clip)
            visible = visible.intersection(clipping)
            clips.append((clip, clipping))
        }
        for (clip, clipping) in clips where !visible.isEmpty {
            guard let layer = clip.layer, layer.cornerRadius > 0 else {
                continue
            }
            let rect = clip.convert(visible, from: nil)
            let bounds = clip.convert(clipping, from: nil)
            let atMinX = abs(rect.minX - bounds.minX) < 0.5
            let atMaxX = abs(rect.maxX - bounds.maxX) < 0.5
            let atMinY = abs(rect.minY - bounds.minY) < 0.5
            let atMaxY = abs(rect.maxY - bounds.maxY) < 0.5
            func radius(_ reaches: Bool, _ corner: CACornerMask) -> CGFloat {
                reaches && layer.maskedCorners.contains(corner) ? layer.cornerRadius : 0
            }
            let minXMinY = radius(atMinX && atMinY, .layerMinXMinYCorner)
            let maxXMinY = radius(atMaxX && atMinY, .layerMaxXMinYCorner)
            let minXMaxY = radius(atMinX && atMaxY, .layerMinXMaxYCorner)
            let maxXMaxY = radius(atMaxX && atMaxY, .layerMaxXMaxYCorner)
            // A layer's corners follow its view's coordinates (AppKit flips a
            // flipped view's layer), so minY is the top only when flipped.
            let flipped = clip.isFlipped
            hosting.topLeft = max(hosting.topLeft, flipped ? minXMinY : minXMaxY)
            hosting.topRight = max(hosting.topRight, flipped ? maxXMinY : maxXMaxY)
            hosting.bottomLeft = max(hosting.bottomLeft, flipped ? minXMaxY : minXMinY)
            hosting.bottomRight = max(hosting.bottomRight, flipped ? maxXMaxY : maxXMinY)
        }
        // As -[RenderWidgetHostViewCocoa sendViewBoundsInWindowToHost] reports
        // a view's bounds: window coordinates flipped by the window's height.
        func fromTop(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: windowHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        hosting.frame = fromTop(frame)
        hosting.clip = visible.isEmpty ? .zero : fromTop(visible)
        return hosting
    }

    /// The rect in the window that `view` clips a page to. The extension
    /// side panel slides by Core Animation: the views around the page take
    /// their end frame at once and only their layers move, while the page's
    /// card follows the page / AI Chat split frame by frame, laid out for
    /// the next display (a frame ahead of the layers' presented state). On
    /// screen the card stays inside them, so mid-slide such a view clips to
    /// the wider of its frame and its layer's presented width, leaving the
    /// card to bound the page. The slide moves no left edge and changes no
    /// height.
    private static func clippingRect(of view: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: nil)
        if let layer = view.layer, layer.animationKeys() != nil,
           let presented = layer.presentation() {
            rect.size.width += max(0, presented.bounds.width - layer.bounds.width)
        }
        return rect
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import ImageIO

/// The page area of an agent Space running on the user's other Mac: its
/// latest frame under the same control pill a local agent Space wears. While
/// the agent drives, the pill's overlay swallows input exactly as it does
/// locally; once this Mac holds control, pointer and key events go to the
/// host as page input.
final class AgentRemoteMirrorView: NSView {
    let target: AgentRemoteMirrorTarget
    private let imageLayer = CALayer()
    private let overlay = AgentSpaceOverlayView()
    private var cssSize: CGSize = .zero
    private var ownedByUser = false
    private var heldButton: String?
    private var cancellables = Set<AnyCancellable>()

    init(target: AgentRemoteMirrorTarget) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        addSubview(overlay)

        let presence = AgentRemotePresence.shared
        overlay.onTakeControl = { presence.send(.takeControl(spaceId: target.spaceId), to: target.peerId) }
        overlay.onHandBack = { presence.send(.handBack(spaceId: target.spaceId), to: target.peerId) }
        overlay.onFinish = { presence.send(.finish(spaceId: target.spaceId), to: target.peerId) }

        presence.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPill() }
            .store(in: &cancellables)
        presence.frames
            .filter { $0.peerId == target.peerId && $0.frame.spaceId == target.spaceId }
            .sink { [weak self] in self?.show($0.frame) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageLayer.frame = pageRect
        overlay.frame = bounds
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard imageLayer.contents == nil else { return }
        layer?.backgroundColor = ThemedColor.extensionSurfaceBackground.resolve(in: self).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// The agent cursor takes its colors from the window's theme, as it does
    /// over a local agent Space.
    func applyTheme(_ theme: Theme, appearance: Appearance) {
        overlay.applyTheme(theme, appearance: appearance)
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
    }

    private func refreshPill() {
        let presence = AgentRemotePresence.shared
        guard let task = presence.task(for: target) else { return }
        // Input goes out only while this Mac is the one holding control.
        ownedByUser = task.ownedByUser && task.remoteController == presence.deviceName
        var display = task.displayTask
        // "Controlled from <this Mac>" is news for the host, not for here.
        if display.remoteController == presence.deviceName { display.remoteController = nil }
        overlay.update(with: display, deviceName: presence.peers[target.peerId]?.deviceName)
    }

    private func show(_ frame: AgentRemoteFrame) {
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if cssSize != frame.cssSize {
            cssSize = frame.cssSize
            needsLayout = true
        }
        imageLayer.contents = image
        // The host's agent window rarely has this card's proportions; the
        // strip it leaves takes the page's own bottom edge color.
        if let edge = Self.bottomEdgeColor(of: image) { layer?.backgroundColor = edge }
        overlay.moveCursor(to: frame.cursor.flatMap(viewPoint(forPage:)))
    }

    private static func bottomEdgeColor(of image: CGImage) -> CGColor? {
        guard let pixel = image.cropping(to: CGRect(x: 0, y: image.height - 1, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return CGColor(srgbRed: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                       blue: CGFloat(data[2]) / 255, alpha: 1)
    }

    // MARK: - Coordinates

    /// Where the frame is drawn: aspect-fit and pinned to the top, the way
    /// a page sits in its card.
    private var pageRect: CGRect {
        guard cssSize.width > 0, cssSize.height > 0 else { return .zero }
        let scale = min(bounds.width / cssSize.width, bounds.height / cssSize.height)
        let size = CGSize(width: cssSize.width * scale, height: cssSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func viewPoint(forPage point: CGPoint) -> CGPoint? {
        let rect = pageRect
        guard rect.width > 0 else { return nil }
        return CGPoint(x: rect.minX + point.x / cssSize.width * rect.width,
                       y: rect.maxY - point.y / cssSize.height * rect.height)
    }

    private func pagePoint(for event: NSEvent) -> CGPoint? {
        let rect = pageRect
        let point = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * cssSize.width,
                       y: (rect.maxY - point.y) / rect.height * cssSize.height)
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    private func sendMouse(_ kind: AgentRemoteInput.Kind, _ event: NSEvent, button: String?) {
        guard ownedByUser, let point = pagePoint(for: event) else { return }
        AgentRemotePresence.shared.send(AgentRemoteInput(
            spaceId: target.spaceId, kind: kind, point: point, button: button,
            clickCount: kind == .mouseMoved ? 0 : event.clickCount,
            modifiers: Self.modifiers(event.modifierFlags)), to: target.peerId)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        heldButton = "left"
        sendMouse(.mousePressed, event, button: "left")
    }

    override func mouseUp(with event: NSEvent) {
        heldButton = nil
        sendMouse(.mouseReleased, event, button: "left")
    }

    override func rightMouseDown(with event: NSEvent) {
        heldButton = "right"
        sendMouse(.mousePressed, event, button: "right")
    }

    override func rightMouseUp(with event: NSEvent) {
        heldButton = nil
        sendMouse(.mouseReleased, event, button: "right")
    }

    override func mouseMoved(with event: NSEvent) { sendMouse(.mouseMoved, event, button: nil) }
    override func mouseDragged(with event: NSEvent) { sendMouse(.mouseMoved, event, button: heldButton) }

    override func scrollWheel(with event: NSEvent) {
        guard ownedByUser, let point = pagePoint(for: event) else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        AgentRemotePresence.shared.send(AgentRemoteInput(
            spaceId: target.spaceId, kind: .mouseWheel, point: point,
            delta: CGSize(width: -event.scrollingDeltaX * scale, height: -event.scrollingDeltaY * scale),
            modifiers: Self.modifiers(event.modifierFlags)), to: target.peerId)
    }

    /// macOS key code → DOM key, code and Windows virtual key code.
    private static let specialKeys: [UInt16: (key: String, code: String, vk: Int, text: String?)] = [
        36: ("Enter", "Enter", 13, "\r"), 76: ("Enter", "NumpadEnter", 13, "\r"),
        48: ("Tab", "Tab", 9, nil), 51: ("Backspace", "Backspace", 8, nil),
        53: ("Escape", "Escape", 27, nil), 117: ("Delete", "Delete", 46, nil),
        123: ("ArrowLeft", "ArrowLeft", 37, nil), 124: ("ArrowRight", "ArrowRight", 39, nil),
        125: ("ArrowDown", "ArrowDown", 40, nil), 126: ("ArrowUp", "ArrowUp", 38, nil),
        115: ("Home", "Home", 36, nil), 119: ("End", "End", 35, nil),
        116: ("PageUp", "PageUp", 33, nil), 121: ("PageDown", "PageDown", 34, nil),
    ]

    override func keyDown(with event: NSEvent) {
        guard ownedByUser else { return }
        let presence = AgentRemotePresence.shared
        let modifiers = Self.modifiers(event.modifierFlags)
        if let special = Self.specialKeys[event.keyCode] {
            for kind in [AgentRemoteInput.Kind.keyDown, .keyUp] {
                presence.send(AgentRemoteInput(
                    spaceId: target.spaceId, kind: kind, key: special.key, code: special.code,
                    keyCode: special.vk, text: kind == .keyDown ? special.text : nil,
                    modifiers: modifiers), to: target.peerId)
            }
            return
        }
        // Command shortcuts stay with this Mac's menus.
        guard !event.modifierFlags.contains(.command),
              let text = event.characters, !text.isEmpty else {
            return super.keyDown(with: event)
        }
        presence.send(AgentRemoteInput(spaceId: target.spaceId, kind: .insertText, text: text),
                      to: target.peerId)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Native overlay for an agent Space's content area. Renders the agent cursor
/// and a status/control pill, and — in watch mode — swallows content input so
/// a watching user can't disturb the agent's page; ownership transfers only
/// through the pill's explicit "Take control" button. A native layer is used
/// (not injected DOM) so it survives navigation, works over any page, and can
/// reliably act as the input interceptor.
final class AgentSpaceOverlayView: NSView {
    var onTakeControl: (() -> Void)?
    var onHandBack: (() -> Void)?
    var onFinish: (() -> Void)?

    private var ownership: AgentTaskOwnership = .agent

    private let cursorLayer = CALayer()
    private let pill = NSVisualEffectView()
    private let captionLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupCursor()
        setupPill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    private func setupCursor() {
        cursorLayer.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        cursorLayer.contents = NSImage(
            systemSymbolName: "cursorarrow", accessibilityDescription: "Agent cursor")
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
    }

    private func setupPill() {
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(primaryButton, action: #selector(primaryTapped))
        configureButton(secondaryButton, action: #selector(secondaryTapped))

        let stack = NSStackView(views: [captionLabel, primaryButton, secondaryButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            pill.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Update

    func update(with task: AgentTask?) {
        guard let task else { return }
        ownership = task.ownership

        switch task.status {
        case .failed(let message):
            captionLabel.stringValue = "⚠︎ \(message)"
            captionLabel.textColor = .systemRed
        default:
            captionLabel.stringValue = task.statusCaption.isEmpty
                ? (ownership == .agent ? "Agent is working…" : "Agent paused")
                : task.statusCaption
            captionLabel.textColor = .labelColor
        }

        switch ownership {
        case .agent:
            primaryButton.title = "Take control"
            primaryButton.isHidden = false
            secondaryButton.isHidden = true
        case .user:
            primaryButton.title = "Hand back"
            secondaryButton.title = "Finish"
            primaryButton.isHidden = false
            secondaryButton.isHidden = false
        }

        if let point = task.cursor {
            cursorLayer.isHidden = false
            // Cursor point is in view coordinates (converted by the mounter).
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            cursorLayer.position = point
            CATransaction.commit()
        } else {
            cursorLayer.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch ownership {
        case .agent: onTakeControl?()
        case .user: onHandBack?()
        }
    }

    @objc private func secondaryTapped() {
        onFinish?()
    }

    // MARK: - Input interception

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always let the pill's controls receive events.
        let pointInPill = convert(point, to: pill)
        if pill.bounds.contains(pointInPill), let hit = super.hitTest(point) {
            return hit
        }
        // Watch mode: swallow all content input so a watching user can't
        // interfere with the agent — but taking control requires the explicit
        // "Take control" button, NOT a stray page click. User mode: pass
        // content through so the user can browse.
        return ownership == .agent ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Agent mode: swallow the click (no-op). Do NOT take control — only the
        // "Take control" button (primaryTapped) transfers ownership.
    }

    override func scrollWheel(with event: NSEvent) {
        // Agent mode: swallow scroll so a watching user can't move the agent's
        // page. (In user mode this view isn't in the hit path.)
        if ownership != .agent { super.scrollWheel(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if ownership != .agent { super.rightMouseDown(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if ownership != .agent { super.otherMouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if ownership != .agent { super.mouseDragged(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if ownership != .agent { super.magnify(with: event) }
    }

    override func swipe(with event: NSEvent) {
        if ownership != .agent { super.swipe(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        // Agent mode: swallow keys (no-op) so they neither reach the page nor
        // take control. User mode: this view isn't in the hit path.
        if ownership != .agent {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { ownership == .agent }
}

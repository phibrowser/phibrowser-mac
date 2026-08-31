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
    private let cursorFillLayer = CAGradientLayer()
    private let cursorStrokeLayer = CAShapeLayer()
    /// Distinguishes a sampled cursor path from an occasional endpoint update.
    /// Rapid samples get a short linear bridge; isolated updates retain the
    /// longer native glide used by older drivers.
    private var lastCursorTargetUpdate: CFTimeInterval?
    /// The current typing-pulse outline, replaced (not stacked) on rapid fills.
    private weak var typingPulseLayer: CALayer?
    private let pill = NSVisualEffectView()
    /// Badge for the driving code agent: an SF Symbol glyph plus a short name
    /// ("Claude Code", "Codex", …), so a watching user sees who controls this
    /// Space, not just that "an agent" does.
    private let agentIcon = NSImageView()
    /// Sized per icon source in `update`: brand assets pad their ink (see
    /// `AgentDriverBadge.assetInkRatio`) and get a wider slot so the visible
    /// glyph matches the 14pt the SF Symbol fallback occupies.
    private var agentIconWidth: NSLayoutConstraint?
    private var agentIconHeight: NSLayoutConstraint?
    private let agentLabel = NSTextField(labelWithString: "")
    private let agentDivider = NSBox()
    private let captionLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    /// Folds the pill down to its ownership buttons and parks it in the
    /// bottom-right corner, for a user who wants the page back.
    private let collapseButton = NSButton()
    /// Collapsed is a deliberate user choice, so it survives every `update`
    /// and every ownership flip — nothing re-expands the pill but the user.
    private var isCollapsed = false
    /// Bottom-centre when expanded, bottom-right corner when collapsed; one is
    /// always active and the other never is.
    private var pillCenterX: NSLayoutConstraint?
    private var pillCornerTrailing: NSLayoutConstraint?
    /// Holds the badge, divider and caption — everything the fold takes away.
    /// Its width is the one thing the animation drives; the pill's own width
    /// follows its content, so the ownership buttons are never compressed.
    private let detailBox = NSView()
    /// Pins the box open at a measured width, or shut at zero. Inactive while
    /// the pill is expanded, so the pane clamp governs the caption as usual.
    private var detailWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupCursor()
        setupPill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    /// The cursor glyph's design-asset size (viewBox units) and its scale to
    /// the rendered 27pt-tall cursor.
    private static let cursorDesignSize = CGSize(width: 14.0089, height: 15.9927)
    private static let cursorScale: CGFloat = 27.0 / cursorDesignSize.height

    private func setupCursor() {
        // The arrow is a path, not an image, so its fill and border can follow
        // the Space's theme — colors are applied by `applyTheme`, called from
        // the hosting controller on mount and on every theme change.
        let path = Self.makeCursorPath()
        let pad = Self.cursorScale  // room for the centered border stroke
        cursorLayer.bounds = CGRect(
            x: 0, y: 0,
            width: path.boundingBoxOfPath.maxX + pad,
            height: path.boundingBoxOfPath.maxY + pad)
        // Pin the glyph's tip (top-left) to the reported cursor point, the way
        // a real pointer's hotspot sits at its tip.
        cursorLayer.anchorPoint = CGPoint(x: 0.1, y: 0.89)
        cursorLayer.isHidden = true

        let mask = CAShapeLayer()
        mask.path = path
        mask.frame = cursorLayer.bounds
        cursorFillLayer.frame = cursorLayer.bounds
        cursorFillLayer.mask = mask
        // Pale at the visual top of the arrow, theme color at the bottom
        // (unit coords are y-up in an unflipped view).
        cursorFillLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cursorFillLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cursorLayer.addSublayer(cursorFillLayer)

        cursorStrokeLayer.path = path
        cursorStrokeLayer.frame = cursorLayer.bounds
        cursorStrokeLayer.fillColor = nil
        cursorStrokeLayer.lineWidth = Self.cursorScale  // the design's 1px border
        cursorStrokeLayer.lineJoin = .round
        cursorLayer.addSublayer(cursorStrokeLayer)

        layer?.addSublayer(cursorLayer)
    }

    /// Tints the agent cursor from the Space's theme. Light appearance fills
    /// the arrow with a vertical gradient from a pale tint of the theme color
    /// down to the theme color itself, bordered in a dark shade of the same
    /// hue; dark appearance fills with the theme color outlined in white.
    func applyTheme(_ theme: Theme, appearance: Appearance) {
        guard let themeColor = theme.color(for: .themeColor, appearance: appearance)
            .usingColorSpace(.sRGB) else { return }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        themeColor.getHue(
            &hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        switch appearance {
        case .light:
            let tint = NSColor(
                hue: hue, saturation: saturation * 0.28,
                brightness: max(brightness, 0.96), alpha: 1)
            let border = NSColor(
                hue: hue, saturation: min(saturation + 0.05, 1),
                brightness: 0.3, alpha: 1)
            cursorFillLayer.colors = [tint.cgColor, themeColor.cgColor]
            cursorStrokeLayer.strokeColor = border.cgColor
        case .dark:
            cursorFillLayer.colors = [themeColor.cgColor, themeColor.cgColor]
            cursorStrokeLayer.strokeColor = NSColor.white.cgColor
        }

        accentFill = themeColor
        applyPrimaryButtonTint(title: primaryButton.title)
    }

    /// The arrow glyph from the design, authored y-down in a
    /// 14.0089 × 15.9927 viewBox and flipped/scaled into layer space.
    private static func makeCursorPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.5039, y: 1.8181))
        p.addCurve(
            to: CGPoint(x: 2.8730, y: 0.8133),
            control1: CGPoint(x: 0.5893, y: 0.6644),
            control2: CGPoint(x: 1.9677, y: 0.1012))
        p.addLine(to: CGPoint(x: 12.9990, y: 8.7879))
        p.addCurve(
            to: CGPoint(x: 12.1641, y: 11.1219),
            control1: CGPoint(x: 14.0076, y: 9.5821),
            control2: CGPoint(x: 13.3921, y: 11.1219))
        p.addLine(to: CGPoint(x: 6.5400, y: 11.1219))
        p.addCurve(
            to: CGPoint(x: 6.1689, y: 11.2039),
            control1: CGPoint(x: 6.4112, y: 11.1219),
            control2: CGPoint(x: 6.2842, y: 11.1504))
        p.addCurve(
            to: CGPoint(x: 5.8750, y: 11.4285),
            control1: CGPoint(x: 6.0539, y: 11.2573),
            control2: CGPoint(x: 5.9535, y: 11.3341))
        p.addLine(to: CGPoint(x: 2.8984, y: 15.0076))
        p.addCurve(
            to: CGPoint(x: 0.5000, y: 14.1668),
            control1: CGPoint(x: 2.1136, y: 15.9510),
            control2: CGPoint(x: 0.5001, y: 15.4459))
        p.addLine(to: CGPoint(x: 0.5000, y: 1.9314))
        p.closeSubpath()
        var flip = CGAffineTransform(scaleX: cursorScale, y: -cursorScale)
            .translatedBy(x: 0, y: -cursorDesignSize.height)
        return p.copy(using: &flip) ?? p
    }

    private func setupPill() {
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        // The fold narrows the pill over content that is still laid out wide;
        // clip so nothing spills past the rounded edge on the way in or out.
        pill.layer?.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        agentIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        agentIcon.contentTintColor = .labelColor
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentIcon.translatesAutoresizingMaskIntoConstraints = false
        agentIcon.setContentHuggingPriority(.required, for: .horizontal)
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 14)
        agentIconHeight = agentIcon.heightAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([agentIconWidth!, agentIconHeight!])

        agentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        agentLabel.textColor = .labelColor
        agentLabel.lineBreakMode = .byTruncatingTail
        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        agentLabel.setContentHuggingPriority(.required, for: .horizontal)

        agentDivider.boxType = .separator
        agentDivider.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 1
        captionLabel.cell?.truncatesLastVisibleLine = true
        // The caption is agent-authored free text and can run to a whole
        // sentence, so it is the ONE part of the pill allowed to give up width:
        // the driver badge stays readable and the ownership buttons stay on
        // screen and clickable however much the agent narrates.
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(primaryButton, action: #selector(primaryTapped))
        configureButton(secondaryButton, action: #selector(secondaryTapped))
        setupCollapseButton()

        // The badge and caption live in their own box, and the box's width is
        // what the fold animates. Squeezing the PILL instead made the stack
        // compress, and compression came for the buttons too — "Hand back"
        // visibly shrank on the way in and sprang back at the end. Nothing
        // squeezes the row now: the box gives up its width, the pill's width
        // follows its content, and the buttons are never asked to move.
        let detailStack = NSStackView(views: [
            agentIcon, agentLabel, agentDivider, captionLabel])
        detailStack.orientation = .horizontal
        detailStack.spacing = 8
        detailStack.alignment = .centerY
        detailStack.setCustomSpacing(6, after: agentIcon)
        detailStack.setCustomSpacing(10, after: agentDivider)
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        detailBox.wantsLayer = true
        // Closing over content that is still laid out wide: clip it.
        detailBox.layer?.masksToBounds = true
        detailBox.translatesAutoresizingMaskIntoConstraints = false
        detailBox.addSubview(detailStack)

        // The gap between the caption and the first button lives INSIDE the
        // box, so a box closed to nothing leaves nothing behind — no stray
        // spacing to snap away at the end of the fold.
        let detailTrailing = detailStack.trailingAnchor.constraint(
            equalTo: detailBox.trailingAnchor, constant: -8)
        detailTrailing.priority = .required - 1
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailBox.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor),
            detailTrailing,
        ])
        detailWidth = detailBox.widthAnchor.constraint(equalToConstant: 0)

        let stack = NSStackView(views: [
            detailBox, primaryButton, secondaryButton, collapseButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.setCustomSpacing(0, after: detailBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            agentDivider.heightAnchor.constraint(equalToConstant: 18),
        ])

        // Width is content-driven but bounded: a long caption truncates instead
        // of growing the pill past the content pane — which pushed "Hand back"
        // and "Finish" off screen, leaving the user no way to return control —
        // and never past a readable line length on a wide display.
        pillCenterX = pill.centerXAnchor.constraint(equalTo: centerXAnchor)
        pillCornerTrailing = pill.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.pillCornerInset)
        pillCenterX?.isActive = true

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Self.pillMinSideInset),
            pill.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.pillMinSideInset),
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: Self.pillMaxWidth),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            pill.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    /// Widest the pill may get, and the gutter it keeps to the pane's edges.
    /// Both are upper bounds on the same width, so the pill settles at
    /// whichever is smaller — a narrow pane clamps before the line-length cap.
    private static let pillMaxWidth: CGFloat = 720
    private static let pillMinSideInset: CGFloat = 16
    /// Distance the collapsed pill keeps from the pane's trailing edge —
    /// the same 24 the expanded pill keeps from the bottom, so it sits square
    /// in the corner.
    private static let pillCornerInset: CGFloat = 24
    /// Fold/unfold timing. The fade is short enough to feel like part of the
    /// fold rather than a step before it.
    private static let foldDuration: TimeInterval = 0.3
    private static let detailFadeDuration: TimeInterval = 0.14

    /// Longest caption laid out. Truncation already handles display; this only
    /// keeps the text engine off a runaway string. The untrimmed caption stays
    /// on the tooltip and in the transcript console.
    private static let captionCharacterLimit = 240

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        // Never squeezed by a long caption — these are the only way to move
        // ownership, so they keep their full width and the caption yields.
        // Above the labels but below required: in a pane too narrow to hold
        // even the buttons, a truncated title beats breaking the width cap and
        // letting the pill spill off screen again.
        button.setContentCompressionResistancePriority(.required - 100, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupCollapseButton() {
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .regularSquare
        collapseButton.imagePosition = .imageOnly
        collapseButton.imageScaling = .scaleProportionallyDown
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.target = self
        collapseButton.action = #selector(collapseTapped)
        collapseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        collapseButton.setContentHuggingPriority(.required, for: .horizontal)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(equalToConstant: 16),
            collapseButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        applyCollapseButtonAppearance()
    }

    private func applyCollapseButtonAppearance() {
        // The chevron points the way the pill travels: right to park it in the
        // corner, left to bring it back out to the middle.
        let symbol = isCollapsed ? "chevron.left" : "chevron.right"
        let title = isCollapsed
            ? NSLocalizedString("agent.controlPill.expandButton", value: "Expand",
                                comment: "Agent control pill - expand the collapsed pill")
            : NSLocalizedString("agent.controlPill.minimiseButton", value: "Minimise",
                                comment: "Agent control pill - collapse the pill into the corner")
        collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        collapseButton.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        collapseButton.toolTip = title
        collapseButton.setAccessibilityLabel(title)
    }

    /// Collapsed keeps ONLY the ownership buttons — the badge, divider and
    /// caption go, and the pill parks in the bottom-right corner so the page
    /// is clear. Everything the caption said is still in the transcript
    /// console, and on the pill's own tooltip.
    /// One continuous motion: the detail box closes, the pill's width follows
    /// it, and the pill travels to the corner — all on the same clock, and
    /// none of it reaching the ownership buttons.
    private func applyCollapsedState(animated: Bool) {
        pill.toolTip = isCollapsed ? captionLabel.toolTip : nil
        applyCollapseButtonAppearance()

        // Respect the system's reduce-motion setting: same end state, no travel.
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            detailBox.alphaValue = isCollapsed ? 0 : 1
            detailWidth?.constant = 0
            detailWidth?.isActive = isCollapsed
            applyPillPosition()
            layoutSubtreeIfNeeded()
            return
        }

        // Mid-flight, `frame` already holds the destination — the presentation
        // layer is where the box actually is, and where this fold must start.
        let startWidth = detailBox.layer?.presentation()?.bounds.width
            ?? detailBox.frame.width
        let targetWidth = isCollapsed ? 0 : measuredDetailWidth()

        detailWidth?.constant = startWidth
        detailWidth?.isActive = true
        applyPillPosition()
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.foldDuration
            // Quick off the mark, long soft landing — the pill reads as being
            // put down in the corner rather than sliding there at a constant clip.
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.32, 0.72, 0, 1)
            context.allowsImplicitAnimation = true
            detailWidth?.animator().constant = targetWidth
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Expanded, the caption answers to the pane clamp again, so the
            // measured width has to let go. Collapsed, the zero stays put.
            detailWidth?.isActive = isCollapsed
        })

        // Concurrent, not sequential — but on its own clock: collapsing dims
        // the detail early so no half-truncated caption is on screen while the
        // box closes over it, and expanding holds it back until the pill has
        // most of its width.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isCollapsed ? Self.detailFadeDuration : Self.foldDuration
            context.timingFunction = CAMediaTimingFunction(
                name: isCollapsed ? .easeOut : .easeIn)
            detailBox.animator().alphaValue = isCollapsed ? 0 : 1
        }
    }

    /// Width the open box settles at: let the pane clamp decide it, read it,
    /// and pin it back. Runs to completion inside one turn of the run loop, so
    /// the intermediate state is never drawn.
    private func measuredDetailWidth() -> CGFloat {
        let wasActive = detailWidth?.isActive ?? false
        detailWidth?.isActive = false
        layoutSubtreeIfNeeded()
        let width = detailBox.frame.width
        detailWidth?.isActive = wasActive
        layoutSubtreeIfNeeded()
        return width
    }

    /// Bottom-centre when expanded, bottom-right corner when collapsed.
    private func applyPillPosition() {
        pillCenterX?.isActive = !isCollapsed
        pillCornerTrailing?.isActive = isCollapsed
    }

    @objc private func collapseTapped() {
        isCollapsed.toggle()
        applyCollapsedState(animated: true)
    }

    // MARK: - Primary action tint

    /// Fill for the ownership-transfer button, from the Space theme. Held
    /// because the button's title changes with ownership and every title change
    /// discards the attributed string carrying its text color.
    private var accentFill: NSColor?

    /// Paints the primary action in the Space theme, so the one control that
    /// transfers ownership reads as part of the mask rather than as a system
    /// button sitting on top of it.
    private func applyPrimaryButtonTint(title: String) {
        guard let fill = accentFill else { return }
        primaryButton.bezelColor = fill
        primaryButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: Self.onAccentColor(for: fill),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
    }

    /// The design's own rule for text on the primary color, so this button and
    /// the buttons the page recoloring paints resolve their contrast the same
    /// way rather than drifting apart.
    private static func onAccentColor(for fill: NSColor) -> NSColor {
        let color = fill.usingColorSpace(.sRGB) ?? fill
        let high = max(color.redComponent, color.greenComponent, color.blueComponent)
        let low = min(color.redComponent, color.greenComponent, color.blueComponent)
        return (high + low) / 2 > 0.66
            ? NSColor(srgbRed: 0x17 / 255, green: 0x15 / 255, blue: 0x1A / 255, alpha: 1)
            : .white
    }

    /// True when `point` — in `sourceView`'s coordinates — lands on the control
    /// pill. The pill is the only live control this overlay exposes, so the
    /// operating mask mounted below it asks before claiming input or the
    /// pointer, which would otherwise strand the user with no way to take
    /// control back.
    func containsControlPill(at point: NSPoint, from sourceView: NSView) -> Bool {
        guard window != nil, !pill.isHidden, !pill.bounds.isEmpty else { return false }
        return pill.bounds.contains(pill.convert(point, from: sourceView))
    }

    /// The control pill's frame in this view's coordinates — for layout
    /// assertions over a long, agent-authored caption.
    var controlPillFrameForTesting: NSRect { pill.frame }

    /// Freezes the fold part-way — 0 wide open, 1 fully shut — so a test can
    /// inspect the geometry the animation passes through.
    func setFoldProgressForTesting(_ fraction: CGFloat) {
        let open = measuredDetailWidth()
        detailWidth?.constant = open * (1 - max(0, min(1, fraction)))
        detailWidth?.isActive = true
        layoutSubtreeIfNeeded()
    }

    /// The ownership button's frame — it must not move or resize mid-fold.
    var controlPillPrimaryButtonFrameForTesting: NSRect { primaryButton.frame }

    /// Drives the minimise toggle the way its button does, minus the animation
    /// so the new geometry has landed by the time the caller reads it.
    func toggleCollapsedForTesting() {
        isCollapsed.toggle()
        applyCollapsedState(animated: false)
    }

    /// What the collapsed pill still shows: the ownership buttons, nothing else.
    var controlPillVisibleItemsForTesting: [String] {
        var items: [String] = []
        // Faded out or closed to nothing — to a reader the detail is gone
        // either way.
        let detailShows = detailBox.alphaValue > 0.01 && detailBox.frame.width > 1
        if detailShows { items.append("badge") }
        if detailShows { items.append("caption") }
        if !primaryButton.isHidden { items.append(primaryButton.title) }
        if !secondaryButton.isHidden { items.append(secondaryButton.title) }
        return items
    }

    // MARK: - Update

    func update(with task: AgentTask?) {
        guard let task else { return }
        ownership = task.ownership

        let badge = AgentDriverBadge.make(agentName: task.agentName, origin: task.origin)
        if let assetName = badge.assetName, let image = NSImage(named: assetName) {
            image.isTemplate = true  // tint with contentTintColor
            agentIcon.image = image
            agentIconWidth?.constant = 14 / AgentDriverBadge.assetInkRatio
            agentIconHeight?.constant = 14 / AgentDriverBadge.assetInkRatio
        } else {
            agentIcon.image = NSImage(systemSymbolName: badge.symbol,
                                      accessibilityDescription: badge.label)
            agentIconWidth?.constant = 14
            agentIconHeight?.constant = 14
        }
        agentLabel.stringValue = badge.label
        agentIcon.toolTip = badge.label
        agentLabel.toolTip = badge.label

        switch task.status {
        case .failed(let message):
            setCaption("⚠︎ \(message)", color: .systemRed)
        default:
            setCaption(
                task.statusCaption.isEmpty
                    ? (ownership == .agent ? "Agent is working…" : "Agent paused")
                    : task.statusCaption,
                color: .labelColor)
        }

        let primaryTitle: String
        switch ownership {
        case .agent:
            primaryTitle = "Take control"
            primaryButton.isHidden = false
            secondaryButton.isHidden = true
        case .user:
            primaryTitle = "Hand back"
            secondaryButton.title = "Finish"
            primaryButton.isHidden = false
            secondaryButton.isHidden = false
        }
        primaryButton.title = primaryTitle
        applyPrimaryButtonTint(title: primaryTitle)
        // `update` re-decides what the ownership row shows; re-assert the
        // user's collapse choice on top of it.
        applyCollapsedState(animated: false)

        moveCursor(to: task.cursor)
    }

    /// Puts one line of agent-authored text on the pill. Captions arrive as
    /// free text — newlines and runs of spaces included — and the pill is a
    /// single line, so collapse the whitespace first and hand the full caption
    /// to the tooltip, which is where a truncated one stays readable.
    private func setCaption(_ text: String, color: NSColor) {
        let flattened = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        captionLabel.stringValue = flattened.count > Self.captionCharacterLimit
            ? String(flattened.prefix(Self.captionCharacterLimit)) + "…"
            : flattened
        captionLabel.textColor = color
        captionLabel.toolTip = flattened.isEmpty ? nil : flattened
    }

    /// Moves (or hides, for `nil`) the agent cursor alone — the streamed-
    /// sample path, called directly by the mounter for each `cursorMoved`
    /// delivery so cursor motion never re-runs the full pill update above.
    /// `point` is in this view's coordinates (converted by the mounter).
    /// Hidden while the USER holds control: the agent stops on takeover, and
    /// its last-reported cursor would otherwise sit frozen next to the real
    /// one. The stored point survives ownership flips (the mounter re-seeds
    /// it), so the cursor reappears where it was on hand-back.
    func moveCursor(to point: CGPoint?) {
        guard let point, ownership == .agent else {
            cursorLayer.isHidden = true
            lastCursorTargetUpdate = nil
            return
        }
        let wasHidden = cursorLayer.isHidden
        cursorLayer.isHidden = false
        let current = cursorLayer.presentation()?.position ?? cursorLayer.position
        let previousTarget = cursorLayer.position
        let distance = hypot(point.x - current.x, point.y - current.y)
        let targetChanged = hypot(point.x - previousTarget.x, point.y - previousTarget.y) >= 0.5
        let now = CACurrentMediaTime()
        let updateGap = targetChanged ? lastCursorTargetUpdate.map { now - $0 } : nil
        if targetChanged {
            lastCursorTargetUpdate = now
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = point
        CATransaction.commit()
        if !wasHidden && distance >= 2 {
            // A sampled driver reports the same path points it dispatches
            // into the page. Bridge rapid points over approximately one
            // sample interval so the overlay follows that curved trace.
            // Older drivers report isolated endpoints; retain their longer
            // eased glide. First appearance skips animation because there
            // is no meaningful prior position.
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = current
            glide.toValue = point
            if let updateGap, updateGap < 0.09 {
                glide.duration = min(0.05, max(1.0 / 120.0, updateGap * 1.15))
                glide.timingFunction = CAMediaTimingFunction(name: .linear)
            } else {
                glide.duration = min(0.45, max(0.18, distance / 1000))
                glide.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.3, 0.0, 0.15, 1.0)
            }
            cursorLayer.add(glide, forKey: "glide")
        } else {
            cursorLayer.removeAnimation(forKey: "glide")
        }
    }

    // MARK: - Transient input effects

    /// Plays a short, self-removing animation mirroring one agent input action
    /// so a watching user can follow what the agent is doing. `point` is in
    /// this view's coordinate space (converted by the mounter).
    func playEffect(kind: AgentEffect.Kind, at point: CGPoint, size: CGSize?, dy: CGFloat?) {
        switch kind {
        case .click: playClickRipple(at: point)
        case .type: playTypingPulse(at: point, size: size)
        case .scroll: playScrollHint(at: point, dy: dy ?? 1)
        }
    }

    private var effectColor: CGColor {
        NSColor.controlAccentColor.cgColor
    }

    private func addTransientLayer(_ transient: CALayer, removeAfter delay: TimeInterval) {
        layer?.addSublayer(transient)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak transient] in
            transient?.removeFromSuperlayer()
        }
    }

    /// Two staggered rings expanding out of the click point over a brief
    /// center dot — reads as a "tap" even at a glance.
    private func playClickRipple(at point: CGPoint) {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8), transform: nil)
        dot.fillColor = effectColor
        dot.position = point
        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 1.0
        dotFade.toValue = 0.0
        dotFade.duration = 0.35
        dotFade.isRemovedOnCompletion = false
        dotFade.fillMode = .forwards
        dot.add(dotFade, forKey: "fade")
        addTransientLayer(dot, removeAfter: 0.4)

        for (index, delay) in [0.0, 0.14].enumerated() {
            let ring = CAShapeLayer()
            let radius: CGFloat = index == 0 ? 18 : 26
            ring.path = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil)
            ring.fillColor = nil
            ring.strokeColor = effectColor
            ring.lineWidth = 2.5
            ring.position = point
            ring.opacity = 0

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.25
            scale.toValue = 1.0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.0, 0.85, 0.0]
            fade.keyTimes = [0, 0.25, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.5
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "ripple")
            addTransientLayer(ring, removeAfter: delay + 0.55)
        }
    }

    /// A pulsing outline around the field being typed into, with three
    /// "typing…" dots blinking under its trailing edge.
    private func playTypingPulse(at point: CGPoint, size: CGSize?) {
        // Replace any still-visible pulse: rapid fills must not stack outlines.
        typingPulseLayer?.removeFromSuperlayer()

        let width = min(max(size?.width ?? 160, 40), max(bounds.width, 40))
        let height = min(max(size?.height ?? 32, 22), max(bounds.height, 22))
        let boxSize = CGSize(width: width + 8, height: height + 8)
        let box = CAShapeLayer()
        box.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: boxSize),
            cornerWidth: 7, cornerHeight: 7, transform: nil)
        box.bounds = CGRect(origin: .zero, size: boxSize)
        box.position = point
        box.strokeColor = effectColor
        box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
        box.lineWidth = 2

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.4
        pulse.autoreverses = true
        pulse.repeatCount = 2
        box.add(pulse, forKey: "pulse")

        // Group opacity carries the dots out with the box.
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = 0.25
        fadeOut.beginTime = CACurrentMediaTime() + 1.6
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        box.add(fadeOut, forKey: "fadeOut")

        for i in 0..<3 {
            let typingDot = CAShapeLayer()
            typingDot.path = CGPath(
                ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
            typingDot.fillColor = effectColor
            // Under the box's bottom-right corner (unflipped coords: below = -y).
            typingDot.position = CGPoint(x: boxSize.width - 30 + CGFloat(i) * 11, y: -9)
            typingDot.opacity = 0.2
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0.2, 1.0, 0.2]
            blink.keyTimes = [0, 0.5, 1]
            blink.duration = 0.6
            blink.repeatCount = 3
            blink.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            typingDot.add(blink, forKey: "blink")
            box.addSublayer(typingDot)
        }

        typingPulseLayer = box
        addTransientLayer(box, removeAfter: 1.95)
    }

    /// Three chevrons drifting in the scroll direction from the wheel's anchor
    /// point. `dy` follows the wheel convention: positive scrolls the page
    /// down, so the hint drifts down-screen (-y in unflipped view coords).
    private func playScrollHint(at point: CGPoint, dy: CGFloat) {
        let downOnScreen = dy >= 0
        let travel: CGFloat = downOnScreen ? -34 : 34
        let apexY: CGFloat = downOnScreen ? -5 : 5
        for i in 0..<3 {
            let chevron = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -10, y: -apexY))
            path.addLine(to: CGPoint(x: 0, y: apexY))
            path.addLine(to: CGPoint(x: 10, y: -apexY))
            chevron.path = path
            chevron.strokeColor = effectColor
            chevron.fillColor = nil
            chevron.lineWidth = 3
            chevron.lineCap = .round
            chevron.lineJoin = .round
            chevron.position = point
            chevron.opacity = 0

            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = point.y - travel * 0.5
            move.toValue = point.y + travel
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.0, 0.9, 0.0]
            fade.keyTimes = [0, 0.35, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.55
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.12
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(group, forKey: "drift")
            addTransientLayer(chevron, removeAfter: Double(i) * 0.12 + 0.6)
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

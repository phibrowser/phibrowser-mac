// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class LayoutSelectionViewController: OnboardingBaseViewController {

    private var selectedMode: LayoutMode = .balanced

    private let optionWidth: CGFloat = 456
    private let optionHeight: CGFloat = 116
    private let optionSpacing: CGFloat = 8
    private let containerWidth: CGFloat = 472
    private let containerLeftOffset: CGFloat = 84
    private let containerCornerRadius: CGFloat = 14
    private let containerPadding: CGFloat = 8

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var optionsStackView: OnboardingOptionStackView = {
        let stackView = OnboardingOptionStackView()
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()

    private lazy var performanceOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("oobe.layoutSelection.performanceOption", value: "Performance", comment: "Onboarding layout selection - Performance option"),
            previewImage: NSImage(resource: .tabLayoutPerformanceOobe),
            isSelected: selectedMode == .performance
        )
        view.onTap = { [weak self] in
            self?.selectMode(.performance)
        }
        return view
    }()

    private lazy var balancedOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("oobe.layoutSelection.balancedOption", value: "Balanced", comment: "Onboarding layout selection - Balanced option"),
            previewImage: NSImage(resource: .tabLayoutBalancedOobe),
            isSelected: selectedMode == .balanced
        )
        view.onTap = { [weak self] in
            self?.selectMode(.balanced)
        }
        return view
    }()

    private lazy var comfortableOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("oobe.layoutSelection.comfortableOption", value: "Comfortable", comment: "Onboarding layout selection - Comfortable option"),
            previewImage: NSImage(resource: .tabLayoutComfortableOobe),
            isSelected: selectedMode == .comfortable
        )
        view.onTap = { [weak self] in
            self?.selectMode(.comfortable)
        }
        return view
    }()

    // MARK: - Lifecycle

    override func loadView() {
        super.loadView()
        setTitle(NSLocalizedString("oobe.layoutSelection.title", value: "Layout selection",
            comment: "Onboarding layout selection - Page title"
        ))
        configureFooterButtons(.init(
            leftTitle: NSLocalizedString(
                "oobe.navigation.backButton",
                value: "Back",
                comment: "OOBE navigation - Button to return to the previous step"
            ),
            rightTitle: nextButton.title
        ))
        setupLayoutOptions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        optionsStackView.configureKeyViewLoop(nextButton: nextButton, backButton: leftButton)
        balancedOptionView.takeInitialFocus(in: window)
    }

    // MARK: - Options Setup

    private func setupLayoutOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(optionsStackView)

        let optionViews = [balancedOptionView, performanceOptionView, comfortableOptionView]
        for optionView in optionViews {
            optionsStackView.addArrangedSubview(optionView)
            optionView.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
                make.height.equalTo(optionHeight)
            }
        }

        optionsContainer.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(containerLeftOffset)
            make.centerY.equalToSuperview()
            make.width.equalTo(containerWidth)
        }

        optionsStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(containerPadding)
        }
    }

    private func selectMode(_ mode: LayoutMode) {
        selectedMode = mode
        performanceOptionView.setSelected(mode == .performance)
        balancedOptionView.setSelected(mode == .balanced)
        comfortableOptionView.setSelected(mode == .comfortable)
    }

    // MARK: - Actions

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        PhiPreferences.GeneralSettings.saveLayoutMode(selectedMode)
        nextClosure?(true)
    }
}

/// Arrow keys select the adjacent option, starting from the focused option or,
/// when no option has keyboard focus, from the selected one. Tab is left to
/// AppKit's key-view loop, including the page's footer buttons.
final class OnboardingOptionStackView: NSStackView {
    func configureKeyViewLoop(nextButton: NSView, backButton: NSView) {
        window?.recalculateKeyViewLoop()
        // Hosting views contain the actual focusable button responders.
        guard let firstOption = arrangedSubviews.first,
              let lastOption = arrangedSubviews.last,
              let nextFocus = nextButton.nextValidKeyView,
              nextFocus.isDescendant(of: nextButton),
              let backFocus = backButton.nextValidKeyView,
              backFocus.isDescendant(of: backButton) else { return }
        lastOption.nextKeyView = nextFocus
        nextFocus.nextKeyView = backFocus
        backFocus.nextKeyView = firstOption
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.keyCode == 125 || event.keyCode == 126,
              let window, window.isKeyWindow, window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else {
            return super.performKeyEquivalent(with: event)
        }
        let options = arrangedSubviews.compactMap { $0 as? OnboardingOptionView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        let focusedOption = window.firstResponder as? OnboardingOptionView
        guard let currentOption = focusedOption ?? options.first(where: \.isSelected),
              let index = options.firstIndex(where: { $0 === currentOption }) else {
            return super.performKeyEquivalent(with: event)
        }
        let offset = event.keyCode == 125 ? 1 : -1
        let target = options[(index + offset + options.count) % options.count]
        if focusedOption != nil, !window.makeFirstResponder(target) {
            return true
        }
        target.onTap?()
        return true
    }
}

/// A radio option participates in native focus navigation without selecting on Tab.
class OnboardingOptionView: NSView {
    var onTap: (() -> Void)?
    var isSelected = false

    // Like system controls, options take focus only with Keyboard navigation on.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }

    // makeFirstResponder ignores acceptsFirstResponder, so explicit focus
    // requests go through these to respect Keyboard navigation.
    func takeFocus() {
        guard acceptsFirstResponder else { return }
        window?.makeFirstResponder(self)
    }

    func takeInitialFocus(in window: NSWindow) {
        guard acceptsFirstResponder else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func becomeFirstResponder() -> Bool {
        setKeyboardFocusRingNeedsDisplay(bounds)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        setKeyboardFocusRingNeedsDisplay(bounds)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 49, modifiers.isEmpty {
            if !event.isARepeat { onTap?() }
        } else if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            interpretKeyEvents([event])
        } else {
            super.keyDown(with: event)
        }
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }
}

// MARK: - LayoutOptionView

class LayoutOptionView: OnboardingOptionView {
    private let titleLabel: NSTextField
    private let previewImageView: NSImageView
    private let checkmarkImageView: NSImageView
    var selectedColor = NSColor.white.withAlphaComponent(0.1)
    var deselectedColor = NSColor.clear

    private let cornerRadius: CGFloat = 8
    private let titleFontSize: CGFloat = 18
    private let horizontalPadding: CGFloat = 18
    private let previewWidth: CGFloat = 140
    private let previewHeight: CGFloat = 81
    private let previewCornerRadius: CGFloat = 6
    private let previewBorderInset: CGFloat = 1
    private let previewToCheckmarkSpacing: CGFloat = 16
    private let checkmarkSize: CGFloat = 18

    init(title: String, previewImage: NSImage, isSelected: Bool) {
        self.titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: titleFontSize, weight: .regular)
        titleLabel.textColor = .white

        self.previewImageView = NSImageView(image: previewImage)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = previewCornerRadius
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.borderWidth = 1
        previewImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        self.checkmarkImageView = NSImageView()

        super.init(frame: .zero)

        self.isSelected = isSelected
        setupUI()
        updateSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        addSubview(titleLabel)
        addSubview(previewImageView)
        addSubview(checkmarkImageView)

        titleLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
        }

        previewImageView.snp.makeConstraints { make in
            make.right.equalTo(checkmarkImageView.snp.left).offset(-previewToCheckmarkSpacing)
            make.centerY.equalToSuperview()
            make.width.equalTo(previewWidth)
            make.height.equalTo(previewHeight)
        }

        checkmarkImageView.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(checkmarkSize)
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(click)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(titleLabel.stringValue)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        updateSelection()
    }

    private func updateSelection() {
        if isSelected {
            layer?.backgroundColor = selectedColor.cgColor
            checkmarkImageView.image = NSImage(resource: .check)
        } else {
            layer?.backgroundColor = deselectedColor.cgColor
            checkmarkImageView.image = NSImage(resource: .uncheck)
        }
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    @objc private func handleTap() {
        takeFocus()
        onTap?()
    }

    // VoiceOver reads the option as a single radio button; the title, preview
    // and checkmark are not exposed separately.
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        onTap?()
        return true
    }
}

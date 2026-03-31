// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Data types available for import, with their Chromium bridge string keys.
enum ImportDataType: String, CaseIterable {
    case bookmarks = "favorites"   // Chromium uses "favorites"
    case history = "history"
    case cookies = "cookies"
    case extensions = "extensions"

    var displayName: String {
        switch self {
        case .bookmarks:
            return NSLocalizedString("Bookmarks", comment: "Import data type - Bookmarks toggle label")
        case .history:
            return NSLocalizedString("Browsing history", comment: "Import data type - Browsing history toggle label")
        case .cookies:
            return NSLocalizedString("Cookies", comment: "Import data type - Cookies toggle label")
        case .extensions:
            return NSLocalizedString("Extensions", comment: "Import data type - Extensions toggle label")
        }
    }

    /// Which data types each browser supports.
    static func availableTypes(for browser: BrowserType) -> [ImportDataType] {
        switch browser {
        case .safari:
            return [.bookmarks, .history]
        case .chrome, .arc:
            return [.bookmarks, .history, .cookies, .extensions]
        default:
            return [.bookmarks, .history]
        }
    }
}

class ImportDataTypeViewController: OnboardingBaseViewController {
    enum DisplayMode {
        case login   // 640x800 for onboarding
        case normal  // 500x625 for standalone window
    }

    let browserType: BrowserType
    private let displayMode: DisplayMode
    private let availableTypes: [ImportDataType]
    private(set) var selectedTypes: Set<ImportDataType>
    /// Called when user taps Return. Bool indicates whether any data types are selected.
    var onReturn: ((_ hasSelection: Bool) -> Void)?

    private var viewWidth: CGFloat { displayMode == .login ? 640 : 500 }
    private var viewHeight: CGFloat { displayMode == .login ? 800 : 625 }
    private var titleFontSize: CGFloat { displayMode == .login ? 46 : 32 }
    private var titleTopOffset: CGFloat { displayMode == .login ? 96 : 56 }
    private var optionWidth: CGFloat { displayMode == .login ? 456 : 364 }
    private var optionHeight: CGFloat { displayMode == .login ? 44 : 36 }
    private var optionFontSize: CGFloat { displayMode == .login ? 18 : 15 }
    private var optionSpacing: CGFloat = 8
    private var containerWidth: CGFloat { displayMode == .login ? 472 : 380 }
    private var containerLeftOffset: CGFloat { displayMode == .login ? 84 : 60 }
    private var containerCornerRadius: CGFloat = 14
    private var containerPadding: CGFloat = 8
    private var buttonBottomOffset: CGFloat { displayMode == .login ? -96 : -56 }

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var optionsStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()

    init(browserType: BrowserType, displayMode: DisplayMode = .login) {
        self.browserType = browserType
        self.displayMode = displayMode
        self.availableTypes = ImportDataType.availableTypes(for: browserType)
        self.selectedTypes = []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        super.loadView()
        titleLabel.stringValue = NSLocalizedString(
            "Browser data",
            comment: "Import data type selection - Page title"
        )
        nextButton.isHidden = true
        skipButton.title = NSLocalizedString(
            "Return",
            comment: "Import data type selection - Return button to go back"
        )
        applyDisplayModeLayout()
        setupToggleOptions()
    }

    private func applyDisplayModeLayout() {
        view.snp.remakeConstraints { make in
            make.width.equalTo(viewWidth)
            make.height.equalTo(viewHeight)
        }

        titleLabel.font = NSFont(name: "IvyPresto Headline", size: titleFontSize)
        titleLabel.snp.remakeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(titleTopOffset)
        }

        skipButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
        }
    }

    // MARK: - Options Setup

    private func setupToggleOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(optionsStackView)

        for dataType in availableTypes {
            let row = DataTypeToggleRow(title: dataType.displayName, isOn: false)
            row.onToggle = { [weak self] isOn in
                guard let self else { return }
                if isOn {
                    self.selectedTypes.insert(dataType)
                } else {
                    self.selectedTypes.remove(dataType)
                }
            }
            optionsStackView.addArrangedSubview(row)
            row.snp.makeConstraints { make in
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

    /// Returns the selected data type strings for the Chromium bridge.
    func selectedDataTypeStrings() -> [String] {
        selectedTypes.map { $0.rawValue }
    }

    // MARK: - Actions

    @objc override func skipButtonTapped(_ sender: NSButton) {
        onReturn?(!selectedTypes.isEmpty)
    }
}

// MARK: - DataTypeToggleRow

class DataTypeToggleRow: NSView {
    var onToggle: ((Bool) -> Void)?

    private let toggle: NSSwitch
    private let cornerRadius: CGFloat = 8
    private let labelFontSize: CGFloat = 18
    private let horizontalPadding: CGFloat = 18

    init(title: String, isOn: Bool) {
        toggle = NSSwitch()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: labelFontSize, weight: .regular)
        label.textColor = .white

        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        addSubview(label)
        addSubview(toggle)

        label.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
        }

        toggle.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        onToggle?(sender.state == .on)
    }
}

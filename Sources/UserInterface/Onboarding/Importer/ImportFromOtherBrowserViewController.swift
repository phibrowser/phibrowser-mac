// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

class ImportFromOtherBrowserViewController: OnboardingBaseViewController {
    enum Phase {
        case importor, permision
    }
    
    enum DisplayMode {
        case login   // 640x800 for onboarding.
        case normal  // 500x700 for the standalone window.
    }
    
    var onCompletion: (() -> Void)?
    /// Per-browser selected data types in the Chromium bridge wire format,
    /// projected live from `selectedTypesPerBrowser`. A browser with no selected
    /// type is omitted; an all-empty selection is nil. Computed (never a stored
    /// snapshot) so the import always reflects the current inline toggle state.
    /// `nil`/missing key means "import all" downstream (BrowserDataImporter.swift:116).
    var dataTypesPerBrowser: [BrowserType: [String]]? {
        Self.projectDataTypes(selectedTypesPerBrowser)
    }
    var phase = Phase.importor
    private let displayMode: DisplayMode
    private var targetProfileId: String
    private var targetSpaceId: String
    private var targetWindowId: Int?
    
    private var viewWidth: CGFloat { displayMode == .login ? 640 : 500 }
    /// Normal (standalone window) height is sized for the worst-case expanded
    /// accordion row: title chain bottom 136 + 8 + card 440 (4-toggle row) +
    /// 12 + Next button 40 + bottom margin 56 = 692, rounded up — so an expanded
    /// card can never overlap (and hitTest-swallow) the Next button.
    private var viewHeight: CGFloat { displayMode == .login ? 800 : 700 }
    private var titleFontSize: CGFloat { displayMode == .login ? 46 : 32 }
    private var titleTopOffset: CGFloat { displayMode == .login ? 96 : 56 }
    private var optionWidth: CGFloat { displayMode == .login ? 472 : 380 }
    private var optionHeight: CGFloat { displayMode == .login ? 68 : 56 }
    /// Height of an inline data-type toggle row (mirrors the old page-2 metric).
    private var toggleRowHeight: CGFloat { displayMode == .login ? 44 : 36 }
    /// Font size of the small reminder caption under Safari's toggles.
    private var hintFontSize: CGFloat { displayMode == .login ? 13 : 12 }
    private let optionIconSize: CGFloat = 32
    private var optionFontSize: CGFloat { displayMode == .login ? 18 : 15 }
    private var buttonBottomOffset: CGFloat { displayMode == .login ? -96 : -56 }
    private var permissionImageWidth: CGFloat { displayMode == .login ? 472 : 380 }
    private var permissionImageHeight: CGFloat { displayMode == .login ? 248 : 200 }
    private var permissionImageTopOffset: CGFloat { displayMode == .login ? 264 : 200 }
    private var descriptionFontSize: CGFloat { displayMode == .login ? 15 : 13 }
    
    init(
        displayMode: DisplayMode = .login,
        targetProfileId: String = LocalStore.defaultProfileId,
        targetSpaceId: String = LocalStore.defaultSpaceId,
        targetWindowId: Int? = nil
    ) {
        self.displayMode = displayMode
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.displayMode = .login
        self.targetProfileId = LocalStore.defaultProfileId
        self.targetSpaceId = LocalStore.defaultSpaceId
        self.targetWindowId = nil
        super.init(coder: coder)
    }
    
    private lazy var importer = BrowserDataImporter(
        targetProfileId: targetProfileId,
        targetSpaceId: targetSpaceId,
        targetWindowId: targetWindowId
    )

    /// Retargets this single import window when it is re-invoked from another
    /// Space. No-op while an import is in flight, so the running import keeps the
    /// destination it was started for and only the window is brought forward.
    func rebindTarget(profileId: String, spaceId: String, windowId: Int?) {
        guard !importer.isImporting else { return }
        targetProfileId = profileId
        targetSpaceId = spaceId
        targetWindowId = windowId
        importer.updateTarget(profileId: profileId, spaceId: spaceId, windowId: windowId)
        refreshTargetLabel()
    }

    /// Clears the previous import's inline selection + status so a re-opened standalone
    /// singleton window (which reuses the same VC) starts fresh, instead of showing stale
    /// toggles, a completed-status line, and a greyed-out Next. No-op while an import is in
    /// flight, so a re-invoke during the deferred-persist window can't wipe live state.
    func resetForReuse() {
        guard !importer.isImporting else { return }
        showSelectionView()
        selectedTypesPerBrowser.removeAll()
        configuredBrowsers.removeAll()
        resetImportFileSelection()
        toggleRowsPerBrowser.values.forEach { $0.forEach { $0.setOn(false) } }
        collapseAll()
        updateImportStatus("")
        updateConfiguredAppearance()
        updateNextButtonState()
    }

    /// Caption (standalone window only) showing where bookmarks will land: the
    /// target Space's icon + name and, in parentheses, its profile.
    private lazy var targetHostingView = NSHostingView(rootView: ImportTargetView(iconStoredValue: nil, text: ""))

    /// Formats the import-target caption: "Space Name (Profile Name)", or just
    /// the Space name when the profile can't be resolved.
    static func formatNameWithParenthetical(primary: String, secondary: String?) -> String {
        if let secondary, !secondary.isEmpty { return "\(primary) (\(secondary))" }
        return primary
    }

    static func formatImportTargetLabel(spaceName: String, profileName: String?) -> String {
        formatNameWithParenthetical(primary: spaceName, secondary: profileName)
    }

    private func refreshTargetLabel() {
        guard isViewLoaded, displayMode == .normal else { return }
        let space = SpaceManager.shared.spaces.first { $0.spaceId == targetSpaceId }
        let profileName = ProfileManager.shared.profile(for: targetProfileId)?.displayName
        let spaceName = space?.name ?? NSLocalizedString("oobe.importBrowserData.target.currentSpaceFallback", value: "Current Space",
            comment: "Fallback label for the import-target Space when it can't be resolved by id"
        )
        targetHostingView.rootView = ImportTargetView(
            iconStoredValue: space?.iconName,
            text: Self.formatImportTargetLabel(spaceName: spaceName, profileName: profileName)
        )
    }
    /// Browsers configured inline (≥1 data type selected via the accordion).
    private(set) var configuredBrowsers: Set<BrowserType> = []
    /// Selected data types per browser, edited inline by the accordion toggles.
    /// Single source of truth for what gets imported (projected by `dataTypesPerBrowser`).
    private var selectedTypesPerBrowser: [BrowserType: Set<ImportDataType>] = [:]
    /// Inline toggle rows + their collapsible containers, keyed by browser, so a
    /// row can be reset (on profile change) and expanded/collapsed.
    private var toggleRowsPerBrowser: [BrowserType: [DataTypeToggleRow]] = [:]
    private var toggleContainersPerBrowser: [BrowserType: NSStackView] = [:]
    /// The single currently-expanded browser (single-open accordion), or nil.
    private var expandedBrowser: BrowserType?
    private var chromeProfiles: [BrowserDataImporter.ChromiumProfileInfo] = []
    private var selectedChromeProfile: BrowserDataImporter.ChromiumProfileInfo?
    private var arcSpaces: [ArcSpace] = []
    private var selectedArcSpaceIndex: Int?
    private var selectedArcSpace: ArcSpace? {
        guard let i = selectedArcSpaceIndex, arcSpaces.indices.contains(i) else { return nil }
        return arcSpaces[i]
    }
    /// The file chosen for file-based import (v1: a bookmarks HTML file), or nil.
    private var selectedImportFileURL: URL?
    
    private lazy var permisionImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = .permission
        imageView.isHidden = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        return imageView
    }()
    
    private lazy var desLabel: NSTextField = {
        let label = NSTextField(labelWithString: NSLocalizedString("oobe.importBrowserData.permission.fullDiskAccessDescription", value: "Phi needs Full Disk Access to import your data from Safari.", comment: "Import browser data page - Description explaining why Full Disk Access permission is needed"))
        label.textColor = NSColor.white
        label.font = NSFont.systemFont(ofSize: descriptionFontSize)
        label.isHidden = true
        return label
    }()
    
    private var containerWidth: CGFloat { displayMode == .login ? 472 : 396 }
    private var containerLeftOffset: CGFloat { displayMode == .login ? 84 : 52 }
    private let containerCornerRadius: CGFloat = 14
    private let containerPadding: CGFloat = 8
    private let optionSpacing: CGFloat = 8

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var browserOptionsStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()
    
    private lazy var chromeOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .chromeIcon,
            title: NSLocalizedString("oobe.importBrowserData.source.chromeOption", value: "From Chrome", comment: "Import browser data page - Option label to import data from Chrome browser"),
            isSelected: false
        )
        view.onTap = { [weak self] in
            self?.toggleExpansion(.chrome)
        }
        view.onProfileSelection = { [weak self] index in
            guard let self, index >= 0, index < self.chromeProfiles.count else {
                return
            }
            let newProfile = self.chromeProfiles[index]
            if self.selectedChromeProfile?.directory != newProfile.directory {
                self.selectedChromeProfile = newProfile
                self.resetToggles(for: .chrome)
            }
        }
        
        view.wantsLayer = true
        return view
    }()
    
    private lazy var safariOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .safariIcon,
            title: NSLocalizedString("oobe.importBrowserData.source.safariOption", value: "From Safari", comment: "Import browser data page - Option label to import data from Safari browser"),
            isSelected: false
        )
        
        view.wantsLayer = true
        
        view.onTap = { [weak self] in
            self?.toggleExpansion(.safari)
        }
        return view
    }()
    
    private lazy var arcOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .arcIcon,
            title: NSLocalizedString("oobe.importBrowserData.source.arcOption", value: "From Arc", comment: "Import browser data page - Option label to import data from Arc browser"),
            isSelected: false
        )
        
        view.wantsLayer = true

        view.onTap = { [weak self] in
            self?.toggleExpansion(.arc)
        }
        view.onProfileSelection = { [weak self] index in
            guard let self, self.arcSpaces.indices.contains(index) else { return }
            // Ignore re-selecting the already-chosen Space (NSMenu fires the action
            // regardless), so it doesn't needlessly reset the configured state — matches Chrome.
            guard self.selectedArcSpaceIndex != index else { return }
            self.selectedArcSpaceIndex = index
            self.resetToggles(for: .arc)
        }
        return view
    }()

    /// Header for the file-import accordion row. Unlike the browser rows it has no
    /// profile selector and no per-type toggles; its body is a file picker. The row
    /// is always shown (the user may have a file to import regardless of installed
    /// browsers). The title stays generic ("From a file"); the picker accepts the
    /// supported sources: Bookmarks HTML, Safari History JSON, and Safari Export
    /// Archive (ZIP).
    private lazy var fileOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: Self.fileRowIcon(),
            title: NSLocalizedString("oobe.importBrowserData.source.fileOption", value: "From a file", comment: "Import browser data page - Option label to import data from a file"),
            isSelected: false
        )
        view.wantsLayer = true
        view.onTap = { [weak self] in
            self?.toggleExpansion(.file)
        }
        return view
    }()

    /// Shows the chosen import file's name, or a placeholder before one is picked.
    private lazy var fileNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: Self.noFileSelectedText)
        label.font = NSFont.systemFont(ofSize: optionFontSize, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private static var noFileSelectedText: String {
        NSLocalizedString("oobe.importBrowserData.filePicker.emptySelectionPlaceholder", value: "No file selected", comment: "Import browser data page - Placeholder when no file has been chosen for import yet")
    }

    /// A colored, app-icon-style tile for the file-import row so it sits next to the
    /// full-color browser icons (Chrome/Safari/Arc) as a peer instead of a flat
    /// monochrome glyph: a white document symbol on a rounded blue gradient tile.
    private static func fileRowIcon() -> NSImage {
        let side: CGFloat = 32
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            let base = NSColor.systemBlue
            let top = base.blended(withFraction: 0.3, of: .white) ?? base
            NSGradient(starting: top, ending: base)?.draw(in: tile, angle: -90)

            let glyphConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(glyphConfig) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - g.width / 2,
                                      y: rect.midY - g.height / 2,
                                      width: g.width,
                                      height: g.height))
            }
            return true
        }
    }

    private lazy var importStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = NSColor.white
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        label.isHidden = true
        return label
    }()
    
    private var cancelables = Set<AnyCancellable>()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setTitle(NSLocalizedString("oobe.importBrowserData.initialTitle", value: "Browser data", comment: "Import browser data page - Initial page title"))
        applyDisplayModeLayout()
        setupBrowserOptions()
        updateNextButtonState()
        
        importer.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else {
                    return
                }
                if phase != .done && phase != .waiting {
                    nextButton.isEnabled = false
                    skipButton.isEnabled = false
                }
        }
            .store(in: &cancelables)
        
        importer.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateImportStatus(status)
            }
            .store(in: &cancelables)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKeyAndOrderFront(nil)
    }
    
    private func updateImportStatus(_ status: String) {
        importStatusLabel.stringValue = status
        importStatusLabel.isHidden = status.isEmpty
    }
    
    private func setupBrowserOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(browserOptionsStackView)
        view.addSubview(importStatusLabel)
        view.addSubview(permisionImageView)
        view.addSubview(desLabel)

        if displayMode == .normal {
            view.addSubview(targetHostingView)
            targetHostingView.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.top.equalTo(titleLabel.snp.bottom).offset(12)
                make.width.lessThanOrEqualTo(optionWidth)
            }
            refreshTargetLabel()
        }

        applyOptionViewStyle(chromeOptionView)
        applyOptionViewStyle(safariOptionView)
        applyOptionViewStyle(arcOptionView)
        applyOptionViewStyle(fileOptionView)

        let hasChrome = hasChromeData()
        let hasArc = hasArcData()
        if hasChrome {
            browserOptionsStackView.addArrangedSubview(makeAccordionWrapper(header: chromeOptionView, browser: .chrome))
            refreshChromeProfilesIfNeeded()
        }

        if hasArc {
            browserOptionsStackView.addArrangedSubview(makeAccordionWrapper(header: arcOptionView, browser: .arc))
            refreshArcSpacesIfNeeded()
        }

        browserOptionsStackView.addArrangedSubview(makeAccordionWrapper(header: safariOptionView, browser: .safari))

        // File import is always available: the user may have a bookmarks HTML file
        // regardless of which browsers are installed. Added last, after the browsers.
        browserOptionsStackView.addArrangedSubview(makeAccordionWrapper(header: fileOptionView, browser: .file))

        optionsContainer.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(containerLeftOffset)
            make.width.equalTo(containerWidth)
            if displayMode == .normal {
                // Centered when short; when a row expands the card outgrows the
                // centered band, so yield centerY (lower priority) and pin the top
                // just below the target caption so it never rides up over it. The
                // bottom is freed by collapsing the open row on Next (Step 5), so an
                // in-flight import's status label never reaches the Next button.
                make.centerY.equalToSuperview().priority(.medium)
                make.top.greaterThanOrEqualTo(targetHostingView.snp.bottom).offset(8)
            } else {
                make.centerY.equalToSuperview()
            }
        }

        browserOptionsStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(containerPadding)
        }

        importStatusLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(optionsContainer.snp.bottom).offset(16)
            make.width.lessThanOrEqualTo(optionWidth)
        }
        
        permisionImageView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.size.equalTo(NSSize(width: permissionImageWidth, height: permissionImageHeight))
            make.top.equalToSuperview().offset(permissionImageTopOffset)
        }
        
        desLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
        }
    }
    
    private func applyOptionViewStyle(_ optionView: BrowserOptionView) {
        optionView.applyStyle(iconSize: optionIconSize, fontSize: optionFontSize)
    }
    
    /// Projects the inline per-browser selections into the Chromium bridge wire
    /// format. A browser with an empty set is omitted; an all-empty input yields
    /// nil. rawValues are sorted for deterministic output. `nil`/missing key means
    /// "import all" downstream (BrowserDataImporter.swift:116).
    static func projectDataTypes(_ selected: [BrowserType: Set<ImportDataType>]) -> [BrowserType: [String]]? {
        let dict = selected.reduce(into: [BrowserType: [String]]()) { acc, pair in
            guard !pair.value.isEmpty else { return }
            acc[pair.key] = pair.value.map { $0.rawValue }.sorted()
        }
        return dict.isEmpty ? nil : dict
    }

    private func handleToggle(browser: BrowserType, dataType: ImportDataType, isOn: Bool) {
        if isOn {
            selectedTypesPerBrowser[browser, default: []].insert(dataType)
        } else {
            selectedTypesPerBrowser[browser]?.remove(dataType)
        }
        if selectedTypesPerBrowser[browser]?.isEmpty ?? true {
            unmarkBrowserConfigured(browser)
        } else {
            markBrowserConfigured(browser)
        }
    }

    /// Resets a browser's inline selection (its toggles + configured state) after
    /// the user picks a different Chrome profile / Arc Space — the old selection
    /// belonged to the previous profile. The row stays expanded.
    private func resetToggles(for browser: BrowserType) {
        selectedTypesPerBrowser[browser] = nil
        toggleRowsPerBrowser[browser]?.forEach { $0.setOn(false) }
        unmarkBrowserConfigured(browser)
    }

    private func headerView(for browser: BrowserType) -> BrowserOptionView {
        switch browser {
        case .chrome: return chromeOptionView
        case .arc: return arcOptionView
        case .file: return fileOptionView
        default: return safariOptionView
        }
    }

    /// Toggles this browser's accordion body. Single-open: expanding one row
    /// collapses any other open row.
    private func toggleExpansion(_ browser: BrowserType) {
        // Lock the accordion while an import is in flight: the page stays interactive
        // during the async import, and expanding a row would re-grow the card (pushing
        // the status label onto Next) and re-enable Next via the toggle path.
        guard !importer.isImporting else { return }
        let willExpand = (expandedBrowser != browser)
        if let current = expandedBrowser, current != browser {
            setExpanded(current, expanded: false, animated: true)
        }
        setExpanded(browser, expanded: willExpand, animated: true)
        expandedBrowser = willExpand ? browser : nil
    }

    private func setExpanded(_ browser: BrowserType, expanded: Bool, animated: Bool = false) {
        headerView(for: browser).setExpanded(expanded)
        guard let container = toggleContainersPerBrowser[browser] else { return }
        guard animated else {
            container.isHidden = !expanded
            return
        }
        // Animate the body show/hide plus the resulting card reflow (lower rows
        // slide). A vertical NSStackView excludes a hidden arranged subview, so
        // animating its `isHidden` via the animator proxy inside an implicit-
        // animation group fades the body and animates the surrounding relayout.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            container.animator().isHidden = !expanded
            self.view.layoutSubtreeIfNeeded()
        }
    }

    /// Builds one accordion cell: the browser header stacked above a collapsible
    /// container of per-type toggle rows. The container starts hidden; a vertical
    /// NSStackView excludes hidden arranged subviews, so showing/hiding it reflows
    /// the card. The fixed header height lives here (on the header inside the
    /// wrapper) so the wrapper itself sizes to its content.
    private func makeAccordionWrapper(header: BrowserOptionView, browser: BrowserType) -> NSStackView {
        header.snp.makeConstraints { make in
            make.width.equalTo(optionWidth)
            make.height.equalTo(optionHeight)
        }

        let toggleContainer = NSStackView()
        toggleContainer.orientation = .vertical
        toggleContainer.spacing = optionSpacing
        toggleContainer.alignment = .centerX
        toggleContainer.distribution = .fill
        toggleContainer.isHidden = true

        var rows: [DataTypeToggleRow] = []
        if browser == .file {
            // The file row has no per-type toggles; its body is a file picker.
            let pickerBody = makeFilePickerBody()
            toggleContainer.addArrangedSubview(pickerBody)
            pickerBody.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
                make.height.equalTo(toggleRowHeight)
            }
        } else {
            for dataType in ImportDataType.availableTypes(for: browser) {
                let row = DataTypeToggleRow(title: dataType.displayName, isOn: false)
                row.onToggle = { [weak self] isOn in
                    self?.handleToggle(browser: browser, dataType: dataType, isOn: isOn)
                }
                toggleContainer.addArrangedSubview(row)
                row.snp.makeConstraints { make in
                    make.width.equalTo(optionWidth)
                    make.height.equalTo(toggleRowHeight)
                }
                rows.append(row)
            }
        }

        // Safari keeps its history/bookmarks databases locked while it is running,
        // so remind the user to quit Safari first. Sits just under the toggles,
        // inside the collapsible body so it shows/hides with the accordion.
        if browser == .safari {
            let hint = makeSafariImportHint()
            toggleContainer.addArrangedSubview(hint)
            hint.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
            }
        }

        toggleRowsPerBrowser[browser] = rows
        toggleContainersPerBrowser[browser] = toggleContainer

        let wrapper = NSStackView()
        wrapper.orientation = .vertical
        wrapper.spacing = optionSpacing
        wrapper.alignment = .centerX
        wrapper.distribution = .fill
        // Load-bearing: the accordion collapse relies on the hidden toggleContainer
        // being EXCLUDED from layout (a collapsed row is just its header height).
        // detachesHiddenViews already defaults to true; set it explicitly so the
        // dependency is documented (matches BookmarkBar.swift's explicit setting).
        wrapper.detachesHiddenViews = true
        wrapper.addArrangedSubview(header)
        wrapper.addArrangedSubview(toggleContainer)

        wrapper.snp.makeConstraints { make in
            make.width.equalTo(optionWidth)
        }
        toggleContainer.snp.makeConstraints { make in
            make.width.equalTo(optionWidth)
        }
        return wrapper
    }

    /// Builds the small reminder caption shown under Safari's toggle rows: Safari
    /// keeps its history/bookmarks databases locked while running, so the user
    /// should quit it before importing. Inset on both sides to match the toggle
    /// rows, muted, and wraps when the localized string is long.
    private func makeSafariImportHint() -> NSView {
        // Matches the toggle rows' 18pt horizontal inset (DataTypeToggleRow /
        // BrowserOptionView express the same value as their own horizontalPadding).
        let horizontalPadding: CGFloat = 18
        let container = NSView()

        let label = NSTextField(wrappingLabelWithString: NSLocalizedString("oobe.importBrowserData.safari.quitReminder", value: "Please quit Safari before importing its data.",
            comment: "Import browser data page - Reminder to quit Safari before importing so its data can be read"
        ))
        label.font = NSFont.systemFont(ofSize: hintFontSize)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.isSelectable = false

        container.addSubview(label)
        label.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.top.bottom.equalToSuperview()
        }
        return container
    }

    /// Builds the file row's collapsible body: a filename label + a "Choose File…"
    /// button. Picking a file marks `.file` configured; there are no per-type toggles.
    private func makeFilePickerBody() -> NSView {
        // Matches the toggle rows' 18pt horizontal inset, which DataTypeToggleRow /
        // BrowserOptionView express as a named `horizontalPadding`. The button's own
        // sizes mirror ProfileSelectionButton, whose values are inline — kept inline.
        let horizontalPadding: CGFloat = 18
        let row = NSView()

        let chooseButton = NSButton(
            title: NSLocalizedString("oobe.importBrowserData.importButton", value: "Choose File…", comment: "Import browser data page - Button to pick a file to import"),
            target: self,
            action: #selector(chooseImportFile(_:))
        )
        chooseButton.isBordered = false
        chooseButton.wantsLayer = true
        chooseButton.contentTintColor = .white
        chooseButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        chooseButton.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.6).cgColor
        chooseButton.layer?.cornerRadius = 8

        row.addSubview(fileNameLabel)
        row.addSubview(chooseButton)

        fileNameLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
        }
        chooseButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.left.greaterThanOrEqualTo(fileNameLabel.snp.right).offset(12)
            make.width.equalTo(110)
            make.height.equalTo(28)
        }
        return row
    }

    /// Opens a file picker limited to the supported import sources — Bookmarks HTML
    /// (UTType `.html` also matches `.htm`), Safari History JSON, and Safari Export
    /// Archive (ZIP) — and records the chosen file. Selecting a file marks `.file`
    /// configured. The Mac side does no parsing — the path is handed to Chromium at
    /// import time, which classifies it by extension.
    @objc private func chooseImportFile(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .json, .zip]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.selectedImportFileURL = url
            self.fileNameLabel.stringValue = url.lastPathComponent
            self.fileNameLabel.textColor = .white
            self.markBrowserConfigured(.file)
        }
    }

    /// Resets the file-import selection to its "nothing chosen" state (clears the
    /// picked URL and restores the placeholder label). Shared by the label's initial
    /// state and `resetForReuse`.
    private func resetImportFileSelection() {
        selectedImportFileURL = nil
        fileNameLabel.stringValue = Self.noFileSelectedText
        fileNameLabel.textColor = NSColor.white.withAlphaComponent(0.7)
    }

    /// Marks a browser configured; called by handleToggle when its inline selection becomes non-empty.
    private func markBrowserConfigured(_ browser: BrowserType) {
        configuredBrowsers.insert(browser)
        updateConfiguredAppearance()
        updateNextButtonState()
    }

    /// Clears a browser's configured state; called by handleToggle/resetToggles when its selection empties or its profile/Space changes.
    private func unmarkBrowserConfigured(_ browser: BrowserType) {
        configuredBrowsers.remove(browser)
        updateConfiguredAppearance()
        updateNextButtonState()
    }

    private func updateConfiguredAppearance() {
        chromeOptionView.setConfigured(configuredBrowsers.contains(.chrome))
        safariOptionView.setConfigured(configuredBrowsers.contains(.safari))
        arcOptionView.setConfigured(configuredBrowsers.contains(.arc))
        fileOptionView.setConfigured(configuredBrowsers.contains(.file))
    }

    private func updateNextButtonState() {
        nextButton.isEnabled = !configuredBrowsers.isEmpty
        nextButton.alphaValue = configuredBrowsers.isEmpty ? 0.5 : 1.0
    }
    
    private func applyDisplayModeLayout() {
        view.snp.remakeConstraints { make in
            make.width.equalTo(viewWidth)
            make.height.equalTo(viewHeight)
        }
        
        setTitle(titleLabel.stringValue, size: titleFontSize)
        titleLabel.snp.remakeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(titleTopOffset)
        }
        
        nextButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
        
        if displayMode == .login {
            skipButton.snp.remakeConstraints { make in
                make.top.equalTo(nextButton.snp.bottom).offset(8)
                make.centerX.equalToSuperview()
            }
        } else {
            skipButton.isHidden = true
        }
    }
    
    /// A lightweight check to infer whether the app has Full Disk Access.
    /// We try to see if a Safari data file is readable. If not, we assume
    /// Full Disk Access has not been granted yet.
    private func hasFullDiskAccess() -> Bool {
        let homeDirectory = NSHomeDirectory()
        let safariHistoryPath = (homeDirectory as NSString).appendingPathComponent("Library/Safari/History.db")
        return FileManager.default.isReadableFile(atPath: safariHistoryPath)
    }
    
    private func hasChromeData () -> Bool {
        let library = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0] as NSString
        let chromePath = library.appendingPathComponent("Google/Chrome")
        return FileManager.default.fileExists(atPath: chromePath)
    }
    
    private func hasArcData () -> Bool {
        let library = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0] as NSString
        let chromePath = library.appendingPathComponent("Arc/User Data")
        return FileManager.default.fileExists(atPath: chromePath)
    }


    private func refreshChromeProfilesIfNeeded() {
        guard hasChromeData() else {
            chromeOptionView.setProfileSelectorVisible(false)
            return
        }
        chromeProfiles = importer.loadChromiumProfiles()
        if chromeProfiles.count > 1 {
            chromeOptionView.setProfileSelectorVisible(true)
            let names = chromeProfiles.map { $0.name }
            let menuTitles = chromeProfiles.map { chromeProfileMenuTitle($0) }
            let selectedIndex = selectedChromeProfileIndex(in: chromeProfiles) ?? 0
            chromeOptionView.updateProfileOptions(
                buttonTitles: names,
                menuTitles: menuTitles,
                selectedIndex: selectedIndex
            )
            selectedChromeProfile = chromeProfiles[selectedIndex]
        } else if chromeProfiles.count == 1 {
            chromeOptionView.setProfileSelectorVisible(false)
            selectedChromeProfile = chromeProfiles.first
        } else {
            chromeOptionView.setProfileSelectorVisible(false)
            selectedChromeProfile = nil
        }
    }

    private func arcProfileDisplayNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data/Local State")
        var map: [String: String] = [:]
        for p in importer.loadChromiumProfiles(localStateURL: url) { map[p.directory] = p.name }
        return map
    }

    private func refreshArcSpacesIfNeeded() {
        guard hasArcData() else {
            arcOptionView.setProfileSelectorVisible(false)
            return
        }
        arcSpaces = importer.loadArcSpaces()
        let profileNames = arcProfileDisplayNames()
        if arcSpaces.count > 1 {
            arcOptionView.setEnabled(true)
            arcOptionView.setProfileSelectorVisible(true)
            let buttonTitles = arcSpaces.map { $0.title }
            let menuTitles = arcSpaces.map { space -> String in
                let secondary = space.profile.directoryName.flatMap { profileNames[$0] }
                    ?? space.profile.directoryName
                return Self.formatNameWithParenthetical(primary: space.title, secondary: secondary)
            }
            arcOptionView.updateProfileOptions(buttonTitles: buttonTitles, menuTitles: menuTitles, selectedIndex: 0)
            selectedArcSpaceIndex = 0
        } else if arcSpaces.count == 1 {
            arcOptionView.setEnabled(true)
            arcOptionView.setProfileSelectorVisible(false)
            selectedArcSpaceIndex = 0
        } else {
            arcOptionView.setProfileSelectorVisible(false)
            arcOptionView.setEnabled(false)        // no Spaces → nothing to import
            selectedArcSpaceIndex = nil
        }
    }

    private func chromeProfileMenuTitle(_ profile: BrowserDataImporter.ChromiumProfileInfo) -> String {
        guard let email = profile.email, !email.isEmpty else {
            return profile.name
        }
        return "\(profile.name) (\(email))"
    }

    private func selectedChromeProfileIndex(in profiles: [BrowserDataImporter.ChromiumProfileInfo]) -> Int? {
        guard let selected = selectedChromeProfile else {
            return nil
        }
        return profiles.firstIndex { $0.directory == selected.directory }
    }

    private func showPermissionView() {
        optionsContainer.isHidden = true
        importStatusLabel.isHidden = true
        // The standalone target caption sits just under the title, where the
        // permission explanation (`desLabel`) also goes — hide it on this screen
        // so the two don't overlap. The flow proceeds to import (never back to
        // the selection screen) afterwards, so it needn't be restored.
        if displayMode == .normal {
            targetHostingView.isHidden = true
        }
        permisionImageView.isHidden = false
        browserOptionsStackView.isHidden = true
        setTitle(NSLocalizedString("oobe.importBrowserData.permission.title", value: "Permissions", comment: "Import browser data page - Page title when showing permission request"))
        desLabel.isHidden = false
        nextButton.title = NSLocalizedString("oobe.importBrowserData.permission.openSettingsButton", value: "Open Settings", comment: "Import browser data page - Button to open system settings for granting permissions")
        phase = .permision
        nextButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
            make.width.equalTo(148)
            make.height.equalTo(40)
        }
    }

    /// Inverse of `showPermissionView()`: restores the browser-selection screen.
    /// The standalone singleton reuses the same VC, so a window closed on the
    /// Full-Disk-Access permission screen must reopen on the selection screen rather
    /// than stranded on the permission dead-end. Called from `resetForReuse`.
    private func showSelectionView() {
        phase = .importor
        optionsContainer.isHidden = false
        browserOptionsStackView.isHidden = false
        if displayMode == .normal {
            targetHostingView.isHidden = false
        }
        permisionImageView.isHidden = true
        desLabel.isHidden = true
        importStatusLabel.isHidden = true
        setTitle(NSLocalizedString("oobe.importBrowserData.resetTitle", value: "Browser data", comment: "Import browser data page - Page title restored after resetting the import state"))
        nextButton.title = NSLocalizedString("oobe.importBrowserData.nextButton", value: "Next", comment: "Import browser data page - Next button after resetting the import state")
        nextButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
    }

    private func openFullDiskAccessSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Collapses any expanded accordion row (single-open invariant). Called before
    /// import so the card shrinks back and the status label clears the Next button.
    private func collapseAll() {
        guard let current = expandedBrowser else { return }
        setExpanded(current, expanded: false)
        expandedBrowser = nil
    }

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        collapseAll()
        if phase == .permision, !hasFullDiskAccess() {
            openFullDiskAccessSettings()
            return
        } else if phase == .importor,
                  configuredBrowsers.contains(.safari),
                  !hasFullDiskAccess() {
            showPermissionView()
            return
        }

        // Reset phase after FDA was granted so import can proceed
        phase = .importor

        if !configuredBrowsers.isEmpty {
            Task {
                // A repeat trigger (e.g. rapid double-click) is ignored by the
                // importer's reentrancy guard, which returns false; only advance
                // the UI when this call actually started the import, so the window
                // is not closed out from under the in-flight one.
                let didStart = await importer.startImportData(
                    Array(configuredBrowsers),
                    chromeProfileDirectory: selectedChromeProfile?.directory,
                    arcSpace: configuredBrowsers.contains(.arc) ? selectedArcSpace : nil,
                    dataTypesPerBrowser: dataTypesPerBrowser,
                    importFilePath: selectedImportFileURL?.path
                )
                guard didStart else { return }
                await MainActor.run {
                    onCompletion?()
                }
            }
        } else {
            onCompletion?()
        }
    }
}

class BrowserOptionView: NSView {
    var onTap: (() -> Void)?
    var onProfileSelection: ((Int) -> Void)?
    private var isSelected: Bool
    private var isEnabledRow = true
    
    private let iconImageView: NSImageView
    private let titleLabel: NSTextField
    private let chevronImageView: NSImageView
    private let profileSelectorButton: ProfileSelectionButton
    private var profileButtonTitles: [String] = []
    private var selectedProfileIndex: Int = 0
    var configuredColor = NSColor.white.withAlphaComponent(0.1)
    var normalColor = NSColor.clear
   
    init(icon: NSImage, title: String, isSelected: Bool) {
        self.isSelected = isSelected
        self.iconImageView = NSImageView(image: icon)
        
        self.titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = .white
        
        self.chevronImageView = NSImageView()
        if let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            chevronImageView.image = chevronImage.withSymbolConfiguration(config)
        }
        chevronImageView.contentTintColor = .white
        self.profileSelectorButton = ProfileSelectionButton(title: "Profile")
        profileSelectorButton.isHidden = true
        
        super.init(frame: .zero)
        
        setupUI()
        updateAppearance()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private let horizontalPadding: CGFloat = 18
    private let iconToTitleSpacing: CGFloat = 16
    private let chevronSize: CGFloat = 24
    private let cornerRadius: CGFloat = 8

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(chevronImageView)
        addSubview(profileSelectorButton)

        iconImageView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(iconImageView.image?.size.width ?? 32)
        }

        titleLabel.snp.makeConstraints { make in
            make.left.equalTo(iconImageView.snp.right).offset(iconToTitleSpacing)
            make.centerY.equalToSuperview()
        }

        chevronImageView.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(chevronSize)
        }

        profileSelectorButton.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.right.equalTo(chevronImageView.snp.left).offset(-12)
        }
        
        profileSelectorButton.setContentHuggingPriority(.required, for: .horizontal)
        profileSelectorButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        profileSelectorButton.target = self
        profileSelectorButton.action = #selector(showProfileMenu(_:))
        
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabledRow = enabled
        alphaValue = enabled ? 1.0 : 0.4
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabledRow else { return }
        onTap?()
    }

    func setConfigured(_ configured: Bool) {
        isSelected = configured
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected ? configuredColor.cgColor : normalColor.cgColor
    }
    
    func setProfileSelectorVisible(_ visible: Bool) {
        profileSelectorButton.isHidden = !visible
    }

    /// Disclosure state: chevron points right when collapsed, down when expanded.
    func setExpanded(_ expanded: Bool) {
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            chevronImageView.image = image.withSymbolConfiguration(config)
        }
    }

    func applyStyle(iconSize: CGFloat, fontSize: CGFloat) {
        iconImageView.snp.updateConstraints { make in
            make.width.height.equalTo(iconSize)
        }
        titleLabel.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
    }
    
    func updateProfileOptions(buttonTitles: [String], menuTitles: [String], selectedIndex: Int) {
        profileButtonTitles = buttonTitles
        selectedProfileIndex = max(0, min(selectedIndex, buttonTitles.count - 1))
        let menu = NSMenu()
        for (index, title) in menuTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(profileMenuItemSelected(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = (index == selectedProfileIndex) ? .on : .off
            menu.addItem(item)
        }
        profileSelectorButton.menu = menu
        if selectedProfileIndex >= 0 && selectedProfileIndex < buttonTitles.count {
            profileSelectorButton.title = buttonTitles[selectedProfileIndex]
        }
    }
    
    @objc private func showProfileMenu(_ sender: NSButton) {
        guard let menu = profileSelectorButton.menu else {
            return
        }
        for item in menu.items {
            item.state = (item.tag == selectedProfileIndex) ? .on : .off
        }
        let location = NSPoint(x: 0, y: profileSelectorButton.bounds.height + 4)
        let selectedItem = menu.item(at: selectedProfileIndex)
        menu.popUp(positioning: selectedItem, at: location, in: profileSelectorButton)
    }
    
    @objc private func profileMenuItemSelected(_ sender: NSMenuItem) {
        let index = sender.tag
        selectedProfileIndex = index
        if index >= 0 && index < profileButtonTitles.count {
            profileSelectorButton.title = profileButtonTitles[index]
        }
        onProfileSelection?(index)
    }
}

final class ProfileSelectionButton: NSButton {
    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let padding = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    private let chevronSymbolName = "chevron.down"
    private let chevronPointSize: CGFloat = 10
    private let titleImageSpacing: CGFloat = 6
    
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            updateAttributedTitle()
            updateChevronImage()
            needsDisplay = true
        }
    }
    
    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        let size = (title as NSString).size(withAttributes: attributes)
        let imageWidth = image?.size.width ?? 0
        let spacing = imageWidth > 0 ? titleImageSpacing : 0
        let width = size.width + padding.left + padding.right + spacing + imageWidth + 2
        return NSSize(
            width: min(width, 120),
            height: max(size.height, image?.size.height ?? 0) + padding.top + padding.bottom
        )
    }
    
    private func commonInit() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.6).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        
        imagePosition = .imageRight
        imageScaling = .scaleProportionallyDown

        let profileCell = ProfileSelectionButtonCell(padding: padding, titleImageSpacing: titleImageSpacing)
        profileCell.font = titleFont
        cell = profileCell
        
        updateAttributedTitle()
        updateChevronImage()
    }
    
    private func updateAttributedTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }
    
    private func updateChevronImage() {
        let titleColor: NSColor
        if attributedTitle.length > 0,
           let color = attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            titleColor = color
        } else {
            titleColor = .white
        }
        image = NSImage.configureSymbolImage(
            systemName: chevronSymbolName,
            pointSize: chevronPointSize,
            weight: .medium,
            color: titleColor
        )
    }
}

final class ProfileSelectionButtonCell: NSButtonCell {
    private let padding: NSEdgeInsets
    private let titleImageSpacing: CGFloat
    
    init(padding: NSEdgeInsets, titleImageSpacing: CGFloat) {
        self.padding = padding
        self.titleImageSpacing = titleImageSpacing
        super.init(textCell: "")
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let imageWidth = image?.size.width ?? 0
        let spacing = imageWidth > 0 ? titleImageSpacing : 0
        
        let availableWidth = max(0, rect.width - padding.left - padding.right - imageWidth - spacing)
        let titleSize = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)])
        let width = min(titleSize.width, availableWidth)
        let height = titleSize.height
        let x = rect.minX + padding.left
        let y = rect.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else {
            return .zero
        }
        let titleRect = titleRect(forBounds: rect)
        let xIdeal = titleRect.maxX + titleImageSpacing
        let xMax = rect.maxX - padding.right - image.size.width
        let x = min(xIdeal, xMax)
        let y = rect.midY - image.size.height / 2
        return NSRect(x: x, y: y, width: image.size.width, height: image.size.height)
    }
}

class OnboardingBaseViewController: NSViewController {
    var nextClosure: ((Bool) -> Void)?
    
    // MARK: - Video Background
    private var videoPlayer: AVPlayer?
    private var videoPlayerLayer: AVPlayerLayer?
    private var loopObserver: Any?
    
    /// If true, will try to make window center
    var isFisrtPage = false
    
    // Placeholder to hide gray flash while video loads
    private var placeholderView: NSImageView = {
        let image = NSImage(resource: .loginWallpaper)
        let imageView = NSImageView(image: image)
        return imageView
    }()
    
    var dotView: NSImageView = {
        let dot = NSImage(resource: .dotBg)
        let imageView = NSImageView(image: dot)
        imageView.alphaValue = 0.08
        return imageView
    }()
            
    /// The onboarding title's brand face and its default size. The face is
    /// Latin-only, so titles go through `setTitle` rather than assigning
    /// `titleLabel.stringValue` directly — see `NSFont.brandDisplay`.
    static let titleFontName = "IvyPrestoDisplay-SemiBoldItalic"
    static let defaultTitleFontSize: CGFloat = 46

    var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont(name: OnboardingBaseViewController.titleFontName,
                            size: OnboardingBaseViewController.defaultTitleFontSize)
        label.textColor = .white
        label.alignment = .center
        return label
    }()

    /// Sets the page title along with a face that can actually draw it. The
    /// brand face carries no CJK glyphs, and on macOS 15 the system fallback
    /// draws those runs clipped — every localized title lost the top of its
    /// characters. Keep the two assignments together: setting `stringValue`
    /// alone reintroduces the bug for any script the brand face lacks.
    func setTitle(_ title: String, size: CGFloat = OnboardingBaseViewController.defaultTitleFontSize) {
        titleLabel.stringValue = title
        titleLabel.font = .brandDisplay(Self.titleFontName, size: size, renders: title)
    }
    
    lazy var nextButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("oobe.navigation.continueButton", value: "Next", comment: "OOBE navigation - Button to continue to the next step")
        button.clickAction = { [weak self] in
            self?.nextButtonTapped()
        }
        return button
    }()
    
    lazy var skipButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = NSLocalizedString("oobe.navigation.skipButton", value: "Skip", comment: "Onboarding base - Skip button to bypass current step")
        button.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        button.contentTintColor = NSColor.gray
        button.target = self
        button.action = #selector(skipButtonTapped(_:))
        return button
    }()
    
    @objc func skipButtonTapped(_ sender: NSButton) {
        nextClosure?(false)
    }
       
    
    @objc func nextButtonTapped(_ sender: NSButton? = nil) {
        nextClosure?(true)
    }
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addSubview(placeholderView)
        view.addSubview(dotView)
        view.addSubview(titleLabel)
        view.addSubview(nextButton)
        view.addSubview(skipButton)
        
        // Set fixed size for the view
        view.snp.makeConstraints { make in
            make.width.equalTo(640)
            make.height.equalTo(800)
        }
        
        // Constraint-built aspect-fill for the two 640×800 (4:5) bitmap layers.
        // At exactly 4:5 (OOBE's 640×800) this is pixel-identical to edge-pinning;
        // at any other ratio (the 500×700 standalone import window) the images
        // cover the view at 4:5 and crop, instead of letterboxing and exposing
        // bands of the bare video layer beneath.
        for background in [placeholderView, dotView] {
            background.imageScaling = .scaleProportionallyUpOrDown
            background.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalTo(background.snp.height).multipliedBy(640.0 / 800.0)
                make.width.greaterThanOrEqualToSuperview()
                make.height.greaterThanOrEqualToSuperview()
                make.height.equalToSuperview().priority(.high)
            }
        }
        
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(96)
        }
        
        nextButton.snp.makeConstraints { make in
            make.bottom.equalToSuperview().offset(-96)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
    
        skipButton.snp.makeConstraints { make in
            make.top.equalTo(nextButton.snp.bottom).offset(8)
            make.centerX.equalToSuperview()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupVideoBackground()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        startVideoPlayback()
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopVideoPlayback()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        if isFisrtPage {
            view.window?.center()
        }
    }
    
    // MARK: - Video Background
    private var statusObservation: NSKeyValueObservation?
    
    private func setupVideoBackground() {
        guard videoPlayer == nil else { return }
        
        guard let url = Bundle.main.url(forResource: "login-dot-bg", withExtension: "mp4") else {
            return
        }
        
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        
        // Observe player item status to know when first frame is ready
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .readyToPlay {
                DispatchQueue.main.async {
                    // Fade out placeholder when video is ready
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.3
                        self.placeholderView.animator().alphaValue = 0
                    } completionHandler: {
                        self.placeholderView.isHidden = true
                    }
                }
            }
        }
        
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill
        
        if let rootLayer = view.layer {
            rootLayer.insertSublayer(layer, at: 0)
        }
        
        self.videoPlayer = player
        self.videoPlayerLayer = layer
        
        // Setup loop observer
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }
    
    private func startVideoPlayback() {
        videoPlayer?.seek(to: .zero)
        videoPlayer?.play()
    }
    
    private func stopVideoPlayback() {
        videoPlayer?.pause()
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
    }
}

/// Import-target caption hosted in the standalone import window: the target
/// Space's icon followed by "Space Name (Profile Name)". Reuses the shared
/// Spaces icon renderer so phi-icons and emoji render identically to the strip.
private struct ImportTargetView: View {
    let iconStoredValue: String?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            // Reuse the strip's icon view: it renders phi-icons, emoji (with
            // `.fixedSize()` so the glyph isn't clipped), and SF-symbol
            // fallbacks correctly — unlike IconPickerSelectionView, whose emoji
            // branch clips to a tight size×size frame.
            SpaceIconView(storedValue: iconStoredValue, size: 16, symbolWeight: .regular, tint: .white)
                .environment(\.colorScheme, .dark)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

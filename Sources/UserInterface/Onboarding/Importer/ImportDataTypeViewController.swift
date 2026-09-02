// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

/// Shared import data-type model (`ImportDataType`) and the reusable inline
/// toggle row (`DataTypeToggleRow`) used by the single-page import accordion.

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
            return NSLocalizedString("oobe.importDataType.bookmarksToggle", value: "Bookmarks", comment: "Import data type - Bookmarks toggle label")
        case .history:
            return NSLocalizedString("oobe.importDataType.browsingHistoryToggle", value: "Browsing history", comment: "Import data type - Browsing history toggle label")
        case .cookies:
            return NSLocalizedString("oobe.importDataType.cookiesToggle", value: "Cookies", comment: "Import data type - Cookies toggle label")
        case .extensions:
            return NSLocalizedString("oobe.importDataType.extensionsToggle", value: "Extensions", comment: "Import data type - Extensions toggle label")
        }
    }

    /// Which data types each browser supports.
    static func availableTypes(for browser: BrowserType) -> [ImportDataType] {
        switch browser {
        case .safari:
            return [.bookmarks, .history]
        case .chrome, .arc, .dia:
            return [.bookmarks, .history, .cookies, .extensions]
        case .file:
            // File import exposes no per-type toggles; the file row uses a picker
            // body instead. Chromium decides what the file contains.
            return []
        case .zen:
            // History only: Zen's bookmarks are parsed Mac-side by Migration, the
            // Firefox importer has no cookie path, and Firefox extensions cannot
            // be installed into Phi.
            return [.history]
        default:
            return [.bookmarks, .history]
        }
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

    /// Sets the switch programmatically. NSSwitch does not fire its action for a
    /// state set in code, so this does NOT re-enter `onToggle` — callers reset
    /// rows without recursing through the toggle handler.
    func setOn(_ on: Bool) {
        toggle.state = on ? .on : .off
    }
}

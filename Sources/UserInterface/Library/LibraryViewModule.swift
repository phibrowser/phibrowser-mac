// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Owns Library navigation and content independently of its window presentation.
final class LibraryViewModule: NSViewController {
    enum Section: Int, CaseIterable {
        case downloads, spaces, folio

        var title: String {
            switch self {
            case .downloads:
                return NSLocalizedString("library.navigation.downloads", value: "Downloads", comment: "Library - Downloads category")
            case .spaces:
                return NSLocalizedString("library.navigation.spaces", value: "Spaces", comment: "Library - Spaces category")
            case .folio:
                return NSLocalizedString("library.navigation.folio", value: "Folio", comment: "Library - Saved content category")
            }
        }

        var symbol: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .spaces: return "square.stack.3d.up"
            case .folio: return "book"
            }
        }
    }

    static var title: String {
        NSLocalizedString("library.navigation.title", value: "Library", comment: "Library - Title and entry button label")
    }

    private let browserState: BrowserState
    private let downloadsManager = DownloadsManager(profileIds: [])
    private let folioModel: FolioLibraryModel
    var onDismiss: (() -> Void)?

    init(browserState: BrowserState) {
        self.browserState = browserState
        folioModel = FolioLibraryModel(profileId: browserState.profileId)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let content = LibraryContentView(browserState: browserState, downloadsManager: downloadsManager, folioModel: folioModel) { [weak self] in
            self?.onDismiss?()
        }
        let host = ThemedHostingController(rootView: content, themeSource: browserState.themeContext)
        addChild(host)
        view = host.view
    }
}

private struct LibraryContentView: View {
    let browserState: BrowserState
    let downloadsManager: DownloadsManager
    let folioModel: FolioLibraryModel
    let dismiss: () -> Void
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: LibraryViewModule.Section = .downloads
    @State private var selectionAnimationTriggers: [LibraryViewModule.Section: Int] = [:]
    @State private var hoveredSection: LibraryViewModule.Section?
    @State private var closeHovered = false
    @State private var folioAvailable = SaveForLaterService.featureEnabled && !ApplicationState.shared.isGuest

    private func color(_ value: ThemedColor) -> Color {
        value.swiftUIColor(theme: theme, appearance: appearance)
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle()
                .fill(color(.separator))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(selection.title)
                        .font(.system(size: 20, weight: .semibold))
                        .themedForeground(.textPrimaryStrong)
                    Spacer()
                    closeButton
                }
                if selection == .downloads {
                    AllDownloadsListView(downloadsManager: downloadsManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selection == .folio {
                    FolioLibraryView(model: folioModel, openURL: openOriginal, openArchive: openArchive, reveal: reveal)
                        .clipShape(.rect(cornerRadius: 10))
                        .onDisappear { folioModel.clear() }
                } else {
                    placeholder
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                color(.contentOverlayBackground)
                    .overlay(color(.themeColor).opacity(0.025))
            }
        }
        .themedForeground(.textPrimary)
        .tint(color(.themeColor))
        .background(color(.windowBackground.withAlphaComponent(1)))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(color(.border), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: selection) {
            while !Task.isCancelled {
                folioAvailable = SaveForLaterService.featureEnabled && !ApplicationState.shared.isGuest
                if selection == .folio {
                    guard folioAvailable else {
                        folioModel.clear()
                        selection = .downloads
                        return
                    }
                    await folioModel.refresh()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onDisappear { folioModel.clear() }
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            ForEach(LibraryViewModule.Section.allCases.filter { $0 != .folio || folioAvailable }, id: \.self) { section in
                Button {
                    selection = section
                    selectionAnimationTriggers[section, default: 0] += 1
                } label: {
                    VStack(spacing: 9) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 25, weight: .regular))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(color(.themeColor))
                            .symbolEffect(.bounce, options: .speed(1.6),
                                          value: reduceMotion ? 0 : selectionAnimationTriggers[section, default: 0])
                        Text(section.title)
                            .foregroundStyle(color(.textPrimary))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selection == section
                                  ? color(.themeColor).opacity(appearance.isDark ? 0.22 : 0.12)
                                  : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(color(.hover).opacity(hoveredSection == section ? 1 : 0))
                            }
                    }
                    .contentShape(.rect)
                    .scaleEffect(!reduceMotion && hoveredSection == section ? 1.025 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredSection == section)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hoveredSection = section
                    } else if hoveredSection == section {
                        hoveredSection = nil
                    }
                }
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 24)
        .frame(width: 136)
        .frame(maxHeight: .infinity, alignment: .center)
        .background(color(.windowBackground.withAlphaComponent(1)))
        .onHover { if !$0 { hoveredSection = nil } }
        .onDisappear { hoveredSection = nil }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .themedForeground(.textSecondary)
                .frame(width: 26, height: 26)
                .background(color(.hover).opacity(closeHovered ? 1 : 0), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHovered = $0 }
        .help(NSLocalizedString("library.navigation.close", value: "Back to browsing", comment: "Library - Close button label"))
        .accessibilityLabel(NSLocalizedString("library.navigation.close", value: "Back to browsing", comment: "Library - Close button label"))
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: selection.symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(color(.themeColor))
                .frame(width: 64, height: 64)
                .background(color(.themeColor).opacity(0.08), in: .rect(cornerRadius: 18))
            Text(NSLocalizedString("library.content.comingSoon", value: "Coming soon", comment: "Library - Placeholder for a category not yet available"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openOriginal(_ url: URL) {
        guard FolioLibrary.webURL(url.absoluteString) != nil,
              SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        dismiss()
        browserState.createTab(url.absoluteString, customGuid: nil, focusAfterCreate: true)
    }

    private func openArchive(_ item: FolioItem) {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        do {
            let url = try FolioLibrary.fileURL(basename: item.basename, ext: "mhtml", folder: folioModel.folder)
            dismiss()
            browserState.createTab(url.absoluteString, customGuid: nil, focusAfterCreate: true)
        } catch { folioModel.error = error.localizedDescription }
    }

    private func reveal(_ item: FolioItem?) {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        do {
            if let item {
                let url = try FolioLibrary.fileURL(basename: item.basename, ext: "md", folder: folioModel.folder)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                try FileManager.default.createDirectory(at: folioModel.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folioModel.folder)
            }
        } catch { folioModel.error = error.localizedDescription }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
import ObjectiveC
#endif

// MARK: - Edit Mode

/// The editing mode for `EditPinnedTab`.
enum EditPinnedTabMode {
    /// Folder mode: only title can be edited.
    case folder
    /// New folder mode: create a new folder, only title can be edited.
    case newFolder
    /// Bookmark mode: both title and URL can be edited.
    case bookmark
    /// Toggle-bookmark mode triggered by CMD+D: edits title/URL/folder, Cancel shows "Remove".
    case editOrMoveBookmark
    /// Favorite mode: only URL can be edited.
    case pin
}

/// The result returned when saving in `EditPinnedTab`.
struct EditPinnedTabResult {
    let title: String?
    let url: String?
    let parentFolderGuid: String?
    /// Updated secondary URL for a split-view bookmark. Nil for ordinary
    /// bookmarks; an empty string is treated as "no secondary URL" by the
    /// persistence layer.
    let secondaryUrl: String?
    /// Updated display title for the secondary URL. Nil for ordinary
    /// bookmarks; for split bookmarks an empty string clears the title and
    /// lets the renderer fall back to the host.
    let secondaryTitle: String?

    init(title: String?,
         url: String?,
         parentFolderGuid: String?,
         secondaryUrl: String? = nil,
         secondaryTitle: String? = nil) {
        self.title = title
        self.url = url
        self.parentFolderGuid = parentFolderGuid
        self.secondaryUrl = secondaryUrl
        self.secondaryTitle = secondaryTitle
    }
}

// MARK: - Favicon View

/// A SwiftUI wrapper for loading and displaying the favicon of a given page URL.
/// The underlying image is fetched via `FaviconDataProvider` and cached by Kingfisher.
private struct FaviconView: View {
    let urlString: String
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let placeholderLabel = Text(
            NSLocalizedString(
                "Website",
                comment: "Pinned tab URL editor - Accessibility description for placeholder favicon"
            )
        )

        Group {
            if URL(string: urlString) != nil {
                Image.favicon(
                    for: urlString,
                    configuration: .init(cornerRadius: cornerRadius)
                )
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(placeholderLabel)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A view displaying the two favicons of a split-view bookmark side-by-side
/// inside a single rounded tile. Used as the header icon in `EditPinnedTabView`
/// when the bookmark being edited carries a `secondaryUrl`.
private struct SplitFaviconView: View {
    let primaryURLString: String
    let secondaryURLString: String
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        // Each favicon takes half the available width; a 1pt gap keeps the
        // two halves visually separated without splitting the rounded tile.
        let halfWidth = (size - 1) / 2
        HStack(spacing: 1) {
            faviconHalf(urlString: primaryURLString, width: halfWidth)
            faviconHalf(urlString: secondaryURLString, width: halfWidth)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func faviconHalf(urlString: String, width: CGFloat) -> some View {
        Group {
            if URL(string: urlString) != nil {
                Image.favicon(
                    for: urlString,
                    configuration: .init(cornerRadius: 0)
                )
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: size)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }
}

/// A view displaying a folder icon.
private struct FolderIconView: View {
    let size: CGFloat

    var body: some View {
        Image(.foderClose)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.orange)
            .frame(width: size, height: size)
    }
}

// MARK: - AppKit Bridge
#if canImport(AppKit)
private var editPinnedTabCoordinatorKey: UInt8 = 0

@MainActor
enum EditPinnedTabPresenter {
    static func presentModal(
        mode: EditPinnedTabMode,
        title: String = "",
        urlString: String = "",
        secondaryUrlString: String? = nil,
        secondaryTitleString: String? = nil,
        modelContainer: ModelContainer? = nil,
        profileId: String = "",
        initialFolderGuid: String? = nil,
        from parentWindow: NSWindow?,
        onCancel: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onCreateFolder: ((String) -> String?)? = nil,
        onSave: @escaping (EditPinnedTabResult) -> Void
    ) {
        let coordinator = Coordinator(onCancel: onCancel, onRemove: onRemove, onSave: onSave)

        let contentView = EditPinnedTabView(
            mode: mode,
            title: title,
            urlString: urlString,
            secondaryUrlString: secondaryUrlString,
            secondaryTitleString: secondaryTitleString,
            profileId: profileId,
            initialFolderGuid: initialFolderGuid,
            dismissesOnAction: false,
            onCancel: { [weak coordinator] in
                coordinator?.cancel()
            },
            onRemove: { [weak coordinator] in
                coordinator?.remove()
            },
            onCreateFolder: onCreateFolder,
            onSave: { [weak coordinator] result in
                coordinator?.save(result)
            }
        )

        let hosting: ThemedHostingController<AnyView>
        if let modelContainer {
            hosting = ThemedHostingController(rootView: AnyView(contentView.modelContainer(modelContainer)))
        } else {
            hosting = ThemedHostingController(rootView: AnyView(contentView))
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        coordinator.window = window
        coordinator.parentWindow = parentWindow
        window.delegate = coordinator
        objc_setAssociatedObject(window, &editPinnedTabCoordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        if let parentWindow {
            coordinator.isSheet = true
            parentWindow.beginSheet(window) { _ in }
        } else {
            coordinator.isSheet = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.runModal(for: window)
        }
    }
}

@MainActor
private final class Coordinator: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    weak var parentWindow: NSWindow?
    var isSheet: Bool = false

    private let onCancel: (() -> Void)?
    private let onRemove: (() -> Void)?
    private let onSave: (EditPinnedTabResult) -> Void
    private var didFinish: Bool = false

    init(onCancel: (() -> Void)?, onRemove: (() -> Void)?, onSave: @escaping (EditPinnedTabResult) -> Void) {
        self.onCancel = onCancel
        self.onRemove = onRemove
        self.onSave = onSave
    }

    func cancel() {
        finishIfNeeded(action: .cancel, value: nil)
    }

    func remove() {
        finishIfNeeded(action: .remove, value: nil)
    }

    func save(_ value: EditPinnedTabResult) {
        finishIfNeeded(action: .save, value: value)
    }

    func windowWillClose(_ notification: Notification) {
        finishIfNeeded(action: .cancel, value: nil)
    }

    private enum FinishAction { case cancel, remove, save }

    private func finishIfNeeded(action: FinishAction, value: EditPinnedTabResult?) {
        guard !didFinish else { return }
        didFinish = true

        endModalAndCloseWindow()

        switch action {
        case .save:
            if let value { onSave(value) }
        case .remove:
            onRemove?()
        case .cancel:
            onCancel?()
        }
    }

    private func endModalAndCloseWindow() {
        guard let window else { return }

        if isSheet {
            if let parentWindow {
                parentWindow.endSheet(window)
            } else if let sheetParent = window.sheetParent {
                sheetParent.endSheet(window)
            }
            window.orderOut(nil)
            window.close()
        } else {
            NSApp.stopModal()
            window.orderOut(nil)
            window.close()
        }

        // Release the retained coordinator.
        objc_setAssociatedObject(window, &editPinnedTabCoordinatorKey, nil, .OBJC_ASSOCIATION_ASSIGN)
    }
}
#endif

// MARK: - Edit Pinned Tab View

struct EditPinnedTabView: View {
    @Environment(\.dismiss) private var dismiss

    private let mode: EditPinnedTabMode
    private let profileId: String
    private let faviconURLString: String
    private let secondaryFaviconURLString: String?
    private let isSplitBookmark: Bool
    private let onCancel: (() -> Void)?
    private let onRemove: (() -> Void)?
    private let onSave: ((EditPinnedTabResult) -> Void)?
    private let onCreateFolder: ((String) -> String?)?
    private let dismissesOnAction: Bool

    @State private var titleString: String
    @State private var urlString: String
    @State private var secondaryUrlString: String
    @State private var secondaryTitleString: String
    @State private var selectedFolderGuid: String?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case title
        case url
        case secondaryTitle
        case secondaryUrl
        case newFolderName
    }

    init(
        mode: EditPinnedTabMode,
        title: String = "",
        urlString: String = "",
        secondaryUrlString: String? = nil,
        secondaryTitleString: String? = nil,
        profileId: String = "",
        initialFolderGuid: String? = nil,
        dismissesOnAction: Bool = true,
        onCancel: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onCreateFolder: ((String) -> String?)? = nil,
        onSave: ((EditPinnedTabResult) -> Void)? = nil
    ) {
        self.mode = mode
        self.profileId = profileId
        self.faviconURLString = urlString
        self.secondaryFaviconURLString = secondaryUrlString
        self.isSplitBookmark = (secondaryUrlString?.isEmpty == false)
        self.dismissesOnAction = dismissesOnAction
        self.onCancel = onCancel
        self.onRemove = onRemove
        self.onCreateFolder = onCreateFolder
        self.onSave = onSave
        _titleString = State(initialValue: title)
        _urlString = State(initialValue: URLProcessor.phiBrandEnsuredUrlString(urlString))
        _secondaryUrlString = State(initialValue: URLProcessor.phiBrandEnsuredUrlString(secondaryUrlString ?? ""))
        _secondaryTitleString = State(initialValue: secondaryTitleString ?? "")
        _selectedFolderGuid = State(initialValue: initialFolderGuid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isCreatingFolder {
                newFolderHeaderSection
                newFolderInputSection
                newFolderButtonsSection
            } else {
                headerSection
                inputFieldsSection
                buttonsSection
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .onAppear {
            setInitialFocus()
        }
        .onChange(of: isCreatingFolder) { _, creating in
            if creating {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusedField = .newFolderName
                }
            }
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            iconView
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(headerTitle)
                    .font(.system(size: 22, weight: .semibold))

                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch mode {
        case .folder, .newFolder:
            FolderIconView(size: 48)
        case .bookmark, .editOrMoveBookmark, .pin:
            if isSplitBookmark, let secondaryFaviconURLString {
                SplitFaviconView(
                    primaryURLString: faviconURLString,
                    secondaryURLString: secondaryFaviconURLString,
                    size: 56,
                    cornerRadius: 6
                )
            } else {
                FaviconView(urlString: faviconURLString, size: 56, cornerRadius: 6)
            }
        }
    }

    private var headerTitle: String {
        switch mode {
        case .folder:
            return NSLocalizedString(
                "Edit Folder",
                comment: "Folder editor - Title of the sheet to edit a folder"
            )
        case .newFolder:
            return NSLocalizedString(
                "New Folder",
                comment: "Folder creator - Title of the sheet to create a new folder"
            )
        case .bookmark, .editOrMoveBookmark:
            if isSplitBookmark {
                return NSLocalizedString(
                    "Edit Split Bookmark",
                    comment: "Bookmark editor - Title of the sheet when editing a split-view bookmark"
                )
            }
            return NSLocalizedString(
                "Edit Bookmark",
                comment: "Bookmark editor - Title of the sheet to edit a bookmark"
            )
        case .pin:
            if isSplitBookmark {
                return NSLocalizedString(
                    "Edit Pinned Split",
                    comment: "Favorite editor - Title of the sheet to edit a pinned split-view tab"
                )
            }
            return NSLocalizedString(
                "Edit Pinned Tab",
                comment: "Favorite editor - Title of the sheet to edit a pin"
            )
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .folder:
            return NSLocalizedString(
                "Give this folder a name to organize your bookmarks.",
                comment: "Folder editor - Subtitle explaining folder naming"
            )
        case .newFolder:
            return NSLocalizedString(
                "Create a new folder to organize your bookmarks.",
                comment: "Folder creator - Subtitle explaining new folder creation"
            )
        case .bookmark, .editOrMoveBookmark:
            if isSplitBookmark {
                return NSLocalizedString(
                    "Edit the name and both addresses for this split-view bookmark.",
                    comment: "Bookmark editor - Subtitle explaining split-view bookmark editing"
                )
            }
            return NSLocalizedString(
                "Edit the name and address for this bookmark.",
                comment: "Bookmark editor - Subtitle explaining bookmark editing"
            )
        case .pin:
            if isSplitBookmark {
                return NSLocalizedString(
                    "Edit the names and addresses for both panes of this pinned split.",
                    comment: "Pinned tab editor - Subtitle explaining pinned split editing"
                )
            }
            return NSLocalizedString(
                "Edit the name and address for this pinned tab.",
                comment: "Pinned tab editor - Subtitle explaining pinned tab editing"
            )
        }
    }

    // MARK: - Input Fields Section

    @ViewBuilder
    private var inputFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .folder || mode == .newFolder || mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryNameFieldLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField(
                        "",
                        text: $titleString,
                        prompt: Text(titlePlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                }
            }

            if mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryUrlFieldLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField(
                        "",
                        text: $urlString,
                        prompt: Text(
                            NSLocalizedString(
                                "https://example.com",
                                comment: "Editor - Placeholder example URL in text field"
                            )
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .url)
                }
            }

            if isSplitBookmark, mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        NSLocalizedString(
                            "Right Name",
                            comment: "Bookmark editor - Label for the right (secondary) title input field on a split-view bookmark"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    TextField(
                        "",
                        text: $secondaryTitleString,
                        prompt: Text(
                            NSLocalizedString(
                                "Bookmark Name",
                                comment: "Bookmark editor - Placeholder for bookmark name input"
                            )
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .secondaryTitle)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        NSLocalizedString(
                            "Right URL",
                            comment: "Bookmark editor - Label for the right (secondary) URL input field on a split-view bookmark"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    TextField(
                        "",
                        text: $secondaryUrlString,
                        prompt: Text(
                            NSLocalizedString(
                                "https://example.com",
                                comment: "Editor - Placeholder example URL in text field"
                            )
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .secondaryUrl)
                }
            }

            if mode == .bookmark || mode == .editOrMoveBookmark {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        NSLocalizedString(
                            "Folder",
                            comment: "Bookmark editor - Label for the folder picker"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    BookmarkFolderPicker(
                        profileId: profileId,
                        selectedFolderGuid: $selectedFolderGuid,
                        onNewFolder: {
                            newFolderName = ""
                            isCreatingFolder = true
                        }
                    )
                }
            }
        }
    }

    private var primaryUrlFieldLabel: String {
        if isSplitBookmark {
            return NSLocalizedString(
                "Left URL",
                comment: "Bookmark editor - Label for the left (primary) URL input field on a split-view bookmark"
            )
        }
        return NSLocalizedString(
            "URL",
            comment: "Editor - Label for the URL input field"
        )
    }

    private var primaryNameFieldLabel: String {
        if isSplitBookmark {
            return NSLocalizedString(
                "Left Name",
                comment: "Bookmark editor - Label for the left (primary) title input field on a split-view bookmark"
            )
        }
        return NSLocalizedString(
            "Name",
            comment: "Editor - Label for the title/name input field"
        )
    }

    private var titlePlaceholder: String {
        switch mode {
        case .folder, .newFolder:
            return NSLocalizedString(
                "Folder Name",
                comment: "Folder editor - Placeholder for folder name input"
            )
        case .bookmark, .editOrMoveBookmark:
            return NSLocalizedString(
                "Bookmark Name",
                comment: "Bookmark editor - Placeholder for bookmark name input"
            )
        case .pin:
            return NSLocalizedString(
                "Tab Name",
                comment: "Pinned tab editor - Placeholder for pinned tab name input"
            )
        }
    }

    // MARK: - Buttons Section

    @ViewBuilder
    private var buttonsSection: some View {
        HStack {
            Spacer()

            if mode == .editOrMoveBookmark {
                // Hidden ESC handler: close without removing
                Button("") {
                    onCancel?()
                    if dismissesOnAction { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)

                Button(
                    NSLocalizedString("Remove", comment: "Bookmark editor - Remove bookmark button title (CMD+D toggle)")
                ) {
                    onRemove?()
                    if dismissesOnAction { dismiss() }
                }
            } else {
                Button(
                    NSLocalizedString("Cancel", comment: "Editor - Cancel button title")
                ) {
                    onCancel?()
                    if dismissesOnAction { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
            }

            Button(
                NSLocalizedString(
                    "Save",
                    comment: "Editor - Save button title"
                )
            ) {
                let result = EditPinnedTabResult(
                    title: (mode == .folder || mode == .newFolder || mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin)
                        ? titleString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    url: (mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin)
                        ? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    parentFolderGuid: (mode == .bookmark || mode == .editOrMoveBookmark)
                        ? selectedFolderGuid
                        : nil,
                    secondaryUrl: (isSplitBookmark && (mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin))
                        ? secondaryUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    secondaryTitle: (isSplitBookmark && (mode == .bookmark || mode == .editOrMoveBookmark || mode == .pin))
                        ? secondaryTitleString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                )
                onSave?(result)
                if dismissesOnAction {
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isSaveEnabled)
        }
        .padding(.top, 6)
    }

    private var isSaveEnabled: Bool {
        switch mode {
        case .folder, .newFolder:
            return !titleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bookmark, .editOrMoveBookmark:
            let titleOK = !titleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let primaryOK = !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSplitBookmark {
                let secondaryOK = !secondaryUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return titleOK && primaryOK && secondaryOK
            }
            return titleOK && primaryOK
        case .pin:
            let titleOK = !titleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let primaryOK = !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSplitBookmark {
                let secondaryOK = !secondaryUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return titleOK && primaryOK && secondaryOK
            }
            return titleOK && primaryOK
        }
    }

    private func setInitialFocus() {
        switch mode {
        case .folder, .newFolder, .bookmark, .editOrMoveBookmark, .pin:
            focusedField = .title
        }
    }

    // MARK: - Inline New Folder

    @ViewBuilder
    private var newFolderHeaderSection: some View {
        HStack(alignment: .top, spacing: 14) {
            FolderIconView(size: 48)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "New Folder",
                    comment: "Bookmark editor - Inline new folder creation title"
                ))
                .font(.system(size: 22, weight: .semibold))

                Text(NSLocalizedString(
                    "Enter a name for the new folder.",
                    comment: "Bookmark editor - Inline new folder creation subtitle"
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var newFolderInputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(
                "Name",
                comment: "Editor - Label for the title/name input field"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)

            TextField(
                "",
                text: $newFolderName,
                prompt: Text(NSLocalizedString(
                    "Folder Name",
                    comment: "Folder editor - Placeholder for folder name input"
                ))
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .newFolderName)
        }
    }

    @ViewBuilder
    private var newFolderButtonsSection: some View {
        HStack {
            Spacer()

            Button(NSLocalizedString("Cancel", comment: "Editor - Cancel button title")) {
                isCreatingFolder = false
                newFolderName = ""
            }
            .keyboardShortcut(.cancelAction)

            Button(NSLocalizedString("Save", comment: "Editor - Save button title")) {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let folderGuid = onCreateFolder?(name)
                let result = EditPinnedTabResult(
                    title: titleString.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
                    parentFolderGuid: folderGuid,
                    secondaryUrl: isSplitBookmark
                        ? secondaryUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    secondaryTitle: isSplitBookmark
                        ? secondaryTitleString.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                )
                onSave?(result)
                if dismissesOnAction { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.top, 6)
    }
}

// MARK: - Bookmark Folder Picker

private struct BookmarkFolderPicker: View {
    let profileId: String
    @Binding var selectedFolderGuid: String?
    var onNewFolder: (() -> Void)?

    @Query private var folderModels: [TabDataModel]

    init(profileId: String, selectedFolderGuid: Binding<String?>, onNewFolder: (() -> Void)? = nil) {
        self.profileId = profileId
        self._selectedFolderGuid = selectedFolderGuid
        self.onNewFolder = onNewFolder
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        _folderModels = Query(
            filter: #Predicate<TabDataModel> { $0.type == folderRaw },
            sort: \.index
        )
    }

    private var rootFolder: TabDataModel? {
        // Identify the Space's hidden top-level folder structurally
        // (parent == nil within the profile). The picker is invoked from the
        // default Space today; when EditPinnedTabView is threaded with a
        // spaceId by the Space-switcher UI, swap the secondary filter to
        // `$0.spaceId == spaceId`.
        folderModels.first {
            $0.parent == nil &&
            $0.profileId == profileId &&
            $0.spaceId == LocalStore.defaultSpaceId
        }
    }

    private var flatFolderList: [(folder: TabDataModel, depth: Int)] {
        guard let root = rootFolder else { return [] }
        var result: [(TabDataModel, Int)] = []
        func dfs(_ node: TabDataModel, depth: Int) {
            let childFolders = node.children
                .filter { $0.dataType == .bookmarkFolder }
                .sorted { $0.index < $1.index }
            for child in childFolders {
                result.append((child, depth))
                dfs(child, depth: depth + 1)
            }
        }
        dfs(root, depth: 0)
        return result
    }

    var body: some View {
        FolderPopUpButton(
            flatFolders: flatFolderList,
            rootGuid: rootFolder?.guid,
            selectedGuid: $selectedFolderGuid,
            onNewFolder: onNewFolder
        )
    }
}

#if canImport(AppKit)
private struct FolderPopUpButton: NSViewRepresentable {
    private static let newFolderTag = -1

    let flatFolders: [(folder: TabDataModel, depth: Int)]
    let rootGuid: String?
    @Binding var selectedGuid: String?
    var onNewFolder: (() -> Void)?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let previousSelection = selectedGuid ?? rootGuid
        button.removeAllItems()

        let bookmarksBarTitle = NSLocalizedString(
            "Bookmarks Bar",
            comment: "Bookmark editor - Root bookmark folder display name in folder picker"
        )
        let menu = button.menu ?? NSMenu()

        let rootItem = NSMenuItem(title: bookmarksBarTitle, action: nil, keyEquivalent: "")
        rootItem.representedObject = rootGuid as NSString?
        rootItem.indentationLevel = 0
        menu.addItem(rootItem)

        for (folder, depth) in flatFolders {
            let item = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
            item.representedObject = folder.guid as NSString
            item.indentationLevel = depth + 1
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let newFolderItem = NSMenuItem(
            title: NSLocalizedString("New Folder…", comment: "Bookmark editor - Create new folder option in folder picker"),
            action: nil,
            keyEquivalent: ""
        )
        newFolderItem.tag = Self.newFolderTag
        menu.addItem(newFolderItem)

        if let guid = previousSelection,
           let idx = menu.items.firstIndex(where: { ($0.representedObject as? String) == guid }) {
            button.selectItem(at: idx)
        } else {
            button.selectItem(at: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FolderPopUpButton
        init(_ parent: FolderPopUpButton) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }
            if item.tag == FolderPopUpButton.newFolderTag {
                // Revert selection, then trigger callback
                let fallbackGuid = parent.selectedGuid ?? parent.rootGuid
                if let guid = fallbackGuid,
                   let idx = sender.menu?.items.firstIndex(where: { ($0.representedObject as? String) == guid }) {
                    sender.selectItem(at: idx)
                } else {
                    sender.selectItem(at: 0)
                }
                parent.onNewFolder?()
            } else if let guid = item.representedObject as? String {
                parent.selectedGuid = guid
            }
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
struct EditPinnedTab_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            EditPinnedTabView(
                mode: .folder,
                title: "My Bookmarks",
                onCancel: {
                    print("EditPinnedTab: Cancel")
                },
                onSave: { result in
                    print("EditPinnedTab: Save -> title: \(result.title ?? "nil")")
                }
            )
            .previewDisplayName("Folder Mode")

            EditPinnedTabView(
                mode: .newFolder,
                onCancel: {
                    print("EditPinnedTab: Cancel")
                },
                onSave: { result in
                    print("EditPinnedTab: Save -> title: \(result.title ?? "nil")")
                }
            )
            .previewDisplayName("New Folder Mode")

            EditPinnedTabView(
                mode: .bookmark,
                title: "Google",
                urlString: "https://www.google.com/",
                onCancel: {
                    print("EditPinnedTab: Cancel")
                },
                onSave: { result in
                    print("EditPinnedTab: Save -> title: \(result.title ?? "nil"), url: \(result.url ?? "nil")")
                }
            )
            .previewDisplayName("Bookmark Mode")

            EditPinnedTabView(
                mode: .pin,
                title: "163",
                urlString: "https://www.163.com/",
                onCancel: {
                    print("EditPinnedTab: Cancel")
                },
                onSave: { result in
                    print("EditPinnedTab: Save -> title: \(result.title ?? "nil"), url: \(result.url ?? "nil")")
                }
            )
            .previewDisplayName("Favorite Mode")
        }
        .frame(width: 400)
        .padding()
    }
}
#endif

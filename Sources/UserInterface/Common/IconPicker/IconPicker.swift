// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct IconPicker: View {
    let selected: IconPickerSelection?
    let showsGroups: Bool
    /// Explicit width for the picker. Nil keeps the fixed default (262pt / 8
    /// columns) used by popovers and the settings pane. When set, the picker
    /// fills exactly that width and the grid reflows to as many columns as fit —
    /// the create-Space form measures its container and passes the width in.
    let width: CGFloat?
    /// When true the picker stretches vertically with its container instead of
    /// the fixed popover height, letting the grid show as many rows as fit —
    /// the Spaces settings pane fills its detail column with the picker.
    let fillsAvailableHeight: Bool
    let onSelect: (IconPickerSelection) -> Void
    let onReset: (() -> Void)?

    private let emojiCatalog: EmojiCatalog

    @State private var selectedTab: IconPickerTab
    @State private var iconSearchText = ""
    @State private var emojiSearchText = ""
    /// The selection last made by clicking a cell inside the picker. Such a
    /// cell is already visible, so the grids skip the reveal-scroll for it
    /// instead of shifting the grid under the cursor.
    @State private var internallyPickedSelection: IconPickerSelection?

    /// Fixed height callers can use to size a container around the picker.
    static let preferredHeight: CGFloat = IconPickerMetrics.height

    init(selected: IconPickerSelection?,
         showsGroups: Bool,
         width: CGFloat? = nil,
         fillsAvailableHeight: Bool = false,
         emojiCatalog: EmojiCatalog = .shared,
         onReset: (() -> Void)? = nil,
         onSelect: @escaping (IconPickerSelection) -> Void) {
        self.selected = selected
        self.showsGroups = showsGroups
        self.width = width
        self.fillsAvailableHeight = fillsAvailableHeight
        self.emojiCatalog = emojiCatalog
        self.onSelect = onSelect
        self.onReset = onReset
        _selectedTab = State(initialValue: selected?.isEmoji == true ? .emoji : .icon)
    }

    private var resolvedWidth: CGFloat { width ?? IconPickerMetrics.width }

    var body: some View {
        if fillsAvailableHeight {
            pickerBody
                .frame(width: resolvedWidth)
                .frame(maxHeight: .infinity)
        } else {
            pickerBody
                .frame(width: resolvedWidth, height: IconPickerMetrics.height)
        }
    }

    private var pickerBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PhiSegmentedPicker(
                    IconPickerTab.allCases,
                    selection: $selectedTab
                ) { tab in
                    Text(tab.title)
                }
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("common.iconPicker.reset", value: "Reset Icon", comment: "Icon picker - Restore the original icon"))
                }
            }
            .frame(height: IconPickerMetrics.segmentHeight)

            IconPickerSearchField(
                text: activeSearchText,
                placeholder: searchPlaceholder
            )
            .padding(.top, IconPickerMetrics.segmentToSearchSpacing)
            .padding(.horizontal, searchHorizontalPadding)

            Group {
                switch selectedTab {
                case .icon:
                    phiIconGrid
                case .emoji:
                    emojiGrid
                }
            }
            .padding(.top, IconPickerMetrics.searchToGridSpacing)
        }
        .padding(.top, IconPickerMetrics.topPadding)
        .padding(.bottom, IconPickerMetrics.bottomPadding)
        // Follow selection changes made from outside (switching Spaces in the
        // settings pane): land on the tab holding the new selection, whose grid
        // then reveals it on appear.
        .onChange(of: selected) { _, newSelection in
            guard let newSelection else { return }
            selectedTab = newSelection.isEmoji ? .emoji : .icon
        }
    }

    private var activeSearchText: Binding<String> {
        switch selectedTab {
        case .icon:
            $iconSearchText
        case .emoji:
            $emojiSearchText
        }
    }

    private var activeSearchQuery: String {
        switch selectedTab {
        case .icon:
            iconSearchText
        case .emoji:
            emojiSearchText
        }
    }

    private var searchPlaceholder: String {
        switch selectedTab {
        case .icon:
            NSLocalizedString("common.iconPicker.iconsSearchPlaceholder", value: "Search icons",
                comment: "Icon picker - Search field placeholder for Phi icons"
            )
        case .emoji:
            NSLocalizedString("common.iconPicker.emojiSearchPlaceholder", value: "Search emoji",
                comment: "Icon picker - Search field placeholder for emoji"
            )
        }
    }

    private var searchHorizontalPadding: CGFloat {
        guard width == nil else { return IconPickerMetrics.gridHorizontalPadding }
        return (resolvedWidth - IconPickerMetrics.fixedGridContentWidth) / 2
    }

    /// As many columns as fit `resolvedWidth` when an explicit width was given,
    /// else the fixed 8-column layout. The reflow path packs the *most* icons a
    /// row can hold at their natural size and lets flexible columns share the
    /// leftover, so the row fills the box edge-to-edge. Sizing each column to a
    /// full item+gap unit instead fits one fewer column and leaves the whole grid
    /// centered with wide left/right margins that read as stray padding in a
    /// narrow sidebar. The column `spacing` here is the horizontal gap only — the
    /// `LazyVGrid`'s own `spacing:` controls row spacing — so a tight reflow gap
    /// doesn't change the vertical rhythm.
    private static let reflowColumnSpacing: CGFloat = 2

    private var gridColumns: [GridItem] {
        guard width != nil else { return IconPickerMetrics.columns }
        let usable = resolvedWidth - 2 * IconPickerMetrics.gridHorizontalPadding
        let count = max(1, Int(usable / IconPickerMetrics.itemSize))
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: Self.reflowColumnSpacing),
            count: count
        )
    }

    private var phiIconGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if filteredPhiIcons.isEmpty {
                        emptySearchResults
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: IconPickerMetrics.rowSpacing) {
                            ForEach(filteredPhiIcons) { icon in
                                IconPickerGridButton(
                                    isSelected: selected == .phiIcon(id: icon.assetName),
                                    help: icon.name,
                                    action: {
                                        internallyPickedSelection = .phiIcon(id: icon.assetName)
                                        onSelect(.phiIcon(id: icon.assetName))
                                    }
                                ) {
                                    Image(icon.assetName)
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: IconPickerMetrics.iconSize, height: IconPickerMetrics.iconSize)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
                .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
            }
            .frame(height: fillsAvailableHeight ? nil : IconPickerMetrics.gridHeight)
            .onAppear {
                revealSelectedIcon(selected, using: proxy)
            }
            .onChange(of: selected) { _, newSelection in
                handleSelectionChange(newSelection) {
                    revealSelectedIcon(newSelection, using: proxy)
                }
            }
        }
    }

    private var filteredPhiIcons: [PhiIconCatalog.Icon] {
        IconPickerSearch.phiIcons(matching: activeSearchQuery)
    }

    private var emojiGrid: some View {
        let columns = gridColumns
        let layout = EmojiGridLayout(
            groups: filteredEmojiGroups,
            showsGroups: showsGroups,
            columnCount: columns.count
        )

        return ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if layout.rows.isEmpty {
                        emptySearchResults
                    } else {
                        LazyVStack(
                            alignment: .leading,
                            spacing: IconPickerMetrics.rowSpacing
                        ) {
                            ForEach(layout.rows) { row in
                                EmojiPickerGridRow(
                                    row: row,
                                    columns: columns,
                                    selectedEmojiId: selectedEmojiId,
                                    onSelect: selectEmoji
                                )
                                .id(row.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
                .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
            }
            .frame(height: fillsAvailableHeight ? nil : IconPickerMetrics.gridHeight)
            .onAppear {
                revealSelectedEmoji(selected, in: layout, using: proxy)
            }
            .onChange(of: selected) { _, newSelection in
                handleSelectionChange(newSelection) {
                    revealSelectedEmoji(newSelection, in: layout, using: proxy)
                }
            }
        }
    }

    private var filteredEmojiGroups: [EmojiCatalog.Group] {
        IconPickerSearch.emojiGroups(in: emojiCatalog, matching: activeSearchQuery)
    }

    private var emptySearchResults: some View {
        Text(NSLocalizedString("common.iconPicker.searchEmptyMessage", value: "No results",
            comment: "Icon picker - Empty state when search has no matching icons"
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(
            minHeight: IconPickerMetrics.gridHeight
                - 2 * IconPickerMetrics.gridVerticalPadding
        )
    }

    private func selectEmoji(_ selection: IconPickerSelection) {
        internallyPickedSelection = selection
        onSelect(selection)
    }

    private var selectedEmojiId: String? {
        guard case .emoji(let id, _) = selected else { return nil }
        return id
    }

    /// A click inside a grid is already visible, so only external selection
    /// changes should request a reveal.
    private func handleSelectionChange(_ newSelection: IconPickerSelection?,
                                       reveal: () -> Void) {
        let wasInternal = newSelection != nil && newSelection == internallyPickedSelection
        internallyPickedSelection = nil
        guard !wasInternal else { return }
        reveal()
    }

    private func revealSelectedIcon(_ selection: IconPickerSelection?,
                                    using proxy: ScrollViewProxy) {
        guard case .phiIcon(let id) = selection else { return }
        let canonicalID = PhiIconCatalog.canonicalId(for: id) ?? id
        guard filteredPhiIcons.contains(where: { $0.id == canonicalID }) else {
            return
        }
        reveal(canonicalID, using: proxy)
    }

    private func revealSelectedEmoji(_ selection: IconPickerSelection?,
                                     in layout: EmojiGridLayout,
                                     using proxy: ScrollViewProxy) {
        guard case .emoji(let id, _) = selection else { return }
        guard let rowID = layout.rowID(for: id) else { return }
        reveal(rowID, using: proxy)
    }

    /// The row is a direct child of the outer lazy stack, so one next-run-loop
    /// scroll is enough even when the selected emoji starts off screen.
    private func reveal<ID: Hashable>(_ target: ID,
                                      using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

struct IconPickerSelectionView: View {
    let selection: IconPickerSelection?
    var size: CGFloat = 18

    var body: some View {
        switch selection ?? .defaultSelection {
        case .phiIcon(let id):
            Image(PhiIconCatalog.canonicalId(for: id) ?? id)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        case .emoji(_, let text):
            Text(text)
                .font(.system(size: size))
                .frame(width: size, height: size)
        }
    }
}

enum IconPickerTab: CaseIterable, Hashable {
    case icon
    case emoji

    var title: String {
        switch self {
        case .icon:
            return NSLocalizedString(
                "common.iconPicker.iconTabTitle",
                value: "Icon",
                comment: "Icon picker - Tab for choosing a Phi icon; translate using the locale's standard term for an icon"
            )
        case .emoji:
            return NSLocalizedString(
                "common.iconPicker.emojiTabTitle",
                value: "Emoji",
                comment: "Icon picker - Tab for choosing an emoji; translate using the locale's standard term for emoji"
            )
        }
    }
}

enum IconPickerSearch {
    static func phiIcons(matching query: String) -> [PhiIconCatalog.Icon] {
        guard let query = preparedQuery(query) else { return PhiIconCatalog.all }
        return PhiIconCatalog.all.filter { icon in
            matches(query, candidates: [icon.name, icon.assetName])
        }
    }

    static func emojiGroups(in catalog: EmojiCatalog,
                            matching query: String) -> [EmojiCatalog.Group] {
        guard let query = preparedQuery(query) else { return catalog.groups }

        return catalog.groups.compactMap { group in
            if matches(query, candidates: [group.name]) {
                return group
            }

            let items = group.items.filter { item in
                matches(query, candidates: emojiKeywords(for: item))
            }
            guard !items.isEmpty else { return nil }
            return EmojiCatalog.Group(name: group.name, items: items)
        }
    }

    static func emojiItems(in catalog: EmojiCatalog,
                           matching query: String) -> [EmojiItem] {
        emojiGroups(in: catalog, matching: query).flatMap(\.items)
    }

    private static func emojiKeywords(for item: EmojiItem) -> [String] {
        [item.text, item.name, item.subgroup]
            + item.skinVariants.flatMap { [$0.text, $0.name] }
    }

    private static func preparedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ query: String, candidates: [String]) -> Bool {
        let normalizedQuery = normalizedWords(in: query)
        return candidates.contains { candidate in
            if candidate.localizedStandardContains(query) {
                return true
            }

            guard !normalizedQuery.isEmpty else { return false }
            return normalizedWords(in: candidate)
                .localizedStandardContains(normalizedQuery)
        }
    }

    private static func normalizedWords(in value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct EmojiGridLayout {
    struct Row: Identifiable {
        enum ID: Hashable {
            case header(groupID: String)
            case items(groupID: String?, firstItemID: String)
        }

        enum Content {
            case header(title: String, addsTopSpacing: Bool)
            case items([EmojiItem])
        }

        let id: ID
        let content: Content
    }

    let rows: [Row]

    private let rowIDByEmojiID: [String: Row.ID]

    init(groups: [EmojiCatalog.Group],
         showsGroups: Bool,
         columnCount: Int) {
        let columnCount = max(1, columnCount)
        var rows: [Row] = []
        var rowIDByEmojiID: [String: Row.ID] = [:]

        func appendItemRows(_ items: [EmojiItem], groupID: String?) {
            var startIndex = 0
            while startIndex < items.count {
                let endIndex = min(startIndex + columnCount, items.count)
                let rowItems = Array(items[startIndex..<endIndex])
                guard let firstItem = rowItems.first else { break }

                let rowID = Row.ID.items(
                    groupID: groupID,
                    firstItemID: firstItem.id
                )
                rows.append(Row(id: rowID, content: .items(rowItems)))

                for item in rowItems {
                    rowIDByEmojiID[item.id] = rowID
                    for variant in item.skinVariants {
                        rowIDByEmojiID[variant.id] = rowID
                    }
                }

                startIndex = endIndex
            }
        }

        if showsGroups {
            var displayedGroupCount = 0
            for group in groups where !group.items.isEmpty {
                rows.append(
                    Row(
                        id: .header(groupID: group.id),
                        content: .header(
                            title: group.name,
                            addsTopSpacing: displayedGroupCount > 0
                        )
                    )
                )
                appendItemRows(group.items, groupID: group.id)
                displayedGroupCount += 1
            }
        } else {
            appendItemRows(groups.flatMap(\.items), groupID: nil)
        }

        self.rows = rows
        self.rowIDByEmojiID = rowIDByEmojiID
    }

    func rowID(for emojiID: String) -> Row.ID? {
        rowIDByEmojiID[emojiID]
    }
}

private enum IconPickerMetrics {
    static let width: CGFloat = 262
    static let height: CGFloat = 280
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    static let segmentHeight: CGFloat = 26
    static let segmentToSearchSpacing: CGFloat = 8
    static let searchHeight: CGFloat = 24
    static let searchToGridSpacing: CGFloat = 4
    static let gridHeight: CGFloat = 202
    static let gridHorizontalPadding: CGFloat = 8
    static let gridVerticalPadding: CGFloat = 8
    static let itemSize: CGFloat = 26
    static let iconSize: CGFloat = 20
    static let emojiFontSize: CGFloat = 14
    static let skinVariantEmojiFontSize: CGFloat = 14
    static let emojiVerticalOffset: CGFloat = -1
    static let itemCornerRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let emojiGroupExtraTopSpacing: CGFloat = 10
    static let emojiHeaderExtraBottomSpacing: CGFloat = 4
    static let fixedColumnCount = 8
    static let fixedColumnSpacing: CGFloat = 4
    static var fixedGridContentWidth: CGFloat {
        CGFloat(fixedColumnCount) * itemSize
            + CGFloat(fixedColumnCount - 1) * fixedColumnSpacing
    }
    static let columns = Array(
        repeating: GridItem(.fixed(itemSize), spacing: fixedColumnSpacing),
        count: fixedColumnCount
    )
}

private struct EmojiPickerGridRow: View {
    let row: EmojiGridLayout.Row
    let columns: [GridItem]
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    var body: some View {
        switch row.content {
        case .header(let title, let addsTopSpacing):
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(
                    .top,
                    addsTopSpacing ? IconPickerMetrics.emojiGroupExtraTopSpacing : 0
                )
                .padding(.bottom, IconPickerMetrics.emojiHeaderExtraBottomSpacing)
        case .items(let items):
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(items) { item in
                    EmojiPickerGridButton(
                        item: item,
                        selectedEmojiId: selectedEmojiId,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
}

private struct IconPickerSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !text.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(NSLocalizedString("common.iconPicker.clearSearchButtonAccessibilityLabel", value: "Clear search",
                    comment: "Icon picker - Accessibility label for clearing search"
                )))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: IconPickerMetrics.searchHeight)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 999))
    }

    private func clearSearch() {
        text = ""
    }
}

private struct IconPickerGridButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    let content: () -> Content

    @State private var isHovering = false

    init(isSelected: Bool,
         help: String,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.help = help
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: IconPickerMetrics.itemSize, height: IconPickerMetrics.itemSize)
                .background(background)
                .contentShape(RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous)
            .fill(
                isSelected
                    ? Color.sidebarTabSelected
                    : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .shadow(
                color: .black.opacity(isSelected ? 0.15 : 0),
                radius: 1,
                x: 0,
                y: 1
            )
    }
}

private struct EmojiPickerGridButton: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    @State private var showsSkinPicker = false

    private var isSelected: Bool {
        selectedEmojiId == item.id
            || item.skinVariants.contains(where: { $0.id == selectedEmojiId })
    }

    var body: some View {
        IconPickerGridButton(
            isSelected: isSelected,
            help: item.name,
            action: selectOrShowSkinPicker
        ) {
            Text(item.text)
                .font(.system(size: IconPickerMetrics.emojiFontSize))
                .offset(y: IconPickerMetrics.emojiVerticalOffset)
        }
        .popover(isPresented: $showsSkinPicker, arrowEdge: .top) {
            EmojiSkinVariantPicker(
                item: item,
                selectedEmojiId: selectedEmojiId,
                onSelect: { selection in
                    showsSkinPicker = false
                    onSelect(selection)
                }
            )
        }
    }

    private func selectOrShowSkinPicker() {
        if item.hasSkinVariants {
            showsSkinPicker = true
        } else {
            onSelect(.emoji(id: item.id, text: item.text))
        }
    }
}

private struct EmojiSkinVariantPicker: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    private var options: [EmojiVariant] {
        [EmojiVariant(id: item.id, text: item.text, name: item.name)] + item.skinVariants
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                IconPickerGridButton(
                    isSelected: selectedEmojiId == option.id,
                    help: option.name,
                    action: { onSelect(.emoji(id: option.id, text: option.text)) }
                ) {
                    Text(option.text)
                        .font(.system(size: IconPickerMetrics.skinVariantEmojiFontSize))
                        .offset(y: IconPickerMetrics.emojiVerticalOffset)
                }
            }
        }
        .padding(10)
    }
}

#Preview("IconPicker") {
    IconPickerPreviewHost()
}

private struct IconPickerPreviewHost: View {
    @State private var selection: IconPickerSelection? = .phiIcon(id: "phi-icon-rss")

    var body: some View {
        IconPicker(
            selected: selection,
            showsGroups: true,
            onSelect: { selection = $0 }
        )
    }
}

// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import SwiftUI
import MarkdownView

struct FolioLibraryView: View {
    @Bindable var model: FolioLibraryModel
    let openURL: (URL) -> Void
    let openArchive: (FolioItem) -> Void
    let reveal: (FolioItem?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showHighlights = false
    @State private var fontSize: CGFloat = 17
    @State private var pendingTrash: FolioItem?
    @FocusState private var searchFocused: Bool

    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.105, green: 0.105, blue: 0.10) : Color(red: 0.985, green: 0.977, blue: 0.957)
    }
    private var shelf: Color {
        colorScheme == .dark ? Color(red: 0.135, green: 0.135, blue: 0.13) : Color(red: 0.947, green: 0.935, blue: 0.91)
    }
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.88, green: 0.60, blue: 0.40) : Color(red: 0.57, green: 0.29, blue: 0.17)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 260, idealWidth: 310, maxWidth: 360)
            reader.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
        }
        .background(paper)
        .tint(accent)
        .environment(\.openURL, OpenURLAction { url in
            guard FolioLibrary.webURL(url.absoluteString) != nil else { return .discarded }
            openURL(url)
            return .handled
        })
        .onChange(of: model.selection) { _, _ in showHighlights = false }
        .task(id: model.selectedItem) { await model.readSelection() }
        .onChange(of: model.search) { _, _ in model.reconcileSelection() }
        .onChange(of: model.filter) { _, _ in model.reconcileSelection() }
        .background {
            Button(FolioStrings.search) { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
            Button(FolioStrings.refresh) { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command).hidden()
        }
        .confirmationDialog(FolioStrings.trashTitle, isPresented: Binding(
            get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible, presenting: pendingTrash) { item in
                Button(FolioStrings.trash, role: .destructive) {
                    pendingTrash = nil
                    Task { await model.trash(item) }
                }
                Button(FolioStrings.cancel, role: .cancel) { pendingTrash = nil }
            } message: { item in
                Text(verbatim: item.title + "\n\n" + FolioStrings.trashMessage)
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FolioStrings.title).font(.system(size: 36, weight: .regular, design: .serif))
                    Spacer()
                    Image(systemName: "books.vertical").font(.system(size: 21, weight: .light)).foregroundStyle(accent)
                }
                Text(FolioStrings.tagline).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, -14)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(FolioStrings.search, text: $model.search)
                        .textFieldStyle(.plain).focused($searchFocused)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel(FolioStrings.clearSearch)
                    }
                }
                .font(.system(size: 13)).padding(10)
                .background(paper, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.08)))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(FolioLibraryModel.Filter.allCases, id: \.self) { filter in
                        filterButton(filter)
                    }
                }
            }.padding(22)
            HStack {
                Text(FolioStrings.collection).font(.system(size: 10, weight: .semibold)).tracking(1.4)
                Text(verbatim: String(model.visibleItems.count)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                Spacer()
                Menu {
                    Button(FolioStrings.newestFirst) { model.oldestFirst = false }
                    Button(FolioStrings.oldestFirst) { model.oldestFirst = true }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help(FolioStrings.sort)
                    .accessibilityLabel(FolioStrings.sort)
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            if model.isLoading && model.items.isEmpty {
                Spacer()
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer()
            } else if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.items.isEmpty ? "bookmark" : "magnifyingglass").font(.system(size: 24, weight: .light))
                    Text(model.items.isEmpty ? FolioStrings.noItems : FolioStrings.noMatches)
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                    if !model.items.isEmpty {
                        Button(FolioStrings.resetFilters) { model.search = ""; model.filter = .all }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }.foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleItems) { item in
                        FolioItemRow(item: item, selected: model.selection == item.id)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 13, bottom: 5, trailing: 13))
                            .contextMenu {
                                if let url = item.sourceURL { Button(FolioStrings.openOriginal) { openURL(url) } }
                                if item.hasWebpage { Button(FolioStrings.webpageCopy) { openArchive(item) } }
                                Button(FolioStrings.reveal) { reveal(item) }
                                Divider()
                                Button(FolioStrings.trash, role: .destructive) { pendingTrash = item }
                            }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            Divider().padding(.horizontal, 22)
            HStack(spacing: 10) {
                Button { reveal(nil) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder").font(.system(size: 15, weight: .light))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FolioStrings.onYourMac).font(.system(size: 11, weight: .medium))
                            Text(verbatim: model.folder.lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.buttonStyle(.plain).help(model.folder.path)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help(FolioStrings.refresh).accessibilityLabel(FolioStrings.refresh)
            }.foregroundStyle(.secondary).padding(22)
        }.background(shelf)
    }

    private func filterButton(_ filter: FolioLibraryModel.Filter) -> some View {
        Button { model.filter = filter } label: {
            HStack(spacing: 7) {
                Image(systemName: filter.symbol).font(.system(size: 11))
                Text(filter.title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .foregroundStyle(model.filter == filter ? accent : .secondary)
                .background(model.filter == filter ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.filter == filter ? accent.opacity(0.18) : .primary.opacity(0.07)))
        }.buttonStyle(.plain).accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }

    private var reader: some View {
        VStack(spacing: 0) {
            if let error = model.error ?? model.loadError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FolioStrings.loadError).fontWeight(.medium)
                        Text(verbatim: error).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(FolioStrings.retry) { Task { await model.refresh(); await model.readSelection() } }
                }.font(.system(size: 12)).padding(16).background(accent.opacity(0.08))
            }
            if let item = model.selectedItem {
                readerToolbar(item)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        articleHeader(item)
                        Rectangle().fill(accent.opacity(0.35)).frame(width: 42, height: 2).padding(.bottom, 4)
                        if model.isReading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
                        } else if let document = model.document {
                            let markdown = showHighlights ? document.highlights : document.article
                            if markdown.isEmpty {
                                Text(showHighlights ? FolioStrings.noHighlights : FolioStrings.noArticle)
                                    .font(.system(size: 15, design: .serif)).foregroundStyle(.secondary)
                            } else {
                                FolioMarkdownView(markdown: markdown, fontSize: fontSize, accent: accent)
                            }
                            HStack(spacing: 10) {
                                Rectangle().frame(height: 1)
                                Image(systemName: "bookmark.fill").font(.system(size: 10))
                                Rectangle().frame(height: 1)
                            }.foregroundStyle(accent.opacity(0.25)).padding(.top, 36)
                        }
                    }
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(.horizontal, 44).padding(.top, 48).padding(.bottom, 64)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top)
                .id(item.id + (showHighlights ? "-highlights" : "-article"))
            } else {
                welcome
            }
        }.background(paper)
    }

    private func readerToolbar(_ item: FolioItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { readingMode; Spacer(); readerActions(item, compact: false) }
            HStack(spacing: 10) { readingMode; Spacer(); readerActions(item, compact: true) }
        }.padding(.horizontal, 20).frame(height: 56)
    }

    private var readingMode: some View {
        Picker(FolioStrings.readingMode, selection: $showHighlights) {
            Text(FolioStrings.article).tag(false)
            Text(FolioStrings.highlights).tag(true)
        }.pickerStyle(.segmented).fixedSize().labelsHidden()
    }

    private func readerActions(_ item: FolioItem, compact: Bool) -> some View {
        HStack(spacing: 16) {
            if let url = item.sourceURL {
                Button { openURL(url) } label: {
                    if compact { Image(systemName: "arrow.up.right") }
                    else { Label(FolioStrings.openOriginal, systemImage: "arrow.up.right") }
                }.buttonStyle(.plain).help(FolioStrings.openOriginal).accessibilityLabel(FolioStrings.openOriginal)
            }
            Menu {
                Button(FolioStrings.largerText) { fontSize = min(25, fontSize + 1) }.disabled(fontSize >= 25)
                Button(FolioStrings.smallerText) { fontSize = max(13, fontSize - 1) }.disabled(fontSize <= 13)
                Divider()
                if item.hasWebpage { Button(FolioStrings.webpageCopy) { openArchive(item) } }
                Button(FolioStrings.reveal) { reveal(item) }
                Divider()
                Button(FolioStrings.trash, role: .destructive) { pendingTrash = item }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16, weight: .light)) }
                .menuStyle(.borderlessButton).fixedSize().help(FolioStrings.more).accessibilityLabel(FolioStrings.more)
        }.font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func articleHeader(_ item: FolioItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: item.isVideo ? "play.rectangle" : "doc.text")
                Text(verbatim: (item.domain.isEmpty ? (item.isVideo ? FolioStrings.video : FolioStrings.article) : item.domain).uppercased())
                    .tracking(1.8).lineLimit(1)
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            Text(verbatim: item.title)
                .font(.system(size: 36, weight: .regular, design: .serif)).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(FolioStrings.saved)
                Text(item.saved, format: .dateTime.month(.abbreviated).day().year())
                if item.hasWebpage {
                    Text(verbatim: "·")
                    Image(systemName: "checkmark.seal").help(FolioStrings.webpageCopy)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.06))
                    .frame(width: 104, height: 132).rotationEffect(.degrees(-12)).offset(x: -12, y: 1)
                RoundedRectangle(cornerRadius: 14).fill(paper)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.25)))
                    .frame(width: 104, height: 132).rotationEffect(.degrees(6))
                Image(systemName: "bookmark").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(accent)
            }.padding(.bottom, 8).accessibilityHidden(true)
            Text(model.items.isEmpty ? FolioStrings.welcome : FolioStrings.selectItem)
                .font(.system(size: 30, weight: .regular, design: .serif)).multilineTextAlignment(.center)
            Text(model.items.isEmpty ? FolioStrings.welcomeDetail : FolioStrings.selectDetail)
                .font(.system(size: 14)).lineSpacing(6).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            if model.items.isEmpty {
                Label(FolioStrings.saveHint, systemImage: "bookmark")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(accent.opacity(0.07), in: Capsule())
            }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolioItemRow: View {
    let item: FolioItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: item.isVideo ? "play.rectangle" : "doc.text")
                Text(verbatim: item.domain.isEmpty ? (item.isVideo ? FolioStrings.video : FolioStrings.article) : item.domain).lineLimit(1)
                Spacer(minLength: 0)
                if item.hasHighlights { Image(systemName: "highlighter").accessibilityLabel(FolioStrings.highlights) }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? .primary : .secondary)
            Text(verbatim: item.title).font(.system(size: 15, weight: .medium, design: .serif))
                .lineLimit(3).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.saved, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 10)).foregroundStyle(selected ? .primary : .secondary).opacity(0.8)
        }.padding(.vertical, 10).padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

/// A single native text view keeps selection continuous across paragraphs.
struct FolioMarkdownView: View {
    let markdown: String
    let fontSize: CGFloat
    let accent: Color

    var body: some View {
        MarkdownReader(markdown) { parsed in
            MarkdownText(parsed)
        }
        .markdownFontGroup(FolioMarkdownFonts(size: fontSize))
        .markdownComponentSpacing(fontSize * 0.9)
        .markdownListIndent(fontSize * 1.3)
        .markdownTableStyle(.github)
        .tint(accent, for: .link)
        .tint(accent, for: .blockQuote)
        // RichText's AppKit link handling does not use SwiftUI's openURL action.
        .markdownElementRenderer(.link(FolioMarkdownLink(), urlScheme: "https"))
        .markdownElementRenderer(.link(FolioMarkdownLink(), urlScheme: "http"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FolioMarkdownLink: MarkdownLinkRenderer {
    func makeBody(configuration: Configuration) -> some View {
        SwiftUI.Link(destination: configuration.url) { configuration.label }
    }
}

private struct FolioMarkdownFonts: MarkdownFontGroup {
    let size: CGFloat

    private func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    var body: any CustomCTFontConvertible { serif(size) }
    var h1: any CustomCTFontConvertible { serif(size + 8, weight: .medium) }
    var h2: any CustomCTFontConvertible { serif(size + 6, weight: .medium) }
    var h3: any CustomCTFontConvertible { serif(size + 4, weight: .medium) }
    var h4: any CustomCTFontConvertible { serif(size + 2, weight: .medium) }
    var h5: any CustomCTFontConvertible { serif(size, weight: .medium) }
    var h6: any CustomCTFontConvertible { serif(size, weight: .medium) }
    var blockQuote: any CustomCTFontConvertible { serif(size) }
    var codeBlock: any CustomCTFontConvertible { NSFont.monospacedSystemFont(ofSize: size - 3, weight: .regular) }
    var tableBody: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size - 2) }
    var tableHeader: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size - 2, weight: .semibold) }
}

extension FolioLibraryModel.Filter {
    var title: String {
        switch self {
        case .all: FolioStrings.allItems
        case .articles: FolioStrings.articles
        case .videos: FolioStrings.videos
        case .highlights: FolioStrings.highlights
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .articles: "doc.text"
        case .videos: "play.rectangle"
        case .highlights: "highlighter"
        }
    }
}

enum FolioStrings {
    static let title = NSLocalizedString("folio.library.title", value: "Folio", comment: "Folio library - Window title and wordmark; keep the product name Folio")
    static let tagline = NSLocalizedString("folio.library.tagline", value: "A little library of things worth keeping.", comment: "Folio library - Subtitle beneath the library name")
    static let search = NSLocalizedString("folio.library.search", value: "Search your library", comment: "Folio library - Search field placeholder for titles and sources")
    static let clearSearch = NSLocalizedString("folio.library.clearSearch", value: "Clear Search", comment: "Folio library - Accessible label for clearing the search field")
    static let refresh = NSLocalizedString("folio.library.refresh", value: "Refresh Library", comment: "Folio library - Reloads saved files from disk")
    static let collection = NSLocalizedString("folio.library.collection", value: "COLLECTION", comment: "Folio library - Small heading above the saved item list")
    static let allItems = NSLocalizedString("folio.library.allItems", value: "All Items", comment: "Folio library - Filter showing every saved item")
    static let articles = NSLocalizedString("folio.library.articles", value: "Articles", comment: "Folio library - Filter showing saved articles")
    static let videos = NSLocalizedString("folio.library.videos", value: "Videos", comment: "Folio library - Filter showing saved video summaries")
    static let highlights = NSLocalizedString("folio.library.highlights", value: "Highlights", comment: "Folio library - Saved highlights and their notes")
    static let article = NSLocalizedString("folio.library.article", value: "Article", comment: "Folio library - Reading mode showing the saved article")
    static let video = NSLocalizedString("folio.library.video", value: "Video", comment: "Folio library - Content type for a saved video summary")
    static let noItems = NSLocalizedString("folio.library.noItems", value: "Your collection starts here.", comment: "Folio library - Empty collection list placeholder")
    static let noMatches = NSLocalizedString("folio.library.noMatches", value: "No items match this view.", comment: "Folio library - Shown when search or filters have no matches")
    static let resetFilters = NSLocalizedString("folio.library.resetFilters", value: "Show All Items", comment: "Folio library - Clears search and filters")
    static let newestFirst = NSLocalizedString("folio.library.newestFirst", value: "Recently Updated First", comment: "Folio library - Sorts by most recently modified file, matching the web library")
    static let oldestFirst = NSLocalizedString("folio.library.oldestFirst", value: "Least Recently Updated First", comment: "Folio library - Sorts by oldest modification date")
    static let sort = NSLocalizedString("folio.library.sort", value: "Sort Collection", comment: "Folio library - Accessible label for the sorting menu")
    static let onYourMac = NSLocalizedString("folio.library.onYourMac", value: "Stored on your Mac", comment: "Folio library - Opens the local storage folder in Finder")
    static let openOriginal = NSLocalizedString("folio.library.openOriginal", value: "Open Original", comment: "Folio library - Opens the original website in the owning browser window")
    static let webpageCopy = NSLocalizedString("folio.library.webpageCopy", value: "Open Saved Webpage", comment: "Folio library - Opens the saved webpage copy in a browser tab")
    static let reveal = NSLocalizedString("folio.library.reveal", value: "Show in Finder", comment: "Folio library - Reveals the saved Markdown file")
    static let more = NSLocalizedString("folio.library.more", value: "Reading Options and Actions", comment: "Folio library - Accessible label for the article options menu")
    static let readingMode = NSLocalizedString("folio.library.readingMode", value: "Reading Mode", comment: "Folio library - Switches between the article and its highlights")
    static let largerText = NSLocalizedString("folio.library.largerText", value: "Larger Text", comment: "Folio library - Increases reading text size")
    static let smallerText = NSLocalizedString("folio.library.smallerText", value: "Smaller Text", comment: "Folio library - Decreases reading text size")
    static let saved = NSLocalizedString("folio.library.saved", value: "Saved", comment: "Folio library - Prefix before the date an item was saved")
    static let noHighlights = NSLocalizedString("folio.library.noHighlights", value: "No highlights yet. Highlight a passage on the original page to keep it here.", comment: "Folio library - Empty highlights reading pane")
    static let noArticle = NSLocalizedString("folio.library.noArticle", value: "This item has no article text. You can open the original or its saved webpage copy.", comment: "Folio library - Shown when the saved item has no readable article")
    static let welcome = NSLocalizedString("folio.library.welcome", value: "Keep what stays with you.", comment: "Folio library - Main heading of the empty library")
    static let welcomeDetail = NSLocalizedString("folio.library.welcomeDetail", value: "Articles to return to, ideas to sit with, and passages you don't want to lose. Give them a place of their own.", comment: "Folio library - Explanation on the empty library welcome screen")
    static let saveHint = NSLocalizedString("folio.library.saveHint", value: "On any webpage, choose File → Save to Folio", comment: "Folio library - Explains how to save the first item")
    static let selectItem = NSLocalizedString("folio.library.selectItem", value: "Something worth returning to.", comment: "Folio library - Heading when no article is selected")
    static let selectDetail = NSLocalizedString("folio.library.selectDetail", value: "Choose an item from your collection and make a little room to read.", comment: "Folio library - Prompt to select a saved article")
    static let loadError = NSLocalizedString("folio.library.loadError", value: "Couldn't read your Folio", comment: "Folio library - Heading for a file or folder access error")
    static let retry = NSLocalizedString("folio.library.retry", value: "Try Again", comment: "Folio library - Retries reading the library after an error")
    static let trash = NSLocalizedString("folio.library.trash", value: "Move to Trash", comment: "Folio library - Moves a saved item and its webpage copy to Trash")
    static let trashTitle = NSLocalizedString("folio.library.trashTitle", value: "Move this item to Trash?", comment: "Folio library - Confirmation before removing a saved item")
    static let trashMessage = NSLocalizedString("folio.library.trashMessage", value: "The article and its saved webpage copy will be moved to Trash. You can restore them in Finder.", comment: "Folio library - Explains what removing an item does")
    static let cancel = NSLocalizedString("folio.library.cancel", value: "Cancel", comment: "Folio library - Cancels moving an item to Trash")
}

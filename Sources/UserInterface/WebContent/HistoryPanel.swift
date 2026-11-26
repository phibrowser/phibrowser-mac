// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

// MARK: - Model

/// Where a history entry opens. `.current` is resolved from the
/// modifier keys at the click, the way links behave: ⌘ opens a new tab in
/// the background, ⌘⇧ a new tab in front.
enum HistoryPanelOpenMode {
    case current, newBackgroundTab, newForegroundTab

    /// The mode for the keys held now; a plain click or Return keeps `self`
    /// unless `newTabByDefault`.
    func resolved(newTabByDefault: Bool = false) -> HistoryPanelOpenMode {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return newTabByDefault ? .newForegroundTab : self }
        return flags.contains(.shift) ? .newForegroundTab : .newBackgroundTab
    }
}

/// State of one window's floating history panel.
@MainActor
final class HistoryPanelModel: ObservableObject {
    enum Range: CaseIterable, Identifiable {
        case today, yesterday, week
        var id: Self { self }

        var title: String {
            switch self {
            case .today:
                return NSLocalizedString("history.floatingPanel.range.today", value: "Today",
                    comment: "Floating history panel - filter chip that shows only today's visits")
            case .yesterday:
                return NSLocalizedString("history.floatingPanel.range.yesterday", value: "Yesterday",
                    comment: "Floating history panel - filter chip that shows only yesterday's visits")
            case .week:
                return NSLocalizedString("history.floatingPanel.range.week", value: "Week",
                    comment: "Floating history panel - filter chip that shows the last seven days of visits")
            }
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let entries: [HistoryPanelEntry]
    }

    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            // Answer at once from what's already here, then ask Chromium.
            showProvisionalMatches()
            reload(debounced: true)
        }
    }
    /// Nil shows all history.
    /// Opens with no filter: all history.
    @Published var range: Range? = nil {
        didSet { if range != oldValue { reload(debounced: false) } }
    }
    @Published private(set) var sections: [Section] = []
    @Published var selectedId: String?
    @Published private(set) var hasLoaded = false

    /// Raw visits Chromium is asked for per page (repeat visits to a page
    /// merge, so fewer rows arrive); scrolling near the end reads the next.
    private static let pageSize = 150
    private let service: HistoryPanelService
    private var entries: [HistoryPanelEntry] = []
    private var reachedEnd = false
    private var queryTask: Task<Void, Never>?

    /// Recent results by search and range, so going back to one (deleting a
    /// letter, switching the chip back) paints at once while it refreshes.
    private struct CacheKey: Hashable {
        let text: String
        let range: Range?
    }
    private struct CachedResult {
        let rows: [HistoryPanelEntry]
        let complete: Bool
    }
    private var cache: [CacheKey: CachedResult] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 24

    private func remember(_ rows: [HistoryPanelEntry], complete: Bool, for key: CacheKey) {
        cache[key] = CachedResult(rows: rows, complete: complete)
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// While a search is on its way: the rows of the closest search already
    /// answered (this one, or a shorter one it extends) that match the new
    /// text. Exact when that search had all of history's matches.
    private func showProvisionalMatches() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[CacheKey(text: text, range: range)] {
            apply(cached.rows)
            return
        }
        let lowered = text.lowercased()
        var source = entries
        var prefix = lowered
        while !prefix.isEmpty {
            prefix.removeLast()
            if let cached = cache[CacheKey(text: prefix, range: range)] { source = cached.rows; break }
        }
        guard !lowered.isEmpty else { return }
        let terms = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        apply(source.filter { entry in
            let haystack = (entry.title + " " + entry.url).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }, provisional: true)
    }
    let onOpen: (HistoryPanelEntry, HistoryPanelOpenMode) -> Void
    let onShowFullHistory: () -> Void
    let onClose: () -> Void

    init(service: HistoryPanelService,
         onOpen: @escaping (HistoryPanelEntry, HistoryPanelOpenMode) -> Void,
         onShowFullHistory: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.service = service
        self.onOpen = onOpen
        self.onShowFullHistory = onShowFullHistory
        self.onClose = onClose
        // Paint the last opening view at once; `onAppear` refreshes it.
        if let cached = service.lastOpeningResults { apply(cached) }
    }


    func favicon(for entry: HistoryPanelEntry) -> NSImage? { service.cachedFavicon(for: entry.url) }

    func loadFavicon(for entry: HistoryPanelEntry, completion: @escaping (NSImage?) -> Void) {
        service.loadFavicon(for: entry.url, completion: completion)
    }

    func reload(debounced: Bool) {
        reachedEnd = false
        if !debounced, let cached = cache[CacheKey(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   range: range)] {
            apply(cached.rows)
        }
        // A short pause lets a burst of typing become one query; what's
        // typed shows at once from `showProvisionalMatches`.
        runQuery(delay: debounced ? 0.04 : 0, mode: .fresh)
    }

    /// Re-reads the newest page so new visits appear; rows already loaded
    /// below it stay.
    func refresh() {
        runQuery(delay: 0, mode: .refresh)
    }

    func loadMoreIfNeeded(after entry: HistoryPanelEntry) {
        guard !reachedEnd, queryTask == nil,
              let index = entries.firstIndex(of: entry), index >= entries.count - 10 else { return }
        runQuery(delay: 0, mode: .more)
    }

    private enum QueryMode { case fresh, refresh, more }

    private func runQuery(delay: TimeInterval, mode: QueryMode) {
        queryTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = range
        let existing = entries
        queryTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let since: Date? = switch range {
            case .today: startOfToday
            case .yesterday: calendar.date(byAdding: .day, value: -1, to: startOfToday)
            case .week: calendar.date(byAdding: .day, value: -7, to: Date())
            case nil: nil
            }
            // Yesterday's view skips today's visits, which come first.
            let keeps: (HistoryPanelEntry) -> Bool = range == .yesterday ? { $0.time < startOfToday } : { _ in true }
            var rows: [HistoryPanelEntry] = mode == .more ? existing : []
            var seen = Set(rows.map(\.id))
            func absorb(_ page: [HistoryPanelEntry]) {
                for entry in page where keeps(entry) && seen.insert(entry.id).inserted { rows.append(entry) }
            }
            let started = Date()
            var page = mode == .more
                ? await self.service.continueQuery(since: since)
                : await self.service.query(text, since: since, limit: Self.pageSize)
            guard !Task.isCancelled else { return }
            absorb(page.entries)
            let firstPageMs = Int(Date().timeIntervalSince(started) * 1000)
            // A new search shows its first page at once; any more it needs
            // to fill the list arrive behind it.
            if mode == .fresh, !rows.isEmpty { self.apply(rows) }
            if mode == .refresh, let boundary = page.entries.last?.time {
                absorb(existing.filter { $0.time < boundary })
            }
            // Read on until something new shows (a refresh's continuation can
            // return rows already listed; Yesterday's first pages can be all
            // today) or history ends. Each page costs about the same.
            let wanted = mode == .more ? existing.count + 1 : (mode == .fresh ? 40 : 0)
            var rounds = 0
            while !page.finished, rows.count < wanted, rounds < 20 {
                rounds += 1
                page = await self.service.continueQuery(since: since)
                guard !Task.isCancelled else { return }
                absorb(page.entries)
            }
            if mode != .refresh { self.reachedEnd = page.finished }
            if mode == .fresh, text.isEmpty, range == nil {
                self.service.lastOpeningResults = rows
            }
            if mode != .more {
                self.remember(rows, complete: page.finished, for: CacheKey(text: text, range: range))
            }
            AppLogDebug("[HistoryPanel] \(mode) query (\(text.count) chars): first page \(firstPageMs) ms, "
                + "\(rows.count) rows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            self.apply(rows)
            self.queryTask = nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    /// `provisional` rows (filtered from earlier results while a search is
    /// on its way) don't replace the loaded list the next page builds on.
    private func apply(_ results: [HistoryPanelEntry], provisional: Bool = false) {
        if !provisional { entries = results }
        let calendar = Calendar.current
        let formatter = Self.dayFormatter
        var built: [Section] = []
        var current: (day: Date, entries: [HistoryPanelEntry])?
        func flush() {
            guard let current else { return }
            let title: String
            if calendar.isDateInToday(current.day) {
                title = Range.today.title
            } else if calendar.isDateInYesterday(current.day) {
                title = Range.yesterday.title
            } else {
                title = formatter.string(from: current.day)
            }
            built.append(Section(id: "\(current.day.timeIntervalSince1970)", title: title, entries: current.entries))
        }
        for entry in results {
            let day = calendar.startOfDay(for: entry.time)
            if current?.day == day {
                current?.entries.append(entry)
            } else {
                flush()
                current = (day, [entry])
            }
        }
        flush()
        sections = built
        hasLoaded = true
        if let selectedId, !results.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let index = selectedId.flatMap { id in entries.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), entries.count - 1) } ?? (delta > 0 ? 0 : entries.count - 1)
        selectedId = entries[next].id
    }

    func openSelection(_ mode: HistoryPanelOpenMode) {
        guard let entry = entries.first(where: { $0.id == selectedId }) ?? entries.first else { return }
        onOpen(entry, mode)
    }
}

// MARK: - View

/// The floating history card.
struct HistoryPanelView: View {
    @ObservedObject var model: HistoryPanelModel
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.phiTheme) private var theme
    @FocusState private var searchFocused: Bool

    private var isDark: Bool { appearance.isDark }
    private var accent: Color { Color(nsColor: theme.color(for: .themeColor, appearance: appearance)) }
    private var onAccent: Color { isDark ? Color(red: 0x12 / 255, green: 0x14 / 255, blue: 0x2A / 255) : .white }
    // The Space's color, as the sidebar shows it, with translucent black or
    // white on top.
    private var ink: Color { isDark ? .white : .black }
    private var text: Color { ink.opacity(0.85) }
    private var muted: Color { ink.opacity(0.5) }
    private var field: Color { ink.opacity(isDark ? 0.08 : 0.06) }
    private var hairline: Color { ink.opacity(isDark ? 0.14 : 0.1) }
    /// The sidebar's Space tint (`windowOverlayBackground`) laid over the
    /// window background: the color the sidebar shows, made opaque, since the
    /// panel has no window glass behind it.
    private var background: Color {
        let base = ThemedColor.windowBackground.resolve(theme: theme, appearance: appearance)
        let tint = ThemedColor.windowOverlayBackground.resolve(theme: theme, appearance: appearance)
        let opaqueTint = tint.withAlphaComponent(1)
        return Color(nsColor: base.blended(withFraction: tint.alphaComponent, of: opaqueTint) ?? opaqueTint)
    }
    static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            chips
            list
            footer
        }
        .padding(EdgeInsets(top: 10, leading: 6, bottom: 8, trailing: 6))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(hairline, lineWidth: 1)
        }
        .onAppear {
            searchFocused = true
            // Shows the cached opening view (if any) at once, then refreshes.
            model.reload(debounced: false)
        }
        .onKeyPress(.escape) {
            if model.searchText.isEmpty { model.onClose() } else { model.searchText = "" }
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Text(NSLocalizedString("history.floatingPanel.title", value: "History",
                comment: "Floating history panel - title at the top of the panel"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(text)
            Spacer()
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(muted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(field))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("history.floatingPanel.close", value: "Close history",
                comment: "Floating history panel - accessible label of the close button"))
        }
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
            TextField("", text: $model.searchText,
                      prompt: Text(NSLocalizedString("history.floatingPanel.searchPlaceholder", value: "Search history",
                          comment: "Floating history panel - placeholder of the search field")).foregroundStyle(muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(text)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onSubmit {
                    model.openSelection(HistoryPanelOpenMode.current.resolved())
                }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(field))
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(HistoryPanelModel.Range.allCases) { range in
                let selected = model.range == range
                Button {
                    // Tapping the selected chip clears the filter: all history.
                    model.range = selected ? nil : range
                } label: {
                    Text(range.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? onAccent : muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? accent : field))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 2, trailing: 6))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 11))
                            .tracking(0.66)
                            .foregroundStyle(muted)
                            .padding(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
                        ForEach(section.entries) { entry in
                            HistoryPanelRow(entry: entry, isSelected: model.selectedId == entry.id,
                                           accent: accent, text: text, muted: muted, field: field,
                                           actions: rowActions)
                                .equatable()
                                .id(entry.id)
                                .onAppear { model.loadMoreIfNeeded(after: entry) }
                        }
                    }
                    if model.hasLoaded, model.sections.isEmpty {
                        Text(NSLocalizedString("history.floatingPanel.empty", value: "No history found",
                            comment: "Floating history panel - shown when no visits match the search or filter"))
                            .font(.system(size: 12))
                            .foregroundStyle(muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedId) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    /// What a row needs from the model, without observing it: a row then
    /// redraws only when its own entry or selection changes, not on every
    /// keystroke or selection move elsewhere in the list.
    private var rowActions: HistoryPanelRow.Actions {
        let model = model
        return HistoryPanelRow.Actions(
            open: { entry in
                model.selectedId = entry.id
                model.onOpen(entry, HistoryPanelOpenMode.current.resolved())
            },
            cachedFavicon: { model.favicon(for: $0) },
            loadFavicon: { model.loadFavicon(for: $0, completion: $1) })
    }

    private var footer: some View {
        Button(action: model.onShowFullHistory) {
            Text(NSLocalizedString("history.floatingPanel.showAll", value: "Show full history",
                comment: "Floating history panel - footer button that opens the full history page in a tab"))
                .font(.system(size: 11.5))
                .foregroundStyle(muted)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

private struct HistoryPanelRow: View, Equatable {
    struct Actions {
        let open: (HistoryPanelEntry) -> Void
        let cachedFavicon: (HistoryPanelEntry) -> NSImage?
        let loadFavicon: (HistoryPanelEntry, @escaping (NSImage?) -> Void) -> Void
    }

    let entry: HistoryPanelEntry
    let isSelected: Bool
    let accent: Color
    let text: Color
    let muted: Color
    let field: Color
    let actions: Actions
    @State private var favicon: NSImage?
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isSelected == rhs.isSelected && lhs.accent == rhs.accent
            && lhs.text == rhs.text && lhs.muted == rhs.muted && lhs.field == rhs.field
    }

    var body: some View {
        Button {
            actions.open(entry)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(field)
                    if let favicon {
                        Image(nsImage: favicon).resizable().interpolation(.high).frame(width: 14, height: 14)
                    } else {
                        Text(verbatim: entry.fallbackLetter)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(text)
                        .lineLimit(1)
                    Text(verbatim: entry.timeOfDay.isEmpty ? entry.domain : "\(entry.domain) · \(entry.timeOfDay)")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? accent.opacity(0.16) : (isHovered ? field : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.url)
        .onAppear {
            favicon = actions.cachedFavicon(entry)
            guard favicon == nil else { return }
            actions.loadFavicon(entry) { favicon = $0 }
        }
    }
}

// MARK: - Panel

/// A borderless panel that can take keyboard focus for the search field.
private final class HistoryPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The floating history panel, a native child window of the browser window,
/// so it stays up across page loads, tab switches and Space switches. When
/// `GeneralSettings.showHistoryInFloatingPanel` is on, Show History (⌘Y)
/// toggles it (`CommandDispatcher`); it slides in from the window's right
/// edge and back out.
@MainActor
final class HistoryPanelController: NSObject {
    private static var controllers: [ObjectIdentifier: HistoryPanelController] = [:]

    static let width: CGFloat = 236
    private static let edgeInset: CGFloat = 12
    /// Room for the card's shadow on the sides that are not the window edge.
    private static let shadowMargin: CGFloat = 20
    private static let maxHeight: CGFloat = 560

    /// Toggles the panel for the browser window behind `window` (or closes
    /// the panel when `window` is the panel itself). Returns false when the
    /// window is not one this panel can serve, so the command falls through.
    @discardableResult
    static func toggle(from window: NSWindow) -> Bool {
        if let panel = window as? HistoryPanelWindow, let parent = panel.parent {
            controllers[ObjectIdentifier(parent)]?.close()
            return true
        }
        // Chromium dispatches with its own hidden widget window, not the
        // window on screen; attaching there would force that hidden window
        // on screen as an empty browser window. Use the session's window.
        guard let controller = SpaceSessionControllersManager.shared.findControllerWith(window: window),
              let host = controller.window else {
            return false
        }
        if let existing = controllers[ObjectIdentifier(host)] {
            existing.close()
            return true
        }
        let panelController = HistoryPanelController(parent: host, session: controller)
        controllers[ObjectIdentifier(host)] = panelController
        panelController.show()
        return true
    }

    private weak var parent: NSWindow?
    private let service: HistoryPanelService
    private let panel: HistoryPanelWindow
    private let container = NSView()
    private var hosting: NSView!
    private var model: HistoryPanelModel!
    private var observers: [NSObjectProtocol] = []
    private var refreshSubscription: AnyCancellable?
    private var keyMonitor: Any?
    private var isClosing = false

    private init(parent: NSWindow, session: SpaceSessionController) {
        self.parent = parent
        let state = session.browserState
        service = HistoryPanelService.service(windowId: Int64(state.windowId), profileId: state.profileId)
        let windowId = Int64(state.windowId)
        panel = HistoryPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        super.init()
        model = HistoryPanelModel(
            service: service,
            onOpen: { [weak self] entry, mode in self?.open(entry.url, mode: mode) },
            onShowFullHistory: { [weak self] in self?.open("chrome://history/", mode: .current.resolved(newTabByDefault: true)) },
            onClose: { [weak self] in self?.close() }
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow, so it slides with the card.
        panel.hasShadow = false
        // An ordinary window attached to the browser window: it stays just
        // above that window, so other apps cover both and it stays open.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.onCancel = { [weak self] in self?.close() }

        // The card draws its own rounded, opaque background and shadow in
        // SwiftUI, inset from every side but the window edge. The container
        // clips at the window's right edge, so sliding the card out of it
        // makes it disappear into that edge.
        let root = HistoryPanelView(model: model)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .padding(EdgeInsets(top: Self.shadowMargin, leading: Self.shadowMargin,
                                bottom: Self.shadowMargin, trailing: Self.edgeInset))
        let hosting = ThemedHostingView(rootView: root, themeSource: state.themeContext)
        // The panel is its own window, not the browser window, so on joining
        // it the hosting view would resolve the global theme and drop the
        // Space's: pin the Space's theme to this subtree.
        hosting.subtreeThemeSource = state.themeContext
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hosting = hosting
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(hosting)
        panel.contentView = container
        panel.appearance = parent.effectiveAppearance

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(animated: false)
                HistoryPanelService.release(windowId: windowId)
            }
        })
        // While the panel is key, Show History (⌘Y, or its remapped key)
        // closes it here, before anything else sees the key: the panel is
        // not a browser window, so the menu would hand the command to
        // Chromium, which opens a new, empty browser window instead.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel,
                      ShortcutsKey.eventKeys(for: event)?.matches(Shortcuts.key(for: .IDC_SHOW_HISTORY)) == true
                else { return event }
                self.close()
                return nil
            }
        }

        // Keep the list live: any tab in this window that commits a
        // navigation or settles its title refreshes it, a beat later.
        refreshSubscription = state.$tabs
            .map { tabs in
                Publishers.MergeMany(tabs.flatMap { tab in
                    [tab.$url.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                     tab.$title.dropFirst().map { _ in () }.eraseToAnyPublisher()]
                })
            }
            .switchToLatest()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.refresh() }
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show() {
        guard let parent else { return }
        position()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        focusSearchField()
        guard !reducesMotion else { return }
        hosting.setFrameOrigin(NSPoint(x: container.bounds.width, y: 0))
        NSAnimationContext.runAnimationGroup { context in
            // Same timing as the floating sidebar's hover reveal.
            context.duration = FloatingSidebarHostViewController.floatingSidebarShowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hosting.animator().setFrameOrigin(.zero)
        }
    }

    /// Puts the cursor in the search field, so typing searches at once. The
    /// view asks for focus when it appears, but that is before the panel is
    /// key, so the request can be lost; this asks again once it is.
    private func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if let field = Self.firstEditableField(in: self.hosting), self.panel.firstResponder !== field.currentEditor() {
                self.panel.makeFirstResponder(field)
            }
        }
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableField(in: subview) { return field }
        }
        return nil
    }

    /// Against the browser window's right edge, vertically centered.
    private func position() {
        guard let parent else { return }
        let frame = parent.frame
        let cardHeight = min(Self.maxHeight, frame.height - 2 * 60)
        let size = NSSize(width: Self.width + Self.shadowMargin + Self.edgeInset,
                          height: cardHeight + 2 * Self.shadowMargin)
        panel.setFrame(NSRect(x: frame.maxX - size.width, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        container.frame = NSRect(origin: .zero, size: size)
        if !isClosing { hosting.frame = container.bounds }
    }

    private func open(_ url: String, mode: HistoryPanelOpenMode) {
        guard let parent,
              let controller = SpaceSessionControllersManager.shared.findControllerWith(window: parent) else { return }
        let state = controller.browserState
        switch mode {
        case .current where !state.isInPlaceholderMode:
            if let wrapper = state.focusingTab?.webContentWrapper {
                wrapper.navigate(toURL: url)
            } else {
                state.createTab(url)
            }
        case .current, .newForegroundTab:
            state.createTab(url)
        case .newBackgroundTab:
            state.createTab(url, focusAfterCreate: false)
        }
    }

    func close(animated: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        // Free the slot first, so a toggle during the slide-out opens anew.
        if let parent { Self.controllers[ObjectIdentifier(parent)] = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refreshSubscription = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        parent?.makeKey()
        let finish = { [self] in
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            service.scheduleRelease()
        }
        guard animated, !reducesMotion, panel.isVisible else { finish(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingSidebarHostViewController.floatingSidebarHideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            hosting.animator().setFrameOrigin(NSPoint(x: container.bounds.width, y: 0))
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct AllDownloadsListView: View {
    @ObservedObject var downloadsManager: DownloadsManager
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var selectedProfileId: String?
    @State private var searchText = ""

    var body: some View {
        let groups = downloadGroups

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                searchBar
                profileFilter
                if downloadsManager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

            if !downloadsManager.failedProfileIds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("downloads.all.loadFailure", value: "Some profiles could not be loaded.", comment: "All downloads window - Partial failure while loading profile download histories"))
                    Text(verbatim: downloadsManager.failedProfileIds.map(profileName).joined(separator: ", "))
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.12))
            }

            if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: searchQuery.isEmpty ? "arrow.down.circle" : "magnifyingglass")
                        .font(.system(size: 36))
                    Text(emptyStateMessage)
                }
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.date) { group in
                            Section {
                                ForEach(group.items, id: \.profileScopedId) { item in
                                    DownloadItemRow(
                                        item: item,
                                        isLast: true,
                                        usesHoverAppearance: true,
                                        onCopyLink: downloadsManager.copyLink,
                                        onOpen: downloadsManager.openDownload,
                                        onShowInFinder: downloadsManager.showInFinder,
                                        onPause: downloadsManager.pauseDownload,
                                        onResume: downloadsManager.resumeDownload,
                                        onCancel: downloadsManager.cancelDownload,
                                        onRemove: downloadsManager.removeDownload,
                                        onKeep: downloadsManager.keepDownload,
                                        onDiscard: downloadsManager.discardDownload
                                    )
                                }
                            } header: {
                                Group {
                                    if let date = group.date {
                                        Text(date, format: .dateTime.year().month(.wide).day())
                                    } else {
                                        Text(NSLocalizedString("downloads.all.unknownDate", value: "Unknown Date", comment: "All downloads window - Section heading for downloads without a start date"))
                                    }
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .themedForeground(.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refresh)
        .onChange(of: profileManager.profiles) { _, _ in
            if let selectedProfileId,
               !profileManager.profiles.contains(where: { $0.profileId == selectedProfileId }) {
                self.selectedProfileId = nil
            }
            if downloadsManager.profileIds != filteredProfileIds {
                applyFilter()
            }
        }
    }

    private var searchBar: some View {
        DownloadsSearchField(text: $searchText)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyStateMessage: String {
        if downloadsManager.isLoading {
            return NSLocalizedString("downloads.all.loading", value: "Loading Downloads…", comment: "All downloads window - Loading profile download histories")
        }
        if !searchQuery.isEmpty {
            return NSLocalizedString("downloads.all.noSearchResults", value: "No Matching Downloads", comment: "All downloads window - No downloads in the selected profiles match the search")
        }
        return NSLocalizedString("downloads.all.empty", value: "No Downloads", comment: "All downloads window - No downloads in the selected profile scope")
    }

    private var downloadGroups: [(date: Date?, items: [DownloadItem])] {
        let query = searchQuery
        let items = query.isEmpty ? downloadsManager.downloads : downloadsManager.downloads.filter {
            $0.fileName.localizedStandardContains(query) || $0.url.localizedStandardContains(query)
        }
        let calendar = Calendar.current
        return Dictionary(grouping: items) { item in
            item.startTime.map { calendar.startOfDay(for: $0) }
        }
        .map { (date: $0.key, items: $0.value) }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var profileFilter: some View {
        Menu {
            Picker(selection: Binding(
                get: { selectedProfileId },
                set: { profileId in
                    selectedProfileId = profileId
                    applyFilter()
                }
            )) {
                Text(allProfilesTitle)
                    .tag(nil as String?)
                Divider()
                ForEach(profileManager.profiles) { profile in
                    Text(verbatim: profile.displayName)
                        .tag(Optional(profile.profileId))
                }
            } label: {
                Text(allProfilesTitle)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label {
                Text(verbatim: selectedProfileId.map(profileName) ?? allProfilesTitle)
            } icon: {
                Image(systemName: "person.crop.circle")
            }
        }
        .fixedSize()
    }

    private var allProfilesTitle: String {
        NSLocalizedString("downloads.all.allProfiles", value: "All", comment: "All downloads window - Filter including all regular profiles")
    }

    private func profileName(_ id: String) -> String {
        profileManager.profile(for: id)?.displayName ?? id
    }

    private var filteredProfileIds: [String] {
        profileManager.profiles.map(\.profileId)
            .filter { selectedProfileId == nil || selectedProfileId == $0 }
    }

    private func applyFilter() {
        downloadsManager.selectProfiles(filteredProfileIds)
    }

    private func refresh() {
        profileManager.refresh()
        applyFilter()
    }
}

private struct DownloadsSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.placeholderString = NSLocalizedString("downloads.all.search", value: "Search Downloads", comment: "All downloads window - Placeholder for searching by file name or source URL")
        field.setAccessibilityLabel(field.placeholderString)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class AllDownloadsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("downloads.all.windowTitle", value: "All Downloads", comment: "All downloads window - Window title")
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.contentViewController = ThemedHostingController(
            rootView: AllDownloadsListView(downloadsManager: DownloadsManager(profileIds: []))
        )
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

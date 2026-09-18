// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct AllDownloadsListView: View {
    @ObservedObject var downloadsManager: DownloadsManager
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var selectedProfileIds: Set<String>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                profileFilter
                Text(downloadsManager.downloads.count, format: .number)
                    .monospacedDigit()
                    .themedForeground(.textSecondary)
                Spacer()
                if downloadsManager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: refresh) {
                    Label(
                        NSLocalizedString("downloads.all.refresh", value: "Refresh", comment: "All downloads window - Refresh download history"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(downloadsManager.isLoading)
            }
            .padding(16)
            Divider()

            if !downloadsManager.failedProfileIds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("downloads.all.loadFailure", value: "Some profiles could not be loaded. Try refreshing.", comment: "All downloads window - Partial failure while loading profile download histories"))
                    Text(verbatim: downloadsManager.failedProfileIds.map(profileName).joined(separator: ", "))
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.12))
            }

            if downloadsManager.downloads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 36))
                    Text(downloadsManager.isLoading
                         ? NSLocalizedString("downloads.all.loading", value: "Loading Downloads…", comment: "All downloads window - Loading profile download histories")
                         : NSLocalizedString("downloads.all.empty", value: "No Downloads in Selected Profiles", comment: "All downloads window - No downloads match the selected profiles"))
                }
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloadsManager.downloads, id: \.profileScopedId) { item in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: profileName(item.profileId))
                                    .font(.caption)
                                    .themedForeground(.textSecondary)
                                    .padding(.top, 12)
                                DownloadItemRow(
                                    item: item,
                                    isLast: false,
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
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refresh)
        .onChange(of: profileManager.profiles) { _, _ in
            if downloadsManager.profileIds != filteredProfileIds {
                applyFilter()
            }
        }
    }

    private var profileFilter: some View {
        Menu {
            Button {
                selectedProfileIds = nil
                applyFilter()
            } label: {
                if selectedProfileIds == nil {
                    Label(allProfilesTitle, systemImage: "checkmark")
                } else {
                    Text(allProfilesTitle)
                }
            }
            Divider()
            ForEach(profileManager.profiles) { profile in
                Toggle(isOn: Binding(
                    get: { selectedProfileIds?.contains(profile.profileId) ?? true },
                    set: { selected in
                        var ids = selectedProfileIds ?? Set(profileManager.profiles.map(\.profileId))
                        if selected {
                            ids.insert(profile.profileId)
                        } else {
                            ids.remove(profile.profileId)
                        }
                        selectedProfileIds = ids
                        applyFilter()
                    }
                )) {
                    Text(verbatim: profile.displayName)
                }
            }
        } label: {
            Label(selectedProfileIds == nil
                  ? allProfilesTitle
                  : NSLocalizedString("downloads.all.selectedProfiles", value: "Selected Profiles", comment: "All downloads window - Profile filter menu with a custom selection"),
                  systemImage: "person.crop.circle")
        }
        .fixedSize()
    }

    private var allProfilesTitle: String {
        NSLocalizedString("downloads.all.allProfiles", value: "All Profiles", comment: "All downloads window - Filter including all regular profiles")
    }

    private func profileName(_ id: String) -> String {
        profileManager.profile(for: id)?.displayName ?? id
    }

    private var filteredProfileIds: [String] {
        profileManager.profiles.map(\.profileId)
            .filter { selectedProfileIds?.contains($0) ?? true }
    }

    private func applyFilter() {
        downloadsManager.selectProfiles(filteredProfileIds)
    }

    private func refresh() {
        profileManager.refresh()
        applyFilter()
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
